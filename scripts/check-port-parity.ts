#!/usr/bin/env bun
/**
 * check-port-parity.ts -- the Elm <-> JS port boundary detector.
 *
 * Nothing else in this repo verifies that the tags Elm sends are the tags the
 * shim handles, or that the tags the shim sends back are tags Elm can decode.
 * Both sides are string-keyed JSON: a rename on one side is a silent no-op on
 * the other. Silent, for a library that signs transactions, is worse than a
 * crash.
 *
 * What is checked (all four directions):
 *
 *   CMD-1  every `( "tag", E.string "x" )` in src/**\/*.elm has a matching
 *          `case 'x':` in js/elm-web3-ports.ts
 *   CMD-2  every `case 'x':` in the shim's cmd switch is emitted by some Elm
 *          module (an unreachable handler means the Elm side was renamed)
 *   CMD-3  no cmd tag is emitted from two Elm sites with DIFFERENT payload
 *          field sets -- that is a tag collision, and the shim will read the
 *          fields of whichever shape it was written against and silently get
 *          `undefined` for the other
 *   SUB-1  every `tag: 'x'` the shim sends is known to some Elm module (either
 *          matched in a tag-dispatching decoder or named in the module's
 *          documented wire format)
 *   SUB-2  every tag matched in an Elm tag-dispatching decoder is actually
 *          emitted by the shim (a dead branch means the shim was renamed)
 *   DTS    js/elm-web3-ports.d.ts -- the published type contract -- lists
 *          exactly the cmd tags the shim handles and the sub tags it emits
 *
 * Exit code: 0 when every direction agrees, 1 otherwise. Advisory sections
 * (field-level heuristics) never affect the exit code; they are printed
 * because they are usually right, and are not trusted enough to gate CI.
 *
 * Usage:
 *   bun run scripts/check-port-parity.ts             # check the working tree
 *   bun run scripts/check-port-parity.ts --verbose   # + advisory field diffs
 *   bun run scripts/check-port-parity.ts --self-test # prove the checker fails
 *
 * `--self-test` is not decoration. A checker that has never been observed
 * rejecting anything is not evidence that the thing it checks is sound. The
 * self-test runs the analyser over hermetic synthetic sources: once clean
 * (must report nothing), then once per failure class with a drift injected
 * (must report exactly that class), then once over the REAL sources with a
 * handler deleted (must notice). It exits 0 only if every injected drift was
 * caught and the clean baseline was silent.
 */

import { readdirSync, readFileSync, statSync, existsSync } from 'node:fs'
import { join, dirname, relative } from 'node:path'

// ---------------------------------------------------------------------------
// Source model
// ---------------------------------------------------------------------------

export interface ElmSource {
  readonly path: string
  readonly text: string
}

export interface Sources {
  readonly elm: readonly ElmSource[]
  /** js/elm-web3-ports.ts */
  readonly shim: string
  /** js/elm-web3-ports.d.ts, or null to skip the DTS section. */
  readonly dts: string | null
}

export type FailureCode =
  | 'CMD-1'
  | 'CMD-2'
  | 'CMD-3'
  | 'SUB-1'
  | 'SUB-2'
  | 'DTS-CMD-MISSING'
  | 'DTS-CMD-EXTRA'
  | 'DTS-SUB-MISSING'
  | 'DTS-SUB-EXTRA'

export interface Finding {
  readonly code: FailureCode
  readonly tag: string
  readonly detail: string
}

export interface Report {
  readonly findings: readonly Finding[]
  readonly advisories: readonly string[]
  readonly stats: {
    readonly elmCmdTags: number
    readonly shimCmdTags: number
    readonly shimSubTags: number
    readonly elmSubTags: number
  }
}

interface Emitter {
  readonly tag: string
  readonly where: string
  readonly fields: readonly string[]
}

// ---------------------------------------------------------------------------
// Comment stripping. Both strippers preserve byte offsets and line breaks so
// reported line numbers stay honest.
// ---------------------------------------------------------------------------

function blank(ch: string): string {
  return ch === '\n' ? '\n' : ' '
}

/** Strip Elm `--` line comments and nested `{- -}` block comments. */
export function stripElmComments(src: string): string {
  let out = ''
  let i = 0
  let depth = 0
  let inString = false
  let inChar = false

  while (i < src.length) {
    const ch = src[i] as string
    const next = src[i + 1] ?? ''

    if (depth > 0) {
      if (ch === '{' && next === '-') { depth++; out += '  '; i += 2; continue }
      if (ch === '-' && next === '}') { depth--; out += '  '; i += 2; continue }
      out += blank(ch); i++; continue
    }
    if (inString) {
      if (ch === '\\') { out += ch + (next || ''); i += 2; continue }
      if (ch === '"') inString = false
      out += ch; i++; continue
    }
    if (inChar) {
      if (ch === '\\') { out += ch + (next || ''); i += 2; continue }
      if (ch === "'") inChar = false
      out += ch; i++; continue
    }
    if (ch === '"') { inString = true; out += ch; i++; continue }
    if (ch === "'") { inChar = true; out += ch; i++; continue }
    if (ch === '{' && next === '-') { depth = 1; out += '  '; i += 2; continue }
    if (ch === '-' && next === '-') {
      while (i < src.length && src[i] !== '\n') { out += ' '; i++ }
      continue
    }
    out += ch; i++
  }
  return out
}

/**
 * Strip JS/TS comments. Regex-literal aware -- `elm-web3-ports.ts` contains
 * `/^http(s?):\/\//i`, whose `\/\/` a naive stripper reads as a line comment
 * and then eats the rest of the line.
 */
export function stripJsComments(src: string): string {
  let out = ''
  let i = 0
  // Last significant (non-space, non-comment) character emitted. Decides
  // whether a `/` opens a regex literal or is a division operator.
  let lastSig = ''

  const regexAllowedAfter = new Set([
    '', '(', ',', '=', ':', '[', '!', '&', '|', '?', '{', '}', ';', '+', '-',
    '*', '%', '~', '^', '<', '>', '\n',
  ])

  while (i < src.length) {
    const ch = src[i] as string
    const next = src[i + 1] ?? ''

    if (ch === '/' && next === '/') {
      while (i < src.length && src[i] !== '\n') { out += ' '; i++ }
      continue
    }
    if (ch === '/' && next === '*') {
      out += '  '; i += 2
      while (i < src.length && !(src[i] === '*' && src[i + 1] === '/')) { out += blank(src[i] as string); i++ }
      out += '  '; i += 2
      continue
    }
    if (ch === '"' || ch === "'" || ch === '`') {
      const quote = ch
      out += ch; i++
      while (i < src.length) {
        const c = src[i] as string
        if (c === '\\') { out += c + (src[i + 1] ?? ''); i += 2; continue }
        out += c; i++
        if (c === quote) break
      }
      lastSig = quote
      continue
    }
    if (ch === '/' && regexAllowedAfter.has(lastSig)) {
      // Regex literal: copy through the closing unescaped `/` plus flags.
      out += ch; i++
      let inClass = false
      while (i < src.length) {
        const c = src[i] as string
        if (c === '\\') { out += c + (src[i + 1] ?? ''); i += 2; continue }
        if (c === '[') inClass = true
        else if (c === ']') inClass = false
        out += c; i++
        if (c === '/' && !inClass) break
        if (c === '\n') break
      }
      lastSig = '/'
      continue
    }
    out += ch
    if (!/\s/.test(ch)) lastSig = ch
    else if (ch === '\n') lastSig = '\n'
    i++
  }
  return out
}

// ---------------------------------------------------------------------------
// Extraction -- Elm side
// ---------------------------------------------------------------------------

const ELM_TAG_RE = /\(\s*"tag"\s*,\s*(?:E|Encode|Json\.Encode)\.string\s*"([A-Za-z0-9_]+)"\s*\)/
// A field entry is `( "name",` or `( "name"` with the value on the next line.
const ELM_FIELD_RE = /\(\s*"([A-Za-z0-9_]+)"\s*(?:,|$)/g

/** Blank out string contents, preserving length so indices stay aligned. */
function maskStrings(line: string): string {
  let out = ''
  let inStr = false
  for (let i = 0; i < line.length; i++) {
    const ch = line[i] as string
    if (inStr && ch === '\\') { out += '  '; i++; continue }
    if (ch === '"') { inStr = !inStr; out += '"'; continue }
    out += inStr ? ' ' : ch
  }
  return out
}

/**
 * Field entries on one line, with the list depth at which each sits. Depth
 * matters: `( "nativeCurrency", E.object [ ( "name", ...` puts `name` one
 * level deeper, and a nested object's keys are not wire fields of the cmd.
 */
function scanFieldLine(line: string, depthBefore: number): { fields: string[]; depth: number } {
  const masked = maskStrings(line)
  const depths: number[] = []
  let d = depthBefore
  for (const ch of masked) {
    depths.push(d)
    if (ch === '[') d++
    else if (ch === ']') d = Math.max(0, d - 1)
  }
  const fields: string[] = []
  ELM_FIELD_RE.lastIndex = 0
  let f: RegExpExecArray | null
  while ((f = ELM_FIELD_RE.exec(line)) !== null) {
    if (f[1] === 'tag') continue
    if ((depths[f.index] ?? 0) <= 1) fields.push(f[1] as string)
  }
  return { fields, depth: d }
}

/**
 * Field names produced by each top-level Elm definition in a module, so an
 * encoder assembled from helpers (`base ++ valueFields call ++ ...`) still
 * reports the fields it actually puts on the wire. `owners[i]` is the
 * top-level definition that line `i` belongs to.
 */
export function elmHelperFields(lines: readonly string[]): { fields: Map<string, Set<string>>; owners: (string | null)[] } {
  const map = new Map<string, Set<string>>()
  const owners: (string | null)[] = []
  let current: string | null = null
  let depth = 0

  for (const line of lines) {
    if (line.trim().length > 0 && !/^\s/.test(line)) {
      // Any column-0 lowercase identifier starts a top-level definition or
      // its type annotation. Continuations are always indented in Elm, so
      // this needs no lookahead: `payloadFields call =` and `encode (X y) =`
      // both land here.
      const m = /^([a-z][A-Za-z0-9_']*)\b/.exec(line)
      current = m ? (m[1] as string) : null
      depth = 0
    }
    owners.push(current)
    if (current === null) continue
    if (!map.has(current)) map.set(current, new Set())
    const scan = scanFieldLine(line, depth)
    for (const f of scan.fields) (map.get(current) as Set<string>).add(f)
    depth = scan.depth
  }
  return { fields: map, owners }
}

/**
 * Every cmd tag an Elm module encodes, with the field names of the object it
 * is encoded into. Fields are collected from the tag line until the next tag
 * line or the end of the enclosing top-level definition (the first column-0
 * line), which keeps the multi-tag `case` encoders in Wallet/Block/Query
 * correctly bucketed. Only the outermost list level counts, so a nested
 * `E.object` (addChain's `nativeCurrency`) does not hoist its children.
 */
export function elmCmdEmitters(path: string, rawText: string): Emitter[] {
  const lines = stripElmComments(rawText).split('\n')
  const { fields: helpers, owners } = elmHelperFields(lines)
  const emitters: Emitter[] = []

  for (let i = 0; i < lines.length; i++) {
    const m = ELM_TAG_RE.exec(lines[i] as string)
    if (!m) continue
    const tag = m[1] as string
    const fields = new Set<string>()
    const blockText: string[] = []
    let depth = 0

    for (let j = i; j < lines.length; j++) {
      const line = lines[j] as string
      if (j > i) {
        if (ELM_TAG_RE.test(line)) break
        if (line.trim().length > 0 && !/^\s/.test(line)) break
      }
      blockText.push(line)
      const scan = scanFieldLine(line, depth)
      for (const f of scan.fields) fields.add(f)
      depth = scan.depth
    }

    // Fields contributed by helper functions this encoder CONCATENATES into
    // the field list (`... ++ valueFields call`). Only `++` lines count: a
    // helper used as a field *value* (`( "calls", E.list encodeCallSpec ... )`)
    // builds a nested object, whose keys are not fields of this cmd. The
    // enclosing definition is skipped too -- its own entry is the union of
    // every branch in it, which would smear a multi-tag `case` encoder's
    // fields across all of its tags.
    const concatLines = blockText.filter((l) => l.includes('++'))
    const owner = owners[i] ?? null
    for (const [name, helperFields] of helpers) {
      if (name === owner || helperFields.size === 0) continue
      const re = new RegExp(`\\b${name}\\b`)
      if (concatLines.some((l) => re.test(l))) for (const f of helperFields) fields.add(f)
    }

    emitters.push({ tag, where: `${path}:${i + 1}`, fields: [...fields].sort() })
  }
  return emitters
}

/**
 * Sub tags an Elm module dispatches on: the branch literals of a
 * `case tag of` that is fed by `D.field "tag" D.string`. These are the tags
 * Elm can genuinely route -- a shim tag absent here and absent from the
 * module's documented wire format cannot reach any update function.
 */
export function elmSubCaseTags(rawText: string): Set<string> {
  const lines = stripElmComments(rawText).split('\n')
  const tags = new Set<string>()
  let armed = false
  let caseIndent = -1

  for (const line of lines) {
    const trimmed = line.trim()
    const indent = line.length - line.trimStart().length

    if (caseIndent >= 0) {
      if (trimmed.length > 0 && indent <= caseIndent) { caseIndent = -1 }
      else {
        const branch = /^"([A-Za-z0-9_]+)"\s*->/.exec(trimmed)
        if (branch) tags.add(branch[1] as string)
        if (/^_\s*->/.test(trimmed)) caseIndent = -1
        continue
      }
    }
    if (/D\.field\s+"tag"\s+D\.string/.test(line) || /field\s+"tag"\s+string/.test(line)) {
      armed = true
      continue
    }
    if (armed) {
      const c = /^case\s+[A-Za-z_][A-Za-z0-9_]*\s+of$/.exec(trimmed)
      if (c) { caseIndent = indent; armed = false }
      else if (trimmed.length > 0 && /^[a-zA-Z]/.test(line)) armed = false
    }
  }
  return tags
}

/**
 * Sub tags an Elm module NAMES, anywhere -- including the documented wire
 * format in a doc comment (`{ tag: "subscribed", id, status }`). Several
 * response decoders are payload-only by design (`Multicall.responseDecoder`,
 * `Subscription.eventDecoder`) and route by tag in consumer code, so the tag
 * appears only in prose. Prose still counts as "the Elm side knows this tag
 * exists"; a tag named in neither prose nor a case branch does not.
 */
export function elmMentionedTags(rawText: string): Set<string> {
  const tags = new Set<string>()
  const re = /["']?\btag["']?\s*[:=]\s*["']([A-Za-z0-9_]+)["']/g
  let m: RegExpExecArray | null
  while ((m = re.exec(rawText)) !== null) tags.add(m[1] as string)
  const branchRe = /^\s*"([A-Za-z0-9_]+)"\s*->/gm
  while ((m = branchRe.exec(rawText)) !== null) tags.add(m[1] as string)
  return tags
}

// ---------------------------------------------------------------------------
// Extraction -- shim side
// ---------------------------------------------------------------------------

/** `case 'x':` labels of the shim's single cmd switch. */
export function shimCmdCases(rawText: string): Set<string> {
  const src = stripJsComments(rawText)
  const tags = new Set<string>()
  const re = /case\s+['"]([A-Za-z0-9_]+)['"]\s*:/g
  let m: RegExpExecArray | null
  while ((m = re.exec(src)) !== null) tags.add(m[1] as string)
  return tags
}

/**
 * Fields a top-level JS function reads off its first parameter. Lets the cmd
 * field scan see through `_calldataOf(cmd)`, which consumes `data`, `method`
 * and `args` on behalf of three case blocks.
 */
function jsHelperFields(src: string, name: string): Set<string> {
  const fields = new Set<string>()
  const at = src.indexOf(`function ${name}(`)
  if (at < 0) return fields
  const openParen = src.indexOf('(', at)
  const param = /\(\s*([A-Za-z0-9_$]+)/.exec(src.slice(openParen))?.[1]
  if (!param) return fields

  // Body: from the first `{` after the parameter list, to its matching `}`.
  let i = openParen
  let depth = 0
  for (; i < src.length; i++) {
    if (src[i] === '(') depth++
    else if (src[i] === ')') { depth--; if (depth === 0) break }
  }
  const bodyStart = src.indexOf('{', i)
  if (bodyStart < 0) return fields
  depth = 0
  let bodyEnd = bodyStart
  for (let j = bodyStart; j < src.length; j++) {
    if (src[j] === '{') depth++
    else if (src[j] === '}') { depth--; if (depth === 0) { bodyEnd = j; break } }
  }
  const body = src.slice(bodyStart, bodyEnd)
  const re = new RegExp(`\\b${param}\\.([A-Za-z0-9_]+)`, 'g')
  let m: RegExpExecArray | null
  while ((m = re.exec(body)) !== null) if (m[1] !== 'tag') fields.add(m[1] as string)
  return fields
}

/** `cmd.<field>` reads inside each cmd case block. */
export function shimCmdFields(rawText: string): Map<string, Set<string>> {
  const src = stripJsComments(rawText)
  const lines = src.split('\n')
  const out = new Map<string, Set<string>>()
  let current: string | null = null

  for (const line of lines) {
    const c = /case\s+['"]([A-Za-z0-9_]+)['"]\s*:/.exec(line)
    if (c) { current = c[1] as string; if (!out.has(current)) out.set(current, new Set()); continue }
    if (/^\s*default\s*:/.test(line)) { current = null; continue }
    if (current === null) continue
    const re = /\bcmd\.([A-Za-z0-9_]+)/g
    let m: RegExpExecArray | null
    while ((m = re.exec(line)) !== null) {
      if (m[1] !== 'tag') (out.get(current) as Set<string>).add(m[1] as string)
    }
    // Destructured reads: `const { rdns, requestId } = cmd`
    const d = /const\s*\{([^}]*)\}\s*=\s*cmd\b/.exec(line)
    if (d) {
      for (const part of (d[1] as string).split(',')) {
        const name = part.trim().split(':')[0]?.trim()
        if (name && name !== 'tag') (out.get(current) as Set<string>).add(name)
      }
    }
    // Whole-cmd handoff: `_calldataOf(cmd)` reads fields on our behalf.
    const h = /\b([A-Za-z0-9_$]+)\s*\(\s*cmd\s*\)/.exec(line)
    if (h) for (const f of jsHelperFields(src, h[1] as string)) (out.get(current) as Set<string>).add(f)
  }
  return out
}

/**
 * Places the extractors above may be blind. A detector that silently fails to
 * parse an emitter is worse than no detector, so anything tag-shaped that the
 * patterns did not claim is surfaced as an advisory.
 */
export function extractionBlindSpots(sources: Sources): string[] {
  const notes: string[] = []

  for (const f of sources.elm) {
    const lines = stripElmComments(f.text).split('\n')
    lines.forEach((line, i) => {
      // Encoder-shaped: a `( "tag"` tuple entry. `D.field "tag" D.string` is
      // the decoder side and is handled by elmSubCaseTags, not here.
      if (!/\(\s*"tag"|"tag"\s*,/.test(line)) return
      if (ELM_TAG_RE.test(line)) return
      notes.push(`${f.path}:${i + 1} looks like a tag emitter this checker cannot parse: ${line.trim()}`)
    })
  }

  const shim = stripJsComments(sources.shim)
  const re = /web3Sub\.send\(\s*([A-Za-z0-9_$]+)\s*\)/g
  let m: RegExpExecArray | null
  while ((m = re.exec(shim)) !== null) {
    const upToHere = shim.slice(0, m.index)
    const line = upToHere.split('\n').length
    notes.push(`js/elm-web3-ports.ts:${line} sends a pre-built object (\`${m[1]}\`); its tag is only visible where that object is built`)
  }
  return notes
}

/** `tag: 'x'` on every message the shim sends back to Elm. */
export function shimSubTags(rawText: string): Set<string> {
  const src = stripJsComments(rawText)
  const tags = new Set<string>()
  const re = /\btag\s*:\s*['"]([A-Za-z0-9_]+)['"]/g
  let m: RegExpExecArray | null
  while ((m = re.exec(src)) !== null) tags.add(m[1] as string)
  // The `Web3Cmd` union in the same file also uses `tag: "x"` members; those
  // are cmd tags, not emitted subs. Subtract them.
  for (const t of shimCmdUnionTags(src)) tags.delete(t)
  return tags
}

/** Tag members of the local `Web3Cmd` type union inside the shim source. */
function shimCmdUnionTags(strippedSrc: string): Set<string> {
  const tags = new Set<string>()
  const start = strippedSrc.indexOf('type Web3Cmd')
  if (start < 0) return tags
  const rest = strippedSrc.slice(start)
  const end = rest.search(/\n(export\s+)?(type|interface|function|const|declare)\s/)
  const block = end > 0 ? rest.slice(0, end) : rest
  const re = /\btag\s*:\s*['"]([A-Za-z0-9_]+)['"]/g
  let m: RegExpExecArray | null
  while ((m = re.exec(block)) !== null) tags.add(m[1] as string)
  return tags
}

// ---------------------------------------------------------------------------
// Extraction -- .d.ts (the published type contract)
// ---------------------------------------------------------------------------

export function dtsTags(rawText: string): { cmd: Set<string>; sub: Set<string> } {
  const src = stripJsComments(rawText)
  const grab = (name: string): Set<string> => {
    const tags = new Set<string>()
    const start = src.indexOf(`type ${name} =`)
    if (start < 0) return tags
    const rest = src.slice(start)
    const end = rest.search(/\n(export\s+)?(type|interface|function|const|declare)\s/)
    const block = end > 0 ? rest.slice(0, end) : rest
    const re = /\btag\s*:\s*['"]([A-Za-z0-9_]+)['"]/g
    let m: RegExpExecArray | null
    while ((m = re.exec(block)) !== null) tags.add(m[1] as string)
    return tags
  }
  return { cmd: grab('Web3Cmd'), sub: grab('Web3Sub') }
}

// ---------------------------------------------------------------------------
// Analysis
// ---------------------------------------------------------------------------

function sorted(s: Iterable<string>): string[] {
  return [...s].sort()
}

export function analyse(sources: Sources): Report {
  const findings: Finding[] = []
  const advisories: string[] = []

  // --- Cmd direction -------------------------------------------------------
  const emitters: Emitter[] = []
  for (const f of sources.elm) emitters.push(...elmCmdEmitters(f.path, f.text))

  const elmCmdTags = new Set(emitters.map((e) => e.tag))
  const shimCmd = shimCmdCases(sources.shim)

  for (const tag of sorted(elmCmdTags)) {
    if (!shimCmd.has(tag)) {
      const where = emitters.filter((e) => e.tag === tag).map((e) => e.where).join(', ')
      findings.push({
        code: 'CMD-1',
        tag,
        detail: `Elm emits cmd '${tag}' (${where}) but the shim has no case for it -- the command is silently dropped`,
      })
    }
  }
  for (const tag of sorted(shimCmd)) {
    if (!elmCmdTags.has(tag)) {
      findings.push({
        code: 'CMD-2',
        tag,
        detail: `shim handles cmd '${tag}' but no Elm module emits it -- dead handler, or the Elm tag was renamed`,
      })
    }
  }

  // Tag collisions: same cmd tag, different payloads.
  const byTag = new Map<string, Emitter[]>()
  for (const e of emitters) {
    const list = byTag.get(e.tag) ?? []
    list.push(e)
    byTag.set(e.tag, list)
  }
  for (const tag of sorted(byTag.keys())) {
    const list = byTag.get(tag) as Emitter[]
    if (list.length < 2) continue
    const shapes = new Set(list.map((e) => e.fields.join(',')))
    if (shapes.size > 1) {
      const desc = list.map((e) => `${e.where} {${e.fields.join(', ')}}`).join('  vs  ')
      findings.push({
        code: 'CMD-3',
        tag,
        detail: `cmd '${tag}' is emitted with incompatible payloads: ${desc}`,
      })
    } else {
      advisories.push(`cmd '${tag}' has ${list.length} emitters with identical payloads (${list.map((e) => e.where).join(', ')})`)
    }
  }

  // --- Sub direction -------------------------------------------------------
  const shimSub = shimSubTags(sources.shim)
  const elmCase = new Set<string>()
  const elmKnown = new Set<string>()
  for (const f of sources.elm) {
    for (const t of elmSubCaseTags(f.text)) { elmCase.add(t); elmKnown.add(t) }
    for (const t of elmMentionedTags(f.text)) elmKnown.add(t)
  }

  for (const tag of sorted(shimSub)) {
    if (!elmKnown.has(tag)) {
      findings.push({
        code: 'SUB-1',
        tag,
        detail: `shim sends sub '${tag}' but no Elm module decodes or documents it -- the message cannot reach any update function`,
      })
    } else if (!elmCase.has(tag)) {
      advisories.push(`sub '${tag}' is documented in Elm but never matched in a tag-dispatching decoder (payload-only decoder; consumers must route it)`)
    }
  }
  for (const tag of sorted(elmCase)) {
    if (!shimSub.has(tag)) {
      findings.push({
        code: 'SUB-2',
        tag,
        detail: `Elm decodes sub '${tag}' but the shim never sends it -- dead branch, or the shim tag was renamed`,
      })
    }
  }

  // --- Published .d.ts contract -------------------------------------------
  if (sources.dts !== null) {
    const dts = dtsTags(sources.dts)
    for (const tag of sorted(shimCmd)) {
      if (!dts.cmd.has(tag)) {
        findings.push({ code: 'DTS-CMD-MISSING', tag, detail: `.d.ts Web3Cmd is missing cmd '${tag}' that the shim handles` })
      }
    }
    for (const tag of sorted(dts.cmd)) {
      if (!shimCmd.has(tag)) {
        findings.push({ code: 'DTS-CMD-EXTRA', tag, detail: `.d.ts Web3Cmd declares cmd '${tag}' that the shim does not handle` })
      }
    }
    for (const tag of sorted(shimSub)) {
      if (!dts.sub.has(tag)) {
        findings.push({ code: 'DTS-SUB-MISSING', tag, detail: `.d.ts Web3Sub is missing sub '${tag}' that the shim sends` })
      }
    }
    for (const tag of sorted(dts.sub)) {
      if (!shimSub.has(tag)) {
        findings.push({ code: 'DTS-SUB-EXTRA', tag, detail: `.d.ts Web3Sub declares sub '${tag}' that the shim never sends` })
      }
    }
  }

  // --- Advisory: cmd field-level drift ------------------------------------
  const shimFields = shimCmdFields(sources.shim)
  for (const tag of sorted(elmCmdTags)) {
    if (!shimCmd.has(tag)) continue
    const read = shimFields.get(tag) ?? new Set<string>()
    const sent = new Set<string>()
    for (const e of emitters) if (e.tag === tag) for (const f of e.fields) sent.add(f)
    const ignoredRead = new Set(['args', 'method'])
    const neverSent = sorted(read).filter((f) => !sent.has(f) && !ignoredRead.has(f))
    const neverRead = sorted(sent).filter((f) => !read.has(f))
    if (neverSent.length > 0) {
      advisories.push(`cmd '${tag}': shim reads ${neverSent.map((f) => `cmd.${f}`).join(', ')} which no Elm emitter sends`)
    }
    if (neverRead.length > 0) {
      advisories.push(`cmd '${tag}': Elm sends ${neverRead.join(', ')} which the shim never reads`)
    }
  }

  advisories.push(...extractionBlindSpots(sources))

  return {
    findings,
    advisories,
    stats: {
      elmCmdTags: elmCmdTags.size,
      shimCmdTags: shimCmd.size,
      shimSubTags: shimSub.size,
      elmSubTags: elmCase.size,
    },
  }
}

// ---------------------------------------------------------------------------
// Loading the working tree
// ---------------------------------------------------------------------------

const ROOT = dirname(dirname(import.meta.path))

function walkElm(dir: string, acc: string[] = []): string[] {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry)
    if (statSync(full).isDirectory()) walkElm(full, acc)
    else if (entry.endsWith('.elm')) acc.push(full)
  }
  return acc
}

export function loadSources(root: string = ROOT): Sources {
  const elm = walkElm(join(root, 'src')).map((p) => ({
    path: relative(root, p),
    text: readFileSync(p, 'utf8'),
  }))
  const dtsPath = join(root, 'js', 'elm-web3-ports.d.ts')
  return {
    elm,
    shim: readFileSync(join(root, 'js', 'elm-web3-ports.ts'), 'utf8'),
    dts: existsSync(dtsPath) ? readFileSync(dtsPath, 'utf8') : null,
  }
}

// ---------------------------------------------------------------------------
// Self-test: hermetic fixtures, one injected drift per failure class
// ---------------------------------------------------------------------------

const FIXTURE_ELM = `module Fake exposing (encode)

import Json.Encode as E


{-| Encode a balance request. Replies with { tag: "balance", id, wei }.
-}
encode : String -> E.Value
encode addr =
    E.object
        [ ( "tag", E.string "getBalance" )
        , ( "address", E.string addr )
        , ( "id", E.string "1" )
        ]


decoder : D.Decoder Msg
decoder =
    D.field "tag" D.string
        |> D.andThen
            (\\tag ->
                case tag of
                    "balance" ->
                        D.map GotBalance (D.field "wei" D.string)

                    _ ->
                        D.fail "nope"
            )
`

const FIXTURE_SHIM = `export type Web3Cmd = { readonly tag: "getBalance"; readonly id: string }

export function setupPorts(app) {
  app.ports.web3Cmd.subscribe(async (cmd) => {
    switch (cmd.tag) {
      // A comment mentioning tag: 'ignoredByStripper' must not count.
      case 'getBalance': {
        const hex = await rpc('eth_getBalance', [cmd.address])
        app.ports.web3Sub.send({ tag: 'balance', id: cmd.id, wei: hex })
        break
      }
    }
  })
}
`

const FIXTURE_DTS = `export type Web3Cmd =
  | { readonly tag: 'getBalance'; readonly id: string; readonly address: string }

export type Web3Sub =
  | { readonly tag: 'balance'; readonly id: string; readonly wei: string }
`

function fixture(overrides: Partial<{ elm: string; shim: string; dts: string }> = {}): Sources {
  return {
    elm: [{ path: 'src/Fake.elm', text: overrides.elm ?? FIXTURE_ELM }],
    shim: overrides.shim ?? FIXTURE_SHIM,
    dts: overrides.dts ?? FIXTURE_DTS,
  }
}

interface SelfTestCase {
  readonly name: string
  readonly sources: Sources
  readonly expect: FailureCode
  readonly expectTag: string
}

function selfTestCases(real: Sources): SelfTestCase[] {
  const cases: SelfTestCase[] = [
    {
      name: 'shim drops a handler Elm still emits',
      sources: fixture({ shim: FIXTURE_SHIM.replace("case 'getBalance':", "case 'getBalanceV2':") }),
      expect: 'CMD-1',
      expectTag: 'getBalance',
    },
    {
      name: 'shim handles a cmd nobody emits',
      sources: fixture({ shim: FIXTURE_SHIM.replace("case 'getBalance': {", "case 'ghostCmd': { break }\n      case 'getBalance': {") }),
      expect: 'CMD-2',
      expectTag: 'ghostCmd',
    },
    {
      name: 'two Elm sites emit one cmd tag with different payloads',
      sources: fixture({
        elm:
          FIXTURE_ELM +
          `

encodeOther : String -> E.Value
encodeOther a =
    E.object
        [ ( "tag", E.string "getBalance" )
        , ( "who", E.string a )
        ]
`,
      }),
      expect: 'CMD-3',
      expectTag: 'getBalance',
    },
    {
      name: 'shim sends a sub no Elm module knows',
      sources: fixture({
        shim: FIXTURE_SHIM.replace(
          "app.ports.web3Sub.send({ tag: 'balance'",
          "app.ports.web3Sub.send({ tag: 'ghostSub', id: cmd.id })\n        app.ports.web3Sub.send({ tag: 'balance'",
        ),
      }),
      expect: 'SUB-1',
      expectTag: 'ghostSub',
    },
    {
      name: 'shim renames a sub Elm still decodes',
      sources: fixture({ shim: FIXTURE_SHIM.replace("tag: 'balance'", "tag: 'balanceV2'") }),
      expect: 'SUB-2',
      expectTag: 'balance',
    },
    {
      name: '.d.ts loses a cmd the shim handles',
      sources: fixture({ dts: FIXTURE_DTS.replace("'getBalance'", "'getBalanceLegacy'") }),
      expect: 'DTS-CMD-MISSING',
      expectTag: 'getBalance',
    },
    {
      name: '.d.ts loses a sub the shim sends',
      sources: fixture({ dts: FIXTURE_DTS.replace("| { readonly tag: 'balance'", "| { readonly tag: 'balanceLegacy'") }),
      expect: 'DTS-SUB-MISSING',
      expectTag: 'balance',
    },
  ]

  // Same injection, against the REAL sources: proves the extractors work on
  // the actual files and not just on the fixtures.
  const realCase = shimCmdCases(real.shim).has('getBalance')
  if (realCase) {
    cases.push({
      name: 'REAL sources with the getBalance handler deleted',
      sources: { ...real, shim: real.shim.replace("case 'getBalance':", "case 'getBalanceRenamed':") },
      expect: 'CMD-1',
      expectTag: 'getBalance',
    })
  }
  return cases
}

function runSelfTest(): number {
  const real = loadSources()
  let failures = 0

  // 1. Clean fixtures must be silent. A checker that always fires is as
  //    useless as one that never does.
  const clean = analyse(fixture())
  if (clean.findings.length === 0) {
    console.log('  ok   clean fixture reports nothing')
  } else {
    failures++
    console.log('  FAIL clean fixture reported findings it should not have:')
    for (const f of clean.findings) console.log(`         [${f.code}] ${f.detail}`)
  }

  // 2. Every injected drift must be caught, with the right code and tag.
  for (const c of selfTestCases(real)) {
    const report = analyse(c.sources)
    const hit = report.findings.find((f) => f.code === c.expect && f.tag === c.expectTag)
    if (hit) {
      console.log(`  ok   ${c.name} -> ${c.expect} ${c.expectTag}`)
    } else {
      failures++
      console.log(`  FAIL ${c.name}: expected ${c.expect} for '${c.expectTag}', got:`)
      if (report.findings.length === 0) console.log('         (nothing)')
      for (const f of report.findings) console.log(`         [${f.code}] ${f.tag}`)
    }
  }

  console.log('')
  if (failures === 0) {
    console.log('SELF-TEST PASS -- the checker detects every injected drift and stays quiet on clean input.')
    return 0
  }
  console.log(`SELF-TEST FAIL -- ${failures} case(s) not detected. The checker is not trustworthy.`)
  return 1
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

function main(): number {
  const args = new Set(process.argv.slice(2))

  if (args.has('--self-test')) {
    console.log('port parity self-test (injected drift must be detected)')
    console.log('')
    return runSelfTest()
  }

  const report = analyse(loadSources())
  const s = report.stats
  console.log(
    `port parity: ${s.elmCmdTags} Elm cmd tags / ${s.shimCmdTags} shim handlers / ` +
      `${s.shimSubTags} shim sub tags / ${s.elmSubTags} Elm sub branches`,
  )

  if (args.has('--verbose') || args.has('-v')) {
    console.log('')
    for (const a of report.advisories) console.log(`  note  ${a}`)
  }

  if (report.findings.length === 0) {
    console.log('OK -- every port tag agrees in both directions.')
    return 0
  }

  console.log('')
  for (const f of report.findings) console.log(`  [${f.code}] ${f.detail}`)
  console.log('')
  console.log(`FAIL -- ${report.findings.length} port boundary mismatch(es).`)
  if (!args.has('--verbose') && !args.has('-v') && report.advisories.length > 0) {
    console.log(`(${report.advisories.length} advisory note(s) hidden; re-run with --verbose)`)
  }
  return 1
}

// Guarded so the extractors above can be imported by other scripts (and by
// the self-test) without running the check.
if (import.meta.main) process.exit(main())
