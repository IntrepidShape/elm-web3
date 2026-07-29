# Changelog

## 3.0.0 — 2026-07-29

MAJOR. Three changes to exposed types, one module removal, one new module.
Every one is a correctness fix; none is a feature.

### Fixed — the bridge could never report a failure

`_decodeRevertReason` was called in the shim's failure path and referenced in a
comment, but **defined nowhere in the file**. Every non-rejection error threw
`ReferenceError` inside its own catch block, so no `failed` message ever
reached Elm: a reverted transaction sat in `Confirming` forever with nothing
surfaced to the user. It was the single `TS2304` in the repo's own tsc output,
and no gate ran tsc. Now implemented for `Error(string)` and `Panic(uint256)`.

### Fixed — raw calldata was ignored

`call`, `estimateGas` and `send` hardcoded `data: encodeCall(method, args)`,
so `readCallRaw`/`writeCallRaw`/`payableCallRaw` — the documented pure-Elm
path — sent `encodeCall("", [])`, the selector of the empty string, to the
contract. Silently. `cmd.data` is now used verbatim when present, and
`estimateGas` honours `from` so an estimate is taken as the sending account.

### Changed — mined-and-reverted is no longer called `Confirmed` (BREAKING)

`Status` gains **`RevertedOnChain Receipt`**. Previously a mined-but-reverted
transaction became `Confirmed`, and the module's own doc example rendered it
as success; every consumer had to remember to check `receipt.status`. The type
now says it. `Receipt` also gains `contractAddress : Maybe Address`, so a
deployment can finally recover its own address.

**Migration:** add a `RevertedOnChain` branch wherever you match on `Status`.
If you were checking `receipt.status` by hand inside your `Confirmed` branch,
delete that check — `Confirmed` now means succeeded.

### Added — one canonical error type (BREAKING)

New module **`Web3.Error`**: `UserRejected | RequestPending | ChainNotAdded |
RpcError Int String | Reverted {reason,data} | Panic Int | DecodeError String
| NetworkError String`. The shim now forwards `err.code`, including the nested
shapes several wallets use, so `4902` (chain-not-added) is detectable and the
standard switchChain-then-addChain retry is finally implementable; `-32002` no
longer vanishes outside connect.

`Wallet.State.Error` now carries a typed `Failure` instead of a `String`, so
the `ConnectFailureReason` the library already decoded is no longer discarded.
`Wallet.Msg.WalletError` carries `Web3.Error.Error`.

**Migration:** `Wallet.failureMessage` recovers the human-readable string if
that is all you need.

### Added — correlation ids on the write path (BREAKING)

`Send.withId`, and every write-path reply carries `Maybe TxId`, so two
in-flight transactions are finally distinguishable. `Transaction.Msg`
constructors re-arity accordingly; `Transaction.msgId` routes.

### Removed — `Contract.Event`'s subscribe half (BREAKING)

`EventFilter`, `watchEvent`, `encode` and `decoder` are gone.
`Web3.Subscription` is now the sole owner of the `watchEvent` wire format.

This was not a working feature being retired. `Contract.Event.watchEvent` sent
no subscription id and put the address under a `contract` key the shim never
reads, so it issued `eth_subscribe(['logs', {address: undefined}])` — **a
subscription to every log on the chain**. Its `logDecoder` then read a
`contract` field the shim never sends, so it could not have decoded a result
either. Its `event : String` field was inert on both sides; nothing hashed it
into a topic. Even the module's headline doc example never type-checked: it
passed `filter = []` to a record whose field is `topics`.

`getLogs`, `logsDecoder`, `EventLog` and `GetLogsQuery` are unchanged and stay
— that half works, and is the only Elm emitter of the shim's `getLogs`
handler.

**Migration:** use `Web3.Subscription` (`open`/`close`, with a `LogFilter`
builder) for live events. It has always spoken the correct wire format.

### Verification

- `scripts/check-port-parity.ts` compares every Elm-emitted tag against the
  shim's handlers and the `.d.ts`, in both directions, and its `--self-test`
  proves it detects an injected drift of each class rather than being trusted
  on faith. This is the detector that would have caught the two bugs above on
  the day they shipped.
- CI rebuilds the shim and fails if the committed artifact differs from its
  source, so a stale bundle cannot ship again.
- `WalletSpec` and `TransactionSpec` were extended and their new invariants
  proven non-vacuous by model-checking mutants first: asserting the pre-3.0.0
  behaviour (a reverted receipt becoming `Confirmed`) violates
  `ConfirmedMeansSuccess` with a four-state counterexample.
- The `decodeRevertReason` doc example encoded length `0x11` for an 18-byte
  string, so it returned `"Insufficient fund"` rather than the
  `"Insufficient funds"` it claimed. Corrected and pinned by a test.


## 2.1.0 — 2026-07-23

> **Read this section even though the version bump is MINOR.** `elm diff`
> classifies a release by comparing *types*, and three functions below changed
> *behaviour* behind identical type signatures. The tool cannot see that, so
> this entry is the only warning you get. Each was a bug producing wrong
> numbers, not a contract anyone could safely depend on — but if you worked
> around one of them, that workaround is now itself the bug.

### Fixed — signed integers decoded as unsigned

`Abi.Decode.int256` was defined as `int256 = uint256`: no two's-complement
inversion at all. `-1` decoded as 2^256-1. Any `int*` return value — a
Uniswap V3 tick, an oracle delta, a funding rate, a rebase delta, a PnL — read
back as an astronomically wrong positive number. The encoder
(`Abi.Calldata.int256`) had always written correct two's complement, so the
encoder and decoder in this package were not inverses of each other.

- **`Abi.Decode.int256`** now interprets a 0x-prefixed word as two's
  complement. Decimal input (what the JS bridge sends) is unchanged.
- **Added `Abi.Decode.int256Slot`** — the signed counterpart of `uint256Slot`,
  which simply did not exist. Use it for every `int*` slot in a raw ABI
  response; `uint256Slot` on a negative value is the bug above.

### Fixed — corrupt calldata when a static tuple precedes a dynamic argument

`Abi.Calldata` computed the head section as `slotCount * 32`. A `tuple` of
all-static components is encoded inline as a single *multi-word* static slot,
so counting slots understated the head and every following dynamic offset
pointed into the wrong place. `foo((uint256,uint256),string)` emitted offset
`0x40` where `0x60` is correct — the contract then read the string's length
from the offset word itself. Head width is now summed in bytes. Signatures
shaped like `(Params, bytes)` or `(Order, bytes signature)` were affected;
flat signatures never were.

### Fixed — negative amounts formatted as garbage

`Units.formatUnits` formatted a signed value directly, so the minus sign ended
up *inside* the fraction: `formatUnits 18 (-1.5e15 wei)` returned `"0.0-15"`,
and `formatEther (-1 wei)` returned `"0.0000000000000000-1"`. The sign is now
applied once to the finished string. This surfaces through
`elm-web3-ui`'s `Amount.formatWei` too, so any balance display inherited it.

### Fixed — parseUnits accepted malformed input and returned a plausible number

`Units.parseUnits` passed the fractional part to `BigInt.fromString`, which
accepts a leading `-` or `+`. `parseUnits 18 "1.-5"` returned 0.95e18 with no
error reported — a user typo silently became a different amount. Fractions
must now be digits; anything else returns `Nothing`. **If you previously
relied on a `Just` here, you were relying on a wrong number.**

### Docs

- The `Units` module overview no longer demonstrates `BigInt.fromInt` on an
  18-decimal literal. An Elm `Int` is a JS double, so
  `BigInt.fromInt 1500000000000000000` yields `999996861446400000000` — the
  headline example taught a corrupting pattern. Use `BigInt.fromString`.

### Docs — ASCII-only doc comments (registry-critical, CI-enforced)

All doc comments are now pure ASCII. elm 0.19.1's client-side docs.json
parser has a byte-position-sensitive bug with raw multi-byte UTF-8: depending
on where a character lands in the generated docs.json, `elm diff` /
`elm bump` / `elm publish` fail with PROBLEM LOADING DOCS for every consumer,
permanently (published bytes are immutable). It bricked the sibling ui
package's published 2.3.0 docs (a `>=` sign at byte offset 65709). This
package's published docs all decode today, but only by byte-layout luck --
pure-ASCII docs are immune by construction, so CI now rejects non-ASCII in
docs.json.


## 2.0.0 — 2026-07-16

### Changed — RequestId-tracked wallet connect (BREAKING)

A single wallet connect attempt is now identified by a `RequestId` so a stale
response or timeout from a superseded attempt (user clicked Connect, gave up,
clicked again) can never clobber a newer one.

- **`State.Connecting`** now carries the in-flight `RequestId`:
  `Connecting` → `Connecting RequestId`. **Breaking** — pattern matches on
  `Connecting` must add the argument (`Connecting _` or `Connecting reqId`).
- **`Msg.WalletConnected`** now leads with the originating request:
  `WalletConnected String Int` → `WalletConnected (Maybe RequestId) String Int`.
- New `Msg` variants distinguishing the three non-success outcomes:
  `WalletConnectRejected RequestId`, `WalletConnectPending RequestId`,
  `WalletConnectFailed RequestId ConnectFailureReason String`.

### Added

- **`type alias RequestId = Int`** — caller-owned connect-attempt counter.
- **`type ConnectFailureReason`** — `NotFound | NoAccounts | NetworkError`.
- **`type alias ConnectedInfo`** — now exposed (`{ address, chainId }`).
- **`isConnecting`**, **`connectingRequestId`**, **`timeoutConnect`** —
  state helpers; `startConnect` can now supersede an in-flight attempt.


## 1.4.4 — 2026-07-02

### Verification — the proof corpus is sorry-free

- **`natCompare_spec` PROVED** (restated form, over valid normalized digit
  lists): nine new helper lemmas — positional decomposition
  (`natVal_append`), power bounds, normalized-shape, and big-endian
  lexicographic agreement — close all three Ordering iffs; forward
  implications by induction, converses free by trichotomy. Axiom check:
  `propext, Classical.choice, Quot.sound` only.
- Zero `sorry` warnings across all ten proof files (CI-enforced). Remaining
  future work is modeling (two statements to write), not proving.

Proofs/docs only.


## 1.4.3 — 2026-07-02

### Verification — the proof push

- **Discharged:** `natSubBorrow_val`, `natSub_val`, `natMul_val`
  (BigInt), `decodeRevertReason_correct` (full pipeline correctness over a
  faithful model of Decode.elm), `uint256_codec_roundtrip` (over a real
  self-contained decimal codec model), `bigPow_pos` (Units).
- `natCompare_spec` was refuted as originally stated (machine-checked:
  `natCompare [5,0] [5] = .gt` with equal values) and restated over valid
  normalized inputs — the invariant Elm maintains by construction. Its
  proof is the corpus's single remaining `sorry`.
- The `natDivMod`/`fromString`-roundtrip entries turned out to be
  `True`-placeholders in the model — recorded as "not yet stated" rather
  than "pending", which the previous table overstated.

Proofs/docs only; no library code changes.


## 1.4.2 — 2026-07-02

- Docs-only: README refresh (verification-story links: proofs page, coverage
  ledger, CI enforcement) so the registry page carries the current front
  door. No code changes.


## 1.4.1 — 2026-07-02

### Changed

- **`watchBlockNumber` now prefers a WS `newHeads` subscription** (push,
  block-accurate) over the 4s HTTP poll, which remains as automatic
  fallback. Same `blockNumber` message shape — zero Elm-side changes.
  `unwatchBlockNumber` tears down whichever path is active.
- `proofs/JS_PORT_PROOF.md`: F1–F8 re-audit — every recorded port finding
  verified fixed in the current bridge; no open port-layer findings.


## 1.4.0 — 2026-07-02

### Added

- **`Abi.Decode.decodeCustomError`** — typed Solidity custom errors
  (`error Foo(uint256,uint256)`) decoded via selector fragments the app
  bakes at codegen time (no runtime keccak, same philosophy as calldata
  selectors). Refuses the standard `Error(string)`/`Panic` selectors so it
  composes with `decodeRevertReason` unambiguously — disjoint domains by
  construction. Four regression vectors added (459 tests green).


## 1.3.0 — 2026-07-02

### Added

- **`Fee.getMaxPriorityFee` / `Fee.maxPriorityFeeDecoder`** —
  `eth_maxPriorityFeePerGas`, completing the EIP-1559 fee-read triad. Shipped
  as a standalone encode/decode pair rather than new `Fee.Msg` variants
  (extending an exposed custom type breaks consumers' case expressions —
  that's a MAJOR; this is additive).
- **`Sign.verify` / `Sign.recoveredDecoder`** — `personal_ecRecover`:
  client-side signature verification for login flows.
- **`Block.unwatchBlockNumber`** — stops a block-number watch.

### Fixed

- **Port F8**: `watchBlockNumber`'s poll interval was never cleared and
  stacked on re-issue. Pollers are now keyed by correlation id, replaced on
  re-issue, and cleared by `unwatchBlockNumber`. `js/elm-web3-ports.js`
  rebuilt (bun).

Wire-pair tests added for every new encoder/decoder (455 tests green).


## 1.2.3 — 2026-07-02

### Verification — all ten Lean files now machine-check (first time ever)

- Installed the toolchain (elan, Lean 4.31.0 pinned in
  `proofs/lean/lean-toolchain`) and ran `lean` on every proof file for the
  first time in the project's history: only 3 of 10 checked. All seven broken
  files were repaired to the pinned toolchain without weakening any surviving
  statement; **all ten now exit 0**, and a `lean` CI job enforces it on every
  PR alongside TLC and elm-test.
- **The checker found three original claims FALSE as stated** (quarantined
  in-file with counterexamples, not silently reworded): the BigInt
  subtraction lemmas admit invalid digit lists (`a=[], b=[-5]`), and both
  revert-decoder guard theorems strip the `0x` prefix unconditionally where
  the code strips it conditionally. Faithful restatement is tracked work.
  The Elm library itself is unaffected — these were defects in the models'
  statements.
- `proofs/COVERAGE.md`: 12 of the 15 downgraded rows promoted back to Proved
  by the checker; the 3 false ones get their own labelled section.
- **New: [What is actually proved](https://intrepidshape.github.io/elm-web3/)**
  — the verification story as a zero-JS page: the four-checker stack, the
  honest coverage chart, all four state machines drawn from their TLA+ specs,
  and the corrections ledger (now four entries). README links it, the
  gallery, and the audit docs.

Docs/proofs/CI only — no library code changes.


## 1.2.2 — 2026-07-02

### Fixed — revert reasons never decoded (wrong selector constant)

- **`Web3.Abi.Decode.decodeRevertReason`** compared against `08c379a2`; the
  real `Error(string)` selector is **`0x08c379a0`**. Every genuine on-chain
  revert payload therefore returned `Nothing` since the function shipped.
  The Lean proofs in `proofs/lean/RevertReason.lean` faithfully verified the
  typo'd constant — correct proofs about the wrong world. Constant fixed in
  code and proofs; four canonical real-world vectors (what solc 0.8+
  actually emits) added as regression tests, including one asserting the
  old typo'd selector does NOT decode. See `proofs/COVERAGE.md` §Known
  limitations for the epistemics.


## 1.2.1 — 2026-07-02

> Registry note: the 1.1.0 and 1.2.0 tags below existed in git but had never
> been run through `elm publish` — the registry only carried 1.0.0. All three
> versions (1.1.0, 1.2.0, 1.2.1) were published together on 2026-07-02.

### Fixed — three state-machine bugs found by the TLA↔code conformance audit

Behavior fixes only — no exposed signature changes. Each was surfaced by
auditing the TLA+ specs action-by-action against the Elm `update` functions
(full audit: `proofs/TLA_CONFORMANCE.md`).

- **`Web3.Wallet`: `ChainChanged` now recovers from `WrongChain`.** If the
  user switched to the expected chain manually in the wallet UI (the EIP-1193
  `chainChanged` event), the app stayed stuck in `WrongChain` forever — only
  the app-initiated `switchChain` round-trip could recover. `WrongChain` +
  `ChainChanged expected` → `Connected` (and updates `chainId` when landing on
  another wrong chain).
- **`Web3.Wallet`: `ReadOnlyMode` no longer tears down a live session.** A
  stray `readOnly` announcement (init race) moved `Connected`/`WrongChain` to
  `ReadOnly`, destroying the session. It is now ignored unless the state is
  `Disconnected`/`Connecting`/`Error`.
- **`Web3.Transaction`: confirmation counts are now actually monotonic.** The
  module docs and TLA+ spec promised "confirmation counts only increase", but
  `update` accepted any count — stale or reordered port messages could move
  the counter backwards. `TxConfirmation` now requires `count ≥ 1` from
  `Submitted` and `count >` current from `Confirming`; stale counts are
  dropped. (The receipt hash still follows the message — a wallet speed-up
  legitimately swaps in a replacement hash.)

Regression tests added for all three (unit + a hostile-stream fuzz property
for monotonicity).

### Verification — TLA↔code conformance audit + EVM API coverage map

- **`proofs/TLA_CONFORMANCE.md`** — new. Maps every Elm `update` case arm to
  its TLA+ action for all three machines. The audit found 9 divergences: the
  3 code bugs above, 5 places the spec modeled a different machine than the
  code (TxReset scope, late rejection, `TxFailed` from `Idle`,
  invalid-receipt path, phantom `ReadOnly → Disconnected` path), and 1 false
  liveness claim.
- **`WalletSpec.tla`**: `UserDisconnect` no longer models the nonexistent
  `ReadOnly → Disconnected` path; `EvtChainChangedFromWrongChain` added;
  `EvtReadOnlyMode` restricted to non-session states; the false
  `NoDeadlock == []<>(Disconnected)` claim replaced by the true (and checked)
  `EventuallyAtRest`; `ConnectedStability` and `ReadOnlySticky` are now
  actually in the `.cfg` (the former was listed in COVERAGE while never being
  evaluated); `ReadOnlyHasNoAddr` invariant now checked too.
- **`TransactionSpec.tla`**: `UserRetry` extended to all terminals (matches
  `TxReset`, removes the phantom deadlock); `GuardedTxRejectedLate` and
  `GuardedTxConfirmedInvalid` added; `TxFailed` source set made faithful
  (includes `Idle`); the vacuous `MonotonicConfirmations` invariant
  (`confirmCount >= confirmCount`) rewritten as a real action property;
  stale "UNGUARDED = faithful to the Elm code" comment corrected.
- TLC deadlock checking re-enabled for Wallet + Transaction (no sinks
  remain); still off for Sign (terminal sinks are intended, no reset exists).
  All three specs re-verified green.
- **`proofs/EVM_API_COVERAGE.md`** — new. Full EIP/JSON-RPC coverage matrix
  with verdicts; wire-protocol integrity check (31 Elm command tags ↔ 31 port
  handlers, 1:1); ranked genuine gaps (`eth_maxPriorityFeePerGas`,
  custom-error revert decoding, `personal_ecRecover`, WS `newHeads`,
  port F8: uncleared `watchBlockNumber` interval).

### Verification — TLA+ specs now actually model-checked by TLC (+ new SignSpec)

- **`proofs/tla/SignSpec.tla`** + **`SignSpec.cfg`** — new TLA+ spec for the
  `Web3.Sign` state machine (`startSign` / `signUpdate`), the first formal spec
  for the signing lifecycle. Safety: terminal absorbing, every terminal entered
  from `SignPending`, and `NoCrossRequestConfusion` (a message for a different
  correlation id can never complete the pending sign). Liveness: `SignPending ⇒
  ◇` terminal. Includes an `UnguardedSpec` baseline that TLC confirms *breaks*
  `NoCrossRequestConfusion` — proving the guard matters.
- **`proofs/tla/check-tla.sh`** — runner that model-checks every spec with TLC.
- **Correction — the TLA+ specs were never actually being checked.** All three
  failed to parse in TLC (a `----` divider before `EXTENDS`; `[]`-of-bare-action
  temporal properties). After fixing the syntax, TLC surfaced and we fixed three
  real defects, then re-verified all specs green:
  - `TransactionSpec.TerminalIsTerminal` claimed terminal states *never* leave,
    contradicting the spec's own `UserRetry` (`Failed`/`Rejected → Idle`);
    corrected to "no port message moves a terminal state."
  - `WalletSpec` mixed integer chain ids with the string `NONE` sentinel — TLC
    aborted comparing `"NONE"` with `369`; chain ids now modelled as strings.
  - `WalletSpec.NoDeadlock` did not hold under `WF(Next)` alone (the wallet
    could stay `Connected` forever); holds once `UserDisconnect` has weak
    fairness.
  `proofs/COVERAGE.md` updated to match; the three specs are now genuinely
  Model-checked (TLC 2.19 / Java 21).

### Verification — Sign non-confusion + state-machine property tests

- **`tests/SignFuzzTest.elm`** — new fuzz module (7 properties) for `Web3.Sign`
  (backlog #7). Verifies EIP-191 vs EIP-712 can never be confused on the wire
  (`encode` always tags `signTypedData`, `personalSign` always tags
  `personalSign`, tags distinct, exact id/from/message), and that the
  `SignState` machine is safe under arbitrary message streams: terminal states
  are absorbing, a response for a different correlation id never transitions a
  pending sign (no cross-request confusion), and `SignIdle` never becomes
  pending/signed from messages alone. All hold.

### Verification — Units conversion property tests

- **`tests/UnitsFuzzTest.elm`** — new fuzz module (5 properties) for
  `Web3.Units`. Existing coverage fuzzed only `parseEther ∘ formatEther` at 18
  decimals on sub-gwei values; this adds the general case (backlog #4): exact
  `parseUnits d (formatUnits d n) = Just n` for any decimals `d ∈ [0,30]` and
  multi-limb (uint256-scale) `n`; agreement between the ether-specific and
  general functions (`formatEther = formatUnits 18`); ether-scale round-trip on
  multi-limb values; and truncation of fractional digits past `d`. All hold —
  conversions are exact with no precision loss.

### Verification — ABI calldata head/tail property tests

- **`tests/CalldataFuzzTest.elm`** — new fuzz module (4 properties) for
  `Web3.Abi.Calldata`, previously covered only by fixed `cast` vectors. Verifies
  the invariants that catch a head/tail offset bug the fixed vectors would miss:
  output is always `0x` + selector + lowercase-hex body aligned to 32-byte
  words; static `uint256` slots round-trip (`decode ∘ encode = id` on multi-limb
  values); and dynamic (`string`) head/tail offsets are 32-aligned, start at the
  head size, strictly increase, stay in bounds, with correct length words and
  intact content. All hold — the head/tail layout is sound under fuzzing.

### Verification — BigInt algebraic-law property tests

- **`tests/BigIntLawsTest.elm`** — new fuzz module (12 properties) covering the
  arithmetic laws that `BigIntFuzzTest` did not: `add`/`mul` commutativity and
  associativity, `mul` distributes over `add`, `compare` agrees with integer
  order and is monotone under addition, and the division algorithm
  (`a = (a/b)*b + (a mod b)`, `0 ≤ a mod b < b`, div/mod by zero → `Nothing`).
  Values are built as genuine multi-limb bignums (past `Int` range) so carries
  are exercised. All laws hold — no invariant violation found.
- These back the still-`sorry` Lean obligations `natMul_val`,
  `natCompare_spec`, `natDivMod_spec` with machine-verified (if weaker)
  evidence. `proofs/COVERAGE.md` updated accordingly.

### Verification — Multicall property tests

- **`tests/MulticallTest.elm`** — new fuzz module (3 properties) covering
  `Web3.Multicall`, previously untested. Verifies that `encode` preserves the
  batch id and every call (contract address, method, args) in order, and that
  `responseDecoder` preserves every per-call result — order, `success`, and
  `data` intact. This is the "aggregation preserves per-call decode
  correctness" invariant from the proof backlog.
- `proofs/COVERAGE.md` — added a **Property-tested (Elm fuzz)** section grading
  the above.

Test/doc only. No source changes; public API unchanged.

## 1.2.0 — 2026-05-14

### Added — pure-Elm ABI calldata encoding

The library no longer needs JavaScript to encode contract calls. Calldata
production is now fully native Elm, which means generated dapps can drop
to a pure-pass-through port bridge.

- **`Web3.Abi.Calldata`** — new module. Produces canonical `"0x…"` calldata
  from a baked selector and a list of typed `Slot`s. Implements the full
  Solidity ABI head/tail layout (static slots inline, dynamic with
  offset/tail), covering:
  - Static: `address`, `uint256` / `uintN`, `int256` (two's-complement),
    `bool`, `bytes32`, `bytesN`
  - Dynamic: `string`, `bytes`, `list` (T[]), `tuple`
  Verified against `cast calldata` vectors for the common ERC-20 shapes.
- **`Web3.BigInt.toHexString`** — converts a BigInt to lowercase hex
  without a `"0x"` prefix or leading zeros. Round-trip tested against
  `fromHexString` over uint256 max.
- **`Web3.Contract.Call.readCallRaw`** — variant of `readCall` that takes
  pre-built hex `data` instead of method+args. The encoded port message
  carries `data` directly; the JS bridge becomes pure pass-through.
- **`Web3.Contract.Send.writeCallRaw` / `payableCallRaw`** — same pattern
  for state-changing calls.

The existing `readCall` / `writeCall` / `payableCall` API is unchanged —
this is a pure additive release.

---

## 1.1.0 — 2026-05-13

### Added

- `Web3.Subscription` — typed `eth_subscribe` / `eth_unsubscribe` flow with
  port-Cmd helpers, decoder for inbound `LogEvent` messages, and a
  `Status` lifecycle (`Open` / `Closed` / `Error`). Pair with the
  `elm-web3-ports.ts` runtime for end-to-end type safety on event streams.
- `js/elm-web3-ports.ts` — canonical, type-checked TypeScript source for
  the JS runtime bridge. Consumers without a TS toolchain can use the
  pre-built `js/elm-web3-ports.js` produced by `bun js/build.ts`.
- `js/elm-web3-ports.d.ts` — public type declarations for the runtime
  bridge.

No breaking changes; this is a pure additive release.

---

## 1.0.0 — 2026-05-09

First publish of `intrepidshape/elm-web3` on the Elm package registry.
Published by [Intrepid Development](https://intrepiddev.com.au).

The Elm registry tracks per-namespace versions, so this package starts at
1.0.0 under the `intrepidshape` namespace. The internal evolution from
1.0.0 → 2.0.x continued under an earlier namespace and is preserved as
historical CHANGELOG entries below for context. The 2.0.2
source content is what shipped here as 1.0.0.

The earlier namespace is no longer maintained.

---

## 2.0.2 (legacy) — 2026-05-09

### Namespace move

Package and repository moved to the `intrepidshape` namespace, where it lives
alongside the rest of [Intrepid Development](https://intrepiddev.com.au)'s
open-source work. No source changes — `elm install intrepidshape/elm-web3`
is a drop-in replacement for the prior namespace.

The earlier namespace is no longer maintained.

---

## 2.0.1 (legacy) — 2026-03-27

### Changes

- Removed unused `elm/http` and `elm/time` from `dependencies`. Neither was imported
  by any of the 19 source modules; their presence was carry-over from an earlier draft.
  No API changes — this is a pure dependency cleanup.

---

## 2.0.0 (legacy) — 2026-03-27

### New modules

- `Web3.Balance` — native ETH/PLS balance queries with correlation IDs (`getBalance`, `encode`, `decoder`)
- `Web3.Block` — block number queries, block data fetching, block number watching, transaction count per block (`getBlockNumber`, `getBlock`, `watchBlockNumber`, `getBlockTransactionCount`)
- `Web3.Fee` — gas price (eth_gasPrice) and EIP-1559 fee history queries (`getGasPrice`, `getFeeHistory`, `FeeHistory`)
- `Web3.Query` — on-chain read queries: nonce, storage slot, contract bytecode, transaction lookup (`getTxCount`, `getStorageAt`, `getCode`, `getTransaction`, `TransactionInfo`)
- `Web3.Units` — pure-Elm ETH/ERC-20 unit conversion, no port required (`formatEther`, `parseEther`, `formatUnits`, `parseUnits`)
- `Web3.Crypto` — keccak256 hashing via port (`keccak256`, `encode`, `decoder`)

### New in existing modules

- `Web3.Types.encodeBlockNumber` — shared `BlockNumber -> E.Value` encoder used by Block, Fee, and Call modules
- `Web3.BigInt.decoder` — JSON decoder for BigInt from a decimal string
- `Web3.BigInt.fromHexString` — parse a 0x-prefixed hex string as a non-negative BigInt
- `Web3.BigInt.fromIntString` — alias for `fromString` (API symmetry with `fromHexString`)
- `Web3.BigInt.mod` — remainder operation returning `Maybe BigInt`
- `Web3.Transaction.TxCmd` — command type for requesting receipts (`RequestReceipt TxHash String`)
- `Web3.Transaction.encodeCmd` — encode a `TxCmd` for the JS port
- `Web3.Transaction.transactionConfirmations` — compute confirmation count given current block number
- `Web3.Transaction.Msg.TxReset` — reset a terminal transaction back to `Idle`
- `Web3.Transaction.Msg.TxReceiptNotFound` — receipt polling no-op (schedule retry in app)
- `Web3.Contract.Call.withFrom` — set a `from` address on a read call (simulates a write without broadcasting)
- `Web3.Contract.Send.deployCall` — encode a contract deployment for the port
- `Web3.Contract.Send.encodeRawSend` — broadcast a pre-signed raw transaction
- `Web3.Contract.Send.WriteCall` — the write call type is now exported
- `Web3.Contract.Send.payableCall`, `writeCall`, `withGasLimit`, `encode`, `estimateGas` — all now fully documented
- `Web3.Contract.Event.EventLog` — now includes `contract`, `topics` fields (breaking change; see below)
- `Web3.Wallet.ChainConfig` — configuration record for EIP-3085 `wallet_addEthereumChain`
- `Web3.Wallet.startConnect` — transition wallet state to `Connecting` before sending the connect port command
- `Web3.Wallet.watchAsset` — EIP-747: add a token to the wallet UI
- `Web3.Wallet.requestPermissions` / `getPermissions` — EIP-2255 wallet permissions
- `Web3.Wallet.isReadOnly` — true when in `ReadOnly` mode (rpcUrl set, no wallet)
- `Web3.Wallet.addChain` — EIP-3085: add a new chain to the wallet
- `Web3.Wallet.State.ReadOnly` — new wallet state for rpcUrl-only connections
- `Web3.Sign.SignState` / `SignMsg` — signing state machine types are now exposed
- `Web3.Sign.startSign`, `signUpdate`, `isSignTerminal` — signing lifecycle helpers
- `Web3.Sign.personalSign` — personal_sign (EIP-191)
- `Web3.Chain` — added: `arbitrum`, `avalanche`, `base`, `bsc`, `fantom`, `gnosis`, `linea`, `optimism`, `polygon`, `scroll`, `zksync`
- `Web3.Abi.Decode` — added: `uint8`, `uint16`, `uint32`, `uint64`, `uint128`, `hexSlot`, `uint256Slot`, `addressSlot`, `boolSlot`, `stringSlot`, `listSlot`, `tuple2Hex`, `tuple3Hex`
- `Web3.Abi.Encode` — added: `bytesN`, `list`, `tuple2`, `tuple3`
- `Web3` (top-level) — added `encodeTxCmd`; `Msg` now includes `TxCmdMsg`

### Breaking changes

- `Web3.Contract.Event.EventLog` — added `contract : Address` and `topics : List String` fields. Update all patterns matching this record.
- `Web3.Transaction.Msg` — added `TxReset` and `TxReceiptNotFound` variants. Update all `case` expressions on `Msg`.
- `Web3.Wallet.Msg` — added `ReadOnlyMode`, `ChainAdded`, `SwitchChainOk`, `AssetWatched`, `GotPermissions` variants. Update all `case` expressions on `Msg`.
- `Web3.Wallet.State` — added `ReadOnly` variant. Update all `case` expressions on `State`.
- `Web3.Wallet.WalletCmd` — added `RequestAddChain`, `RequestWatchAsset`, `RequestPermissions`, `GetPermissions` variants. Update all `case` expressions on `WalletCmd`.
- `Web3.Wallet.getBalance` removed — use `Web3.Balance.getBalance` instead.
- `Web3.Wallet.balanceDecoder` removed — use `Web3.Balance.decoder` instead.
- `Web3.Msg` — added `TxCmdMsg` variant. Update all `case` expressions on `Web3.Msg`.

---

## 1.0.0 — 2026-03-26

Initial release.

- `Web3.Types` — opaque Address, TxHash, ChainId, Wei types with validation
- `Web3.Wallet` — EIP-6963 multi-wallet discovery, connection state machine
- `Web3.Transaction` — transaction lifecycle state machine with revert reason decoding
- `Web3.Contract.Call` — typed read-only contract calls
- `Web3.Contract.Send` — typed write calls, payable calls, gas estimation
- `Web3.Contract.Event` — event subscriptions and historical log queries
- `Web3.Multicall` — batch reads via Multicall3
- `Web3.Sign` — EIP-712 typed data signing
- `Web3.Chain` — Ethereum, PulseChain, Sepolia, and custom chain definitions
- `Web3.BigInt` — arbitrary-precision integers, zero dependencies, base-10^7 digit representation
- `Web3.Abi.Encode` / `Web3.Abi.Decode` — ABI parameter helpers
- JS port bridge (`js/elm-web3-ports.js`) — ~500 lines, zero dependencies
- ABI-to-Elm code generator (`codegen/`)
- Formal verification: TLA+ state machine specs, Lean 4 type soundness proofs
