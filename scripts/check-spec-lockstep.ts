#!/usr/bin/env bun
/**
 * check-spec-lockstep.ts -- machine enforcement of CONTRIBUTING.md rule 2.
 *
 *   > **State machines change in lockstep.** If you touch
 *   > `Wallet.update` / `Transaction.update` / `Sign.signUpdate`, update the
 *   > matching spec in `proofs/tla/`, re-run `check-tla.sh`, and update the
 *   > action mapping in `proofs/TLA_CONFORMANCE.md`. A spec that models a
 *   > machine the code no longer implements is a bug.
 *
 * That rule was violated by the work that became 2.0.0: 837991a (2026-07-07)
 * rewrote `src/Web3/Wallet.elm` around `RequestId`-tracked connect state and
 * 1657054 added supersede semantics on top; neither touched
 * `proofs/tla/WalletSpec.tla`, which went on modeling the pre-2.0 machine.
 * The release commit 625d2d1 (2026-07-16) then published the proofs page
 * advertising a model check of a state machine that no longer existed.
 * Nothing in CI noticed for twenty days. This script is what notices.
 *
 * Prove it is real, against the commits that caused the problem:
 *
 *     bun run scripts/check-spec-lockstep.ts --range 837991a~1..837991a
 *     bun run scripts/check-spec-lockstep.ts --range 1657054~1..1657054
 *     bun run scripts/check-spec-lockstep.ts --range 837991a~1..625d2d1
 *     # -> exit 1, "Wallet.elm changed; WalletSpec.tla did not"
 *
 * And note what it does NOT flag: `--range 625d2d1~1..625d2d1` passes, because
 * that commit's only change to Wallet.elm is a five-line doc comment. The
 * exemption below is why, and that range is its regression test.
 *
 * USAGE
 *   bun run scripts/check-spec-lockstep.ts                 # auto (see below)
 *   bun run scripts/check-spec-lockstep.ts --range A..B    # explicit range
 *   bun run scripts/check-spec-lockstep.ts --range A...B   # merge-base range
 *   bun run scripts/check-spec-lockstep.ts --worktree      # uncommitted work
 *   bun run scripts/check-spec-lockstep.ts --staged        # index only
 *   bun run scripts/check-spec-lockstep.ts --self-test     # test the detector
 *
 * AUTO MODE picks the first of:
 *   1. $LOCKSTEP_RANGE, if set.
 *   2. A pull-request range built from $GITHUB_BASE_REF (merge-base ... HEAD).
 *   3. The working tree, when it has uncommitted tracked changes.
 *   4. origin/<default-branch>..HEAD, when HEAD is ahead of it.
 *   5. Nothing to check -> pass.
 *
 * COMMENT-ONLY CHANGES are exempt, and the exemption is computed, not
 * trusted: both revisions of the source file are stripped of Elm line and
 * (nesting) block comments with string- and char-literal awareness, then
 * whitespace-normalised and compared. Identical code => no spec obligation.
 * Anything the stripper cannot account for fails closed, i.e. is treated as
 * a code change. Without this, the ASCII-doc-comment sweep (5546420) would
 * have demanded a spec edit for changing "--" into "-", the guard would have
 * been bypassed once, and bypassing would have become the habit.
 *
 * EXIT CODES
 *   0  lockstep holds (or there was nothing to check)
 *   1  a state machine changed without its spec
 *   2  the script could not determine what changed (git failure, bad range)
 */

import { existsSync, readFileSync } from "node:fs";

type Pair = {
  readonly source: string;
  readonly spec: string;
  readonly machine: string;
};

/** CONTRIBUTING.md rule 2, as data. */
const PAIRS: readonly Pair[] = [
  {
    source: "src/Web3/Wallet.elm",
    spec: "proofs/tla/WalletSpec.tla",
    machine: "Web3.Wallet.update / startConnect / timeoutConnect",
  },
  {
    source: "src/Web3/Transaction.elm",
    spec: "proofs/tla/TransactionSpec.tla",
    machine: "Web3.Transaction.update",
  },
  {
    source: "src/Web3/Sign.elm",
    spec: "proofs/tla/SignSpec.tla",
    machine: "Web3.Sign.signUpdate / startSign",
  },
];

/** Rule 2 also requires the action mapping to be re-audited. Missing it is a
 *  warning, not a failure: the mapping can legitimately be unchanged when a
 *  spec edit only touches comments or property names. */
const CONFORMANCE_DOC = "proofs/TLA_CONFORMANCE.md";

// ---------------------------------------------------------------- git ----

type GitResult = { readonly ok: boolean; readonly out: string; readonly code: number };

function git(args: readonly string[]): GitResult {
  const proc = Bun.spawnSync(["git", ...args], { stdout: "pipe", stderr: "pipe" });
  return {
    ok: proc.exitCode === 0,
    out: new TextDecoder().decode(proc.stdout),
    code: proc.exitCode ?? 1,
  };
}

function gitLines(args: readonly string[]): string[] {
  const r = git(args);
  if (!r.ok) return [];
  return r.out.split("\n").map((l) => l.trim()).filter((l) => l.length > 0);
}

/** File content at a revision, or null when the path does not exist there. */
function blobAt(rev: string, path: string): string | null {
  const r = git(["show", `${rev}:${path}`]);
  return r.ok ? r.out : null;
}

// ------------------------------------------------------- comment strip ----

/**
 * Remove Elm comments from `src`.
 *
 * Handles: `--` line comments, `{- -}` block comments (which NEST in Elm, so
 * depth is tracked), `{-| -}` doc comments, "..." strings, triple-quoted
 * """...""" strings, 'c' char literals, and backslash escapes inside both.
 * Comment text is replaced by a single space so tokens cannot fuse.
 *
 * Returns null if the input ends inside a string or block comment -- that
 * means either the file does not parse or this stripper mis-tracked state,
 * and either way the caller must fall back to "assume it is a code change".
 */
export function stripElmComments(src: string): string | null {
  let out = "";
  let i = 0;
  let blockDepth = 0;
  const n = src.length;

  while (i < n) {
    const two = src.slice(i, i + 2);

    if (blockDepth > 0) {
      if (two === "{-") { blockDepth++; i += 2; continue; }
      if (two === "-}") { blockDepth--; i += 2; if (blockDepth === 0) out += " "; continue; }
      if (src[i] === "\n") out += "\n";
      i++;
      continue;
    }

    if (two === "{-") { blockDepth = 1; i += 2; continue; }

    if (two === "--") {
      // Line comment: skip to end of line, keeping the newline.
      while (i < n && src[i] !== "\n") i++;
      out += " ";
      continue;
    }

    if (src.slice(i, i + 3) === '"""') {
      const end = src.indexOf('"""', i + 3);
      if (end === -1) return null;
      out += src.slice(i, end + 3);
      i = end + 3;
      continue;
    }

    if (src[i] === '"' || src[i] === "'") {
      const quote = src[i];
      let j = i + 1;
      while (j < n) {
        if (src[j] === "\\") { j += 2; continue; }
        if (src[j] === quote) { j++; break; }
        if (src[j] === "\n") return null; // unterminated literal
        j++;
      }
      if (j > n) return null;
      out += src.slice(i, j);
      i = j;
      continue;
    }

    out += src[i];
    i++;
  }

  if (blockDepth !== 0) return null;
  return out;
}

/** Collapse all runs of whitespace so reflowed code compares equal. */
export function normalise(src: string): string {
  return src.replace(/\s+/g, " ").trim();
}

/**
 * True when `before` and `after` differ only in comments and whitespace.
 * Fails closed: a null on either side (missing file, unparseable) is false.
 */
export function isCommentOnlyChange(before: string | null, after: string | null): boolean {
  if (before === null || after === null) return false;
  const a = stripElmComments(before);
  const b = stripElmComments(after);
  if (a === null || b === null) return false;
  return normalise(a) === normalise(b);
}

// ------------------------------------------------------------ verdict ----

export type Verdict = {
  readonly violations: readonly { pair: Pair; note: string }[];
  readonly warnings: readonly string[];
  readonly exempt: readonly string[];
};

/**
 * The whole decision, as a pure function of a changed-file set plus a way to
 * read the two revisions of a path. Everything above is plumbing that
 * produces the inputs; `--self-test` drives this directly.
 */
export function evaluate(
  changed: ReadonlySet<string>,
  readPair: (path: string) => { before: string | null; after: string | null },
): Verdict {
  const violations: { pair: Pair; note: string }[] = [];
  const warnings: string[] = [];
  const exempt: string[] = [];

  for (const pair of PAIRS) {
    if (!changed.has(pair.source)) continue;

    const { before, after } = readPair(pair.source);
    if (isCommentOnlyChange(before, after)) {
      exempt.push(`${pair.source} (comments/whitespace only)`);
      continue;
    }

    if (!changed.has(pair.spec)) {
      violations.push({
        pair,
        note: `${pair.source} changed; ${pair.spec} did not`,
      });
      continue;
    }

    if (!changed.has(CONFORMANCE_DOC)) {
      warnings.push(
        `${pair.source} and ${pair.spec} both changed, but ${CONFORMANCE_DOC} did not -- ` +
          `re-check the action mapping for ${pair.machine}`,
      );
    }
  }

  return { violations, warnings, exempt };
}

// -------------------------------------------------------------- modes ----

type Mode =
  | { readonly kind: "range"; readonly from: string; readonly to: string; readonly label: string }
  | { readonly kind: "worktree" }
  | { readonly kind: "staged" }
  | { readonly kind: "none"; readonly why: string };

function revExists(rev: string): boolean {
  return git(["rev-parse", "--verify", "--quiet", `${rev}^{commit}`]).ok;
}

function parseRange(range: string): { from: string; to: string } | null {
  const three = range.indexOf("...");
  if (three !== -1) {
    const left = range.slice(0, three) || "HEAD";
    const right = range.slice(three + 3) || "HEAD";
    const mb = git(["merge-base", left, right]);
    if (!mb.ok) return null;
    return { from: mb.out.trim(), to: right };
  }
  const two = range.indexOf("..");
  if (two !== -1) {
    const from = range.slice(0, two) || "HEAD";
    const to = range.slice(two + 2) || "HEAD";
    if (!revExists(from) || !revExists(to)) return null;
    return { from, to };
  }
  // A bare revision means "that commit against its parent".
  if (!revExists(range) || !revExists(`${range}~1`)) return null;
  return { from: `${range}~1`, to: range };
}

function defaultBranchRef(): string | null {
  const head = git(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"]);
  if (head.ok) return head.out.trim();
  for (const candidate of ["origin/master", "origin/main"]) {
    if (git(["rev-parse", "--verify", "--quiet", candidate]).ok) return candidate;
  }
  return null;
}

function autoMode(): Mode {
  const envRange = (process.env.LOCKSTEP_RANGE ?? "").trim();
  if (envRange.length > 0) {
    const parsed = parseRange(envRange);
    // An unresolvable range (shallow clone, force-push, first push of a
    // branch) falls through to the next strategy rather than failing the
    // build on a plumbing problem.
    if (parsed) return { kind: "range", ...parsed, label: `$LOCKSTEP_RANGE (${envRange})` };
    console.log(`  note: LOCKSTEP_RANGE=${envRange} is not resolvable here; falling back`);
  }

  const base = (process.env.GITHUB_BASE_REF ?? "").trim();
  if (base.length > 0) {
    const parsed = parseRange(`origin/${base}...HEAD`);
    if (parsed) {
      return { kind: "range", ...parsed, label: `pull request against ${base}` };
    }
  }

  const dirty = gitLines(["diff", "--name-only", "HEAD"]);
  if (dirty.length > 0) return { kind: "worktree" };

  const branch = defaultBranchRef();
  if (branch) {
    const ahead = gitLines(["rev-list", `${branch}..HEAD`]);
    if (ahead.length > 0) {
      const parsed = parseRange(`${branch}...HEAD`);
      if (parsed) {
        return { kind: "range", ...parsed, label: `${branch}..HEAD (${ahead.length} commit(s))` };
      }
    }
  }

  return { kind: "none", why: "clean tree, nothing ahead of the default branch" };
}

function collect(mode: Mode): {
  changed: Set<string>;
  readPair: (path: string) => { before: string | null; after: string | null };
  description: string;
} {
  switch (mode.kind) {
    case "range": {
      const files = gitLines(["diff", "--name-only", `${mode.from}..${mode.to}`]);
      return {
        changed: new Set(files),
        readPair: (p) => ({ before: blobAt(mode.from, p), after: blobAt(mode.to, p) }),
        description: `commit range ${mode.from.slice(0, 12)}..${mode.to} -- ${mode.label}`,
      };
    }
    case "staged": {
      const files = gitLines(["diff", "--cached", "--name-only"]);
      return {
        changed: new Set(files),
        readPair: (p) => ({ before: blobAt("HEAD", p), after: blobAt("", p) }),
        description: "staged changes (index vs HEAD)",
      };
    }
    case "worktree": {
      const tracked = gitLines(["diff", "--name-only", "HEAD"]);
      const untracked = gitLines(["ls-files", "--others", "--exclude-standard"]);
      const root = git(["rev-parse", "--show-toplevel"]).out.trim();
      return {
        changed: new Set([...tracked, ...untracked]),
        readPair: (p) => {
          const abs = `${root}/${p}`;
          return {
            before: blobAt("HEAD", p),
            after: existsSync(abs) ? readFileSync(abs, "utf8") : null,
          };
        },
        description: "uncommitted changes (working tree vs HEAD)",
      };
    }
    case "none":
      return { changed: new Set(), readPair: () => ({ before: null, after: null }), description: mode.why };
  }
}

// ---------------------------------------------------------- self-test ----

/**
 * Tests the detector itself against fixtures. Every case states what it
 * expects; a case that does not behave as stated means the guard cannot be
 * trusted and this exits 1. All-pass exits 0.
 */
function selfTest(): number {
  const codeV1 = [
    "module Web3.Wallet exposing (State(..))",
    "",
    "{-| Wallet connection state. -}",
    "type State",
    "    = Disconnected",
    "    | Connecting -- no request id yet",
    "",
    'label : String',
    'label =',
    '    "-- not a comment {- nor this -}"',
  ].join("\n");

  // Same code, every comment reworded, whitespace reflowed.
  const codeV1DocsOnly = [
    "module Web3.Wallet exposing (State(..))",
    "",
    "",
    "{-| Wallet connection state, described differently.",
    "",
    "    Multi-line, nested {- block -} and all.",
    "-}",
    "type State",
    "    = Disconnected",
    "    | Connecting -- reworded trailing note",
    "",
    'label : String',
    'label =',
    '    "-- not a comment {- nor this -}"',
  ].join("\n");

  // Real code change: the 2.0.0 shape.
  const codeV2 = codeV1.replace("| Connecting -- no request id yet", "| Connecting RequestId");

  const cases: {
    name: string;
    changed: string[];
    before: string;
    after: string;
    expectViolation: boolean;
    expectExempt: boolean;
  }[] = [
    {
      name: "drift: Wallet.elm code change, spec untouched",
      changed: ["src/Web3/Wallet.elm", "README.md"],
      before: codeV1,
      after: codeV2,
      expectViolation: true,
      expectExempt: false,
    },
    {
      name: "lockstep: Wallet.elm and WalletSpec.tla both changed",
      changed: ["src/Web3/Wallet.elm", "proofs/tla/WalletSpec.tla", CONFORMANCE_DOC],
      before: codeV1,
      after: codeV2,
      expectViolation: false,
      expectExempt: false,
    },
    {
      name: "exempt: comment/whitespace-only change to Wallet.elm",
      changed: ["src/Web3/Wallet.elm"],
      before: codeV1,
      after: codeV1DocsOnly,
      expectViolation: false,
      expectExempt: true,
    },
    {
      name: "fail closed: source added with no previous revision",
      changed: ["src/Web3/Wallet.elm"],
      before: "",
      after: codeV2,
      expectViolation: true,
      expectExempt: false,
    },
    {
      name: "untouched machine is not implicated",
      changed: ["src/Web3/Units.elm"],
      before: codeV1,
      after: codeV2,
      expectViolation: false,
      expectExempt: false,
    },
  ];

  let bad = 0;
  console.log("check-spec-lockstep --self-test\n");
  for (const c of cases) {
    const verdict = evaluate(new Set(c.changed), (p) =>
      p === "src/Web3/Wallet.elm"
        ? { before: c.before === "" ? null : c.before, after: c.after }
        : { before: null, after: null },
    );
    const gotViolation = verdict.violations.length > 0;
    const gotExempt = verdict.exempt.length > 0;
    const ok = gotViolation === c.expectViolation && gotExempt === c.expectExempt;
    if (!ok) bad++;
    console.log(
      `  ${ok ? "ok  " : "FAIL"}  ${c.name}\n` +
        `        expected violation=${c.expectViolation} exempt=${c.expectExempt}; ` +
        `got violation=${gotViolation} exempt=${gotExempt}`,
    );
  }

  console.log("");
  if (bad > 0) {
    console.log(`${bad} self-test case(s) failed -- the detector is NOT trustworthy.`);
    return 1;
  }
  console.log("All self-test cases behaved as specified.");
  console.log(
    "For an end-to-end red run against the real defect:\n" +
      "  bun run scripts/check-spec-lockstep.ts --range 837991a~1..837991a   # exits 1",
  );
  return 0;
}

// --------------------------------------------------------------- main ----

function main(): number {
  const argv = process.argv.slice(2);

  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(
      [
        "check-spec-lockstep.ts -- CONTRIBUTING.md rule 2, enforced.",
        "",
        "  (no args)          auto: PR range, else working tree, else branch range",
        "  --range A..B       explicit commit range (A...B uses the merge base)",
        "  --worktree         uncommitted changes",
        "  --staged           staged changes",
        "  --self-test        test the detector against fixtures",
      ].join("\n"),
    );
    return 0;
  }

  if (argv.includes("--self-test")) return selfTest();

  if (!git(["rev-parse", "--git-dir"]).ok) {
    console.error("not a git repository -- cannot determine what changed");
    return 2;
  }

  let mode: Mode;
  const rangeIdx = argv.indexOf("--range");
  if (rangeIdx !== -1) {
    const raw = argv[rangeIdx + 1];
    if (!raw) {
      console.error("--range needs an argument, e.g. --range HEAD~1..HEAD");
      return 2;
    }
    const parsed = parseRange(raw);
    if (!parsed) {
      console.error(`could not resolve range: ${raw}`);
      return 2;
    }
    mode = { kind: "range", ...parsed, label: raw };
  } else if (argv.includes("--worktree")) {
    mode = { kind: "worktree" };
  } else if (argv.includes("--staged")) {
    mode = { kind: "staged" };
  } else {
    mode = autoMode();
  }

  const { changed, readPair, description } = collect(mode);
  console.log(`check-spec-lockstep: ${description}`);

  if (mode.kind === "none") {
    console.log("nothing to check -- pass");
    return 0;
  }

  const { violations, warnings, exempt } = evaluate(changed, readPair);

  for (const e of exempt) console.log(`  exempt: ${e}`);
  for (const w of warnings) console.log(`  warn:   ${w}`);

  if (violations.length === 0) {
    const inLockstep = PAIRS.filter((p) => changed.has(p.source) && changed.has(p.spec)).length;
    console.log(
      inLockstep === 0
        ? "  no state-machine source changed without its spec -- pass"
        : `  ${inLockstep} state machine(s) changed in lockstep with their spec -- pass`,
    );
    return 0;
  }

  console.error("");
  console.error("SPEC LOCKSTEP VIOLATION (CONTRIBUTING.md rule 2)");
  console.error("");
  for (const v of violations) {
    console.error(`  ${v.note}`);
    console.error(`    machine: ${v.pair.machine}`);
    console.error(`    fix:     update ${v.pair.spec}, re-run proofs/tla/check-tla.sh,`);
    console.error(`             and re-audit the action mapping in ${CONFORMANCE_DOC}`);
    console.error("");
  }
  console.error(
    "A spec that models a machine the code no longer implements is not a weaker\n" +
      "proof -- it is a proof of the wrong thing, published as if it were the right\n" +
      "thing. That is the defect this guard exists to prevent.",
  );
  return 1;
}

// Guarded so the pure helpers above can be imported (by --self-test harnesses
// or a future test file) without the CLI running as a side effect.
if (import.meta.main) process.exit(main());
