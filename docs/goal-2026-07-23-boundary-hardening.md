# GOAL — Boundary Hardening (`elm-web3` + `elm-web3-ui`)

**From "the proofs are sound and the package is broken" to "the boundaries are
verified by the same machinery as the interior" — without rewriting a single
thing the audits rated best-in-class.**

## Why

Five parallel audits (core API, UI composability, consumer-as-oracle, code
quality, packaging) on 2026-07-23 produced one diagnosis in five voices:

> **The rigour points inward. Every serious defect is at a boundary.**

The Lean corpus and the TLA+ specs verify pure-Elm internals, and they hold.
But nothing verifies Elm↔JS, encoder↔decoder, lib↔consumer, doc↔code, or
spec↔code — and that is where all of it lives:

| Boundary | Failure |
|---|---|
| Elm ↔ JS shim | shipped artifact predates 2.0.0; `cmd.data` ignored on 3 paths; 7 field-name drifts in the `.d.ts` |
| encoder ↔ decoder | `Calldata.int256` writes two's complement, `Decode.int256` reads unsigned — not inverses |
| lib ↔ consumer | closed `Config` records + no attribute passthrough ⇒ 5%-different means fork |
| doc ↔ code | README wallet sample, `examples/basic`, and the gallery all fail to compile |
| spec ↔ code | `WalletSpec.tla` models the pre-2.0 machine it claims to verify |

Second diagnosis, and the reason this is P0 rather than housekeeping:
**"Zero runtime exceptions" is being satisfied in the wrong dimension.**
Nothing in Track A throws. Everything in Track A is silently wrong. For a
library that signs and broadcasts transactions, silent wrongness is strictly
worse than a crash.

This is a **correctness and boundary-verification** goal. It is not a feature
goal. `EVM_API_COVERAGE.md`'s remaining wishlist (EIP-5792, ENS) stays parked.

## Evidence baseline (executed against HEAD 2026-07-23, not inferred)

```
formatUnits 18 (fromInt -1500000000000000)  ->  "0.0-15"
formatEther  (fromInt -1)                   ->  "0.0000000000000000-1"
parseUnits 18 "1.-5"                        ->  950000000000000000     (0.95, no error)
parseUnits 18 "1.5"        (control)        ->  1500000000000000000    (correct)
BigInt.toString (fromInt 1500000000000000000) -> 999996861446400000000 (expected 1500000000000000000)

calldata "aabbccdd" [tuple [uint256 1, uint256 2], string "hi"]  ->  offset word 0x40   WRONG
calldata "aabbccdd" [uint256 1, uint256 2, string "hi"]          ->  offset word 0x60   correct
```
```
grep -c connectRejected js/elm-web3-ports.ts -> 2   js/elm-web3-ports.js -> 0
grep -c connectPending  js/elm-web3-ports.ts -> 2   js/elm-web3-ports.js -> 0
grep -c connectFailed   js/elm-web3-ports.ts -> 6   js/elm-web3-ports.js -> 0
```

## Standing constraints

- **Every gate below is a command with an exit code.** No gate may require a
  human action, a live playtest, or a subjective judgement — see
  a Stop-hook that embeds a human-only condition rejects every stop attempt
  forever. Anything genuinely needing the maintainer lives in **Handoff**,
  never in Definition of DONE.
- **A regression check must be proven to fail before it is trusted.** Every new
  fuzz property in Track A must be demonstrated red against the unfixed code
  (`git stash` the fix, run, confirm failure, restore) before its gate counts.
  This is the `check-no-tier3.ts` standard from
  `docs/goal-2026-07-12-mcp-tool-surface.md`.
- **Semver honesty.** Several Track A/B fixes change exposed types. `elm bump`
  is the arbiter; a MAJOR is acceptable and expected. Do not contort an API to
  dodge a version bump.
- **ASCII-only doc comments** (CI-enforced). String literals are unaffected.
- Plain commit messages, no AI attribution — the hook rejects it.
- `elm-test` must be invoked as `elm-test@0.19.1-revision12`; unpinned pulls a
  build demanding elm 0.19.2.

## Orchestration map

Five tracks. **A, B, C, D are fully independent and run concurrently.**
E depends on B's error taxonomy only for step E4; E1–E3 may start immediately.

```
A  core numeric + ABI correctness   ─┐
B  Elm<->JS boundary + detectors    ─┼─ parallel ─→  F  publish prep
C  front door (docs/examples/policy)─┤
D  spec & proof truth               ─┘
E  composability  (E1-E3 now, E4 after B3)
```

Track A is the only track that blocks a publish on correctness grounds. Track B
is the only track that installs a *detector*, and is therefore the one that
prevents recurrence — treat it as equal priority to A, not subordinate.

---

## Track A — Silent-money bugs (`elm-web3`, pure Elm)

**A1. `Abi.Decode.int256` is `= uint256`** (`src/Web3/Abi/Decode.elm:175-178`).
Implement real two's-complement decoding; add `int256Slot : Int -> String ->
Maybe BigInt`; add the missing `BigInt.negate`. Audit `intN` widths at
`Decode.elm:143-170` while here — `uint64`/`uint128` only check `>= 0` and
accept 2^200.

**A2. `Calldata` head-size counts slots, not bytes**
(`src/Web3/Abi/Calldata.elm:318-319`). Replace
`headSize = List.length slots * (sLEN // 2)` with a per-slot width sum
(`Static` = its own byte length, `Dynamic` = 32). The JS encoder's `_headSize`
already recurses correctly — mirror its semantics.

**A3. `Units.formatUnits` sign handling** (`src/Web3/Units.elm:57-84`). Extract
sign before padding/trimming the fractional remainder; re-apply once.

**A4. `Units.parseUnits` input validation** (`src/Web3/Units.elm:117-141`).
Reject any input whose fractional part is not `[0-9]*`; keep truncation
behaviour but document it. Return `Nothing`, not a plausible wrong number.

**A5. uint256 range enforcement.** `padLeftHex` (`Calldata.elm:372-382`)
returns over-long input unchanged, silently shifting every later parameter.
Decide the contract (clamp is unacceptable): either `Calldata.uint256` takes a
validated newtype, or the encoder returns `Result RangeError String`. Same
class at `AbiInput.elm:890-896` (`bytes99` accepted).

**A6. Slot decoders must not report success on malformed data.**
`hexToInt` returns `0` on parse failure by design (`Decode.elm:405-428`) and
that zero becomes an offset — `stringSlot 0 "0xdeadbeef"` yields `Just ""`,
indistinguishable from a real empty `symbol()`. Also bound `listSlot`
(`Decode.elm:307-315`): an unvalidated count feeds `List.range` and hangs the tab.

**A7. `BigInt.fromInt` past 2^53** (`BigInt.elm:90-101`) — returns
`999996861446400000000` for `1500000000000000000`. Either document the safe
range and add `fromSafeInt`/`fromString` guidance, or return `Maybe`. Fix the
module doc at `Units.elm:10`, which uses the corrupting literal as its headline
example.

**A8. `BigInt.mod` implements `rem`** (`BigInt.elm:517-524`) — `mod -10 3`
gives `-1` where Elm's `modBy` gives `2`. Rename or correct the sign.

**A9. Mined-and-reverted is called `Confirmed`** (`Transaction.elm:229-238`).
Split `Confirmed Receipt | RevertedOnChain Receipt`; update `isTerminal`,
`Ui.Transaction.statusBadge`, and the module doc example at `Transaction.elm:34`
which currently renders a revert as success.

**Gate A.** A new `tests/BoundaryRegressionTest.elm` containing, at minimum:
an `int256` **hex** round-trip fuzz property (`Calldata.int256 >> Decode.int256`
over negative values — the existing `AbiFuzzTest.elm:614` passes only because it
round-trips decimal strings through JSON and never touches the hex path); a
`tuple`-beside-`dynamic` calldata vector asserting `0x60`; `formatUnits` over
negative fuzz input; `parseUnits` over adversarial strings including `"1.-5"`,
`"1.+5"`, `"1.e5"`. Each property must be **shown red against the unfixed code**
before the fix lands.
```
npx --yes elm-test@0.19.1-revision12 --compiler $(which elm)   # exit 0
```

---

## Track B — The Elm↔JS boundary and its detectors

**B1. Rebuild and commit the shim.** `bun js/build.ts` — the committed
`js/elm-web3-ports.js` predates the 2.0.0 wallet rewrite and cannot emit
`connectRejected` / `connectPending` / `connectFailed`, which
`src/Web3/Wallet.elm:671-677` decodes. Every adopter following the README today
gets a wallet that can never report rejection, pending, or failure.

**B2. Wire `cmd.data` through.** `js/elm-web3-ports.ts:579,593,620` hardcode
`data: encodeCall(cmd.method, cmd.args)`; for a raw call that is
`encodeCall("", [])` = the constant selector of the empty string. Three
`if (cmd.data)` branches. Also `Send.estimateGas` (`Send.elm:165-180`) never
sends `call.data` and drops `from` — fix the Elm side too.

**B3. One canonical error type.** The port maps `4001` to `rejected` and
everything else to `failed: <string>` (`js:1091-1112`); `err.code` never crosses
the boundary. Introduce
`Web3.Error = UserRejected | RequestPending | ChainNotAdded | RpcError Int String
| Reverted { reason, data } | Panic Int | DecodeError String | NetworkError String`,
forward `err.code`, and stop discarding the already-decoded
`ConnectFailureReason` at `Wallet.elm:261`. Unblocks E4 and kills `4902`
undetectability (the switchChain→addChain retry flow is currently impossible).

**B4. Correlation ids on the write path.** `Send.encode`/`estimateGas`/
`deployCall` emit no `id`, and `submitted`/`confirmed`/`failed` carry none, so
two in-flight transactions are indistinguishable and `Web3.Model.transactions`
can never be driven. Add `Send.withId`; thread through `Transaction.Msg`.

**B5. Port-tag parity check — the detector that matters most.** A CI script
extracting every `E.string "<tag>"` from `src/**/*.elm` and every `case '<tag>'`
from `js/elm-web3-ports.ts`, failing on a set difference in either direction,
for both the Cmd and Sub directions. This single check would have caught B1, B2,
and the `watchEvent` tag collision (`Subscription.elm:210` vs `Event.elm:61`,
same tag, incompatible payloads, so the WS path subscribes to every log on chain)
on the day each shipped.

**B6. Artifact freshness check.** CI runs `bun js/build.ts` then
`git diff --exit-code js/elm-web3-ports.js`. Makes a stale artifact impossible.

**B7. Generate the `.d.ts`.** It is hand-maintained and has drifted in seven
places (`raw`/`rawTx`, `input`/`message`, `address`/`contract`, missing
`requestId`, missing `data`, missing `getFeeHistory` params, missing `id` on
`watchBlockNumber`). Its own header admits drift "must be caught in code review";
it wasn't. Emit it from `tsc --declaration` instead.

**Gate B.**
```
bun js/build.ts && git diff --exit-code js/elm-web3-ports.js     # exit 0
bun run scripts/check-port-parity.ts                             # exit 0
bun run scripts/check-port-parity.ts --self-test                 # exits 1 on an injected drift
```
The `--self-test` mode is mandatory: a parity checker that has never been seen
to fail is not evidence.

---

## Track C — The front door

**C1. README wallet section** (`README.md:111-126,154-156`) documents pre-2.0.0
arity — `Connecting` without `RequestId`, `startConnect : State -> State`,
`connect : WalletCmd`. The flagship sample does not type-check.

**C2. Quickstart script tag** (`README.md:57-64`). The shipped `.js` is an ESM
bundle ending in `export{...}`; the README says to load it with a classic
`<script src>` and call a global `setupPorts`. That throws
`SyntaxError: Unexpected token 'export'`. Use the `type="module"` form that
`examples/basic/index.html` already has.

**C3. Fix `examples/basic`.** `src/Main.elm:105,292` use `Wallet.Connecting`
with no argument. Delete `examples/basic/ports.js` (a 488-line stale fork
handling 11 of 35 tags) and source the canonical shim.

**C4. Unpin the gallery.** `examples/gallery/elm.json` pins elm-web3 **1.2.2**
while `src/` needs 2.0.0; Pages deploy has failed on every push since
2026-07-16 and the live site still serves a 2026-07-02 build, so 2.4.0 is
invisible to anyone evaluating the package.

**C5. CI builds every example.** Neither workflow compiles `examples/` today,
which is why C3 and C4 rotted silently.

**C6. Reconcile the module count.** README says 57, `elm.json` exposes 52,
`PRIMITIVES.md` says 46, the GitHub description says 36. Derive it, or pick one
and fix the rest. Also `elm-web3-ui/README.md:17` claims elm-web3 "1.0.0 or
later" while `elm.json` requires `2.0.0 <= v < 3.0.0`.

**C7. `SECURITY.md` in both repos.** This library signs and broadcasts
transactions and there is no disclosure address, no statement of what is and
isn't audited, and no patch procedure for a registry that cannot unpublish.
State plainly: no external audit; here is what is machine-checked; zero runtime
npm dependencies; here is how to verify the shim bytes; here is the
deprecate-and-supersede procedure.

**C8. `UPGRADING.md` (1.x→2.0) + a compatibility matrix.** Three moving parts
(elm-web3 ↔ elm-web3-ui ↔ shim revision) with zero documentation of how they
pair. The 2.0.0 CHANGELOG is good prose but is not a migration doc: it doesn't
say to also replace the shim, and doesn't say elm-web3-ui < 2.4.0 is incompatible.

**C9. `examples/hello-read/`** — ~40 lines, one `eth_call`, one public RPC, no
wallet. The time-to-first-successful-contract-read artefact. Built by CI.

**Gate C.**
```
elm make examples/basic/src/Main.elm --output=/dev/null                # exit 0
elm make examples/hello-read/src/Main.elm --output=/dev/null           # exit 0
cd ../elm-web3-ui/examples/gallery && elm make src/Main.elm --output=/dev/null   # exit 0
bun run scripts/check-readme-samples.ts                                # extracts fenced elm blocks, compiles each
test -f SECURITY.md -a -f docs/UPGRADING.md                            # exit 0
```

---

## Track D — Spec and proof truth

**D1. `proofs/tla/WalletSpec.tla:71`** still models bare `Connecting`; the code
was rewritten 2026-07-16 (`625d2d1`) adding `RequestId`, supersede semantics and
three `Msg` variants. This violates `CONTRIBUTING.md` rule 2 and inflates the
proofs page for the current release. For a project whose sole differentiator is
verification honesty, this is the one a skeptic finds first.

**D2. `proofs/TLA_CONFORMANCE.md`** says "Audited 2026-07-02" — re-audit
action-by-action against 2.0.0.

**D3. `proofs/JS_PORT_PROOF.md:3-4`** audits "`js/elm-web3-ports.js` (509
lines)". The bridge is now 1,688 lines of TypeScript. Its F7 claim — failures
unified on a catch emitting `failed` "with a context field" — is false; there is
no context field (`js:1103-1109`). Re-audit against the `.ts` and restate.

**D4. `proofs/EVM_API_COVERAGE.md`** claims the port contract is "verified 1:1".
It verified tag names only. Restate the claim to exactly what was checked, and
point at Track B5 as the mechanism that now checks fields.

**D5. Derive the proofs-page version strings.** `docs-site/index.html:14` reads
"elm-web3 1.4.4 · elm-web3-ui 2.3.1" against actual 2.0.0 / 2.4.0. Generate from
`elm.json` at build time.

**D6. CI lockstep guard.** Fail if `src/Web3/Wallet.elm` changes without
`proofs/tla/WalletSpec.tla` in the same commit range.

**Gate D.**
```
proofs/tla/check-tla.sh                                    # exit 0, WalletSpec included
bun run scripts/check-spec-lockstep.ts                     # exit 0
grep -c '1\.4\.4\|2\.3\.1' docs-site/index.html            # 0 matches
```

---

## Track E — Composability (`elm-web3-ui`, plus `Multicall` in core)

The consumer-as-oracle audit is a falsification, not an opinion: **two
production dapps written by the same author import 5 and 8 of 52 UI modules,
and the Layer 2/3 flow generics — `RemoteCall`, `ApprovalFlow`, `TxQueue`,
`SimulateFirst`, `BlockRefresh`, `Form` — have zero adoption in both.** Each is
one axis too narrow.

**E1. Attribute passthrough on every view.** `README.md:22` promises "Every
function takes `List (Html.Attribute msg)` as its first argument" — true for
**8 of 39** modules with a top-level `view`. Mechanical, MAJOR, and the single
biggest composability unlock: without it a consumer cannot attach `id`,
`data-testid`, or any ARIA attribute to most of the library.

**E2. Applicative `Multicall`** (core). `responseDecoder` returns an untyped
positional list. One downstream app wrote a **1,345-line** decoder module of
hardcoded index slots; the other wrote parallel field-name registries zipped by
position — whose doc had already drifted 4→5 fields. Ship
`Multicall.succeed f |> andMap (call addr sig args decoder)` plus
`decode : Batch a -> List CallResult -> Result Error a`. Index drift becomes
uninhabitable.

**E3. The seams both apps forked at.** `Address.shortString : String -> String`
(seven hand-rolled copies across the two apps, three different ellipsis
characters); `Amount.formatWeiWith { grouping, siSuffix, decimals }` (the
"documented seam" in `PRIMITIVES.md:118` is precisely the fork point);
restore `PriceDisplay.fixedDp` (its removal is cited in consumer source twice as
forcing a hand-roll); `Deadline.toUnixDeadlineWei` returning `BigInt` (the `Int`
version is unusable at the uint256 call site); expose the duplicated
bps/duration/percent/truncate helpers as one `Web3.Ui.Format`.

**E4. Typed transaction failure** — *depends on B3*. `Tx.Failed String` forces
every consumer to write a substring matcher; both apps did, and both name this
type as the cause in their own comments. Adopt `Failed FailureDetail` and add
`Revert.classify : String -> FailureDetail` for the legacy path.

**E5. One axis each on the unadopted generics.** `RemoteCall` gains
stale-while-revalidate (`Loading { id, last }`, `latest`, `hasLanded`);
`TxQueue` splits into a headless core plus an optional renderer;
`ApprovalFlow` generalises to an N-gate ladder; `BlockRefresh` gains
multi-cadence and scope gating.

**E6. Decimals correctness** (same bug class the 2.4.0 changelog says bit a live
app): `StakeCard.elm:112`, `NFTStakeCard.elm:133`, `BondCard.elm:107` format a
*different* token's amount with the stake token's `decimals`. `GaugeRow` got it
right with separate fields — copy that.

**E7. Kill the `Float` round-trips.** `GaugeRow.elm:152`, `VeBalanceChart:159`,
`BondingCurve:158`, `SupplyBar:119`, `TrendIndicator:64`, `FundingPool:149` all
route uint256 through `Float`, directly contradicting
`Ui/Internal/Decimal.elm:10-19`, which exists to forbid exactly this.

**Gate E.**
```
bun run scripts/check-attrs-passthrough.ts        # every exposed view takes List (Html.Attribute msg) first
npx --yes elm-test@0.19.1-revision12 --compiler $(which elm)   # incl. new Multicall applicative + decimals tests
grep -rn 'String.toFloat\|toFloat' src/Web3/Ui --include=*.elm | grep -v Internal/Decimal   # 0 matches
# Downstream consumers. Paths are machine-local by design and are NOT recorded
# in this repo -- set them in an untracked scripts/consumers.env:
#   CONSUMER_A=/path/to/app-one   CONSUMER_B=/path/to/app-two
bun run scripts/check-consumers.ts     # compiles each consumer against the working tree; exit 0
```
The last two are the real gate: both production consumers must still compile
against the changed libs, or the change is not done.

---

## Track F — Publish prep (after A–E)

**F1.** `elm bump` in both packages; accept whatever MAJOR falls out.
**F2.** Changelogs written as migration instructions, not release notes.
**F3.** `RELEASING.md` encoding the gate order:
`elm make src` → `elm make --docs` → ASCII guard → tests → shim rebuild +
diff-exit-code → port parity → build every example → TLC → Lean → `elm bump` →
tag → `elm publish` → `gh release create`.
**F4.** Commit per track, plain messages.

**Gate F.** `bun run scripts/release-preflight.ts` runs every gate from
A–E in sequence and exits 0.

---

## Definition of DONE (autonomous — every item is a command's exit code)

- [ ] Gate A green, and each new regression property demonstrated red against
      the unfixed code first
- [ ] Gate B green, including `check-port-parity --self-test` exiting 1 on an
      injected drift
- [ ] Gate C green (`examples/basic`, `examples/hello-read`, gallery all
      compile; README fenced samples compile; `SECURITY.md` + `UPGRADING.md` exist)
- [ ] Gate D green (TLC passes on the current `WalletSpec`, lockstep guard
      committed, no stale version strings on the proofs page)
- [ ] Gate E green, **including both production consumer apps still compiling**
- [ ] Gate F: `release-preflight.ts` exits 0
- [ ] `elm bump` run in both packages, changelogs written, everything committed
      locally with plain messages
- [ ] Memory updated (`project_elm_web3_formal.md`)

## Handoff — requires the maintainer (deliberately NOT in DONE)

These are human actions by design; putting them in DONE would deadlock a
Stop-hook forever.

- `git push` on both repos (the harness blocks a push initiated from a goal
  doc's own authority — it needs an explicit instruction naming the push)
- `elm publish` on both packages
- npm publish of `@intrepidshape/elm-web3-ports`, if F/B7 concludes that's the
  right home for it
- Any decision to accept a MAJOR version bump's blast radius on downstream users

## What this does NOT touch

**Do not rewrite the parts every audit independently rated best-in-class.**
`Web3.Wallet`'s `RequestId` supersession FSM (called better than wagmi's, and
the best-adopted module across both consumer apps). EIP-6963 discovery and the
`registerProvider`/`setupExternalProvider` BYO-transport seam. The RPC pool —
shuffled endpoints, per-endpoint cooldown, read/write split so writes never
touch a public RPC — and the WS backoff/re-arm/poll-fallback path.
Simulate-before-send as the default. The base-10^7 `BigInt` core with its
written 2^53 carry-safety argument and its Lean proofs (A7/A8 fix the *edges* of
`fromInt`/`mod`, not the arithmetic). `Web3.Types`' opaque wrappers. The
`web3-*` class contract with no inline styles — it is the sole reason two wildly
different skins render from the same markup; the closed `Config` records are the
blocker, not the CSS contract.

**No new features.** EIP-5792, ENS, token lists, and the ERC-20/721/1155 ABI
helper set stay parked — this goal is about making what already exists true.

**No emergency `elm-web3` 2.0.1.** One audit urged it because 2.0.0's published
docs.json holds 104 non-ASCII characters. Verified false alarm: no multibyte
character crosses a 64 KiB boundary and it decodes cleanly with a cleared cache.
The ASCII guard is correctly forward-looking. The ui 2.3.0 docs remain
permanently undecodable and that is already superseded by 2.4.0 — see
`[[project_elm_web3_formal]]`.

**No registry cleanup attempts.** The two superseded look-alike packages under
the earlier publishing handle cannot be removed; the Elm registry is append-only
and they are already non-installable (deleted GitHub org, so the install
endpoint 404s). Settled -- see project memory, not this public doc.
