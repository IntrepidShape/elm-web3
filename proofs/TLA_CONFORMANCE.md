# TLA+ <-> Elm conformance audit

Action-by-action mapping between the three TLA+ specs and the Elm `update`
functions they claim to model. A spec that doesn't match the code proves the
wrong machine - this document is what makes the "Model-checked" grade in
`COVERAGE.md` meaningful.

| Spec | Audited against | Date | Status |
|---|---|---|---|
| `WalletSpec.tla` | `src/Web3/Wallet.elm` @ 2.0.0 (tree `87d686b`) | **2026-07-27** | re-audited in full; spec rewritten |
| `TransactionSpec.tla` | `src/Web3/Transaction.elm` | 2026-07-02, re-verified 2026-07-27 | mapping unchanged (see below) |
| `SignSpec.tla` | `src/Web3/Sign.elm` | 2026-07-02, re-verified 2026-07-27 | mapping unchanged (see below) |

"Re-verified" means the module was diffed against the revision the audit was
written against and the difference was shown to be doc comments only:

```
git diff a4e1d77..HEAD -- src/Web3/Transaction.elm   # ASCII sweep 5546420 only
git diff 4dbea58..HEAD -- src/Web3/Sign.elm          # ASCII sweep 5546420 only
```

Both diffs touch only `--` and `{-| -}` text (em dash -> hyphen, arrow ->
`->`). No expression changed, so the 2026-07-02 action mapping still holds.
That is a mechanical check, not a re-read: sections 2 and 3 below are carried
forward on the strength of the diff, and are labelled accordingly.

Conventions: "stutter" means the Elm arm returns the state unchanged and the
TLA models it as either an explicit `UNCHANGED` action or nothing (both are
equivalent under `[][Next]_vars`).

---

## 0. Why this audit happened, and what it says about the last one

The header of this file used to read "Audited 2026-07-02" with a table of ✓s
for `WalletSpec`. That audit was real and correct **on 2026-07-02**. Five days
later, `837991a` and `1657054` (both 2026-07-07) rewrote the connect path
around `RequestId`, added supersede semantics, `timeoutConnect`, and three new
`Msg` variants. Neither commit touched `WalletSpec.tla` or this file. On
2026-07-16 that became release 2.0.0, and the proofs page went on advertising
a TLC-verified state machine whose `Connecting` state had not existed in the
code for nine days.

Nothing lied. The ✓s were simply never re-checked, and nothing forced them to
be. That is now `scripts/check-spec-lockstep.ts`, which fails CI when
`src/Web3/Wallet.elm`, `src/Web3/Transaction.elm` or `src/Web3/Sign.elm`
changes without its spec - and which was demonstrated red against the exact
commits above before being trusted:

```
bun run scripts/check-spec-lockstep.ts --range 837991a~1..837991a   # exit 1
bun run scripts/check-spec-lockstep.ts --range 1657054~1..1657054   # exit 1
```

---

## 1. WalletSpec.tla <-> `Web3.Wallet` (2.0.0)

Every arm of `update` (`Wallet.elm:203-383`) plus the two state-transition
helpers. Line numbers are the audited revision.

### Connect lifecycle - the part the old spec did not model at all

| Elm code path | TLA action | Conforms |
|---|---|---|
| `startConnect rid`: `Disconnected \| Error -> Connecting rid` (411-419) | `UserConnect`, then-branch | ✓ |
| `startConnect rid`: `Connecting _ -> Connecting rid` - a newer attempt supersedes the in-flight one (420-421) | `UserConnect`, then-branch (`Connecting` is in the enabling set) | ✓ (new) |
| `startConnect rid`: `Connected \| WrongChain \| ReadOnly -> ` unchanged (423-424) | `UserConnect`, else-branch: `UNCHANGED fsm`, but `nextRid` still advances | ✓ (new) |
| `timeoutConnect rid`: `Connecting activeId`, `rid == activeId -> Disconnected` (434-441) | `EvtTimeoutConnect(r)`, then-branch | ✓ (new) |
| `timeoutConnect rid`: id mismatch, or any non-`Connecting` state -> unchanged (442-445) | `EvtTimeoutConnect(r)`, else-branch | ✓ (new) |
| `WalletConnected` staleness test: drop iff `(Connecting activeId, Just rid)` and `rid /= activeId` (206-222) | `EvtConnectedOk` / `EvtConnectedBadAddr`, then-branch | ✓ (new) |
| `WalletConnected (Just rid)` when NOT `Connecting` -> applied, never stale (218-219) | same actions, else-branch (guard requires `state = "Connecting"`) | ✓ (new) |
| `WalletConnected Nothing` (silent page-load reconnect) -> always applied (218-219) | `mrid = NO_RID`, excluded from the stale test | ✓ (new) |
| `WalletConnected`, valid address, `chain == expected -> Connected` (225-232) | `EvtConnectedOk(mrid, a, c)` with `c = EXPECTED_CHAIN` | ✓ |
| `WalletConnected`, valid address, wrong chain -> `WrongChain info expectedChain` (234-235) | `EvtConnectedOk`, else-branch | ✓ |
| `WalletConnected`, malformed address -> `Error` (237-238) | `EvtConnectedBadAddr` | ✓ |
| `WalletConnectRejected rid` from `Connecting activeId`, ids equal -> `Disconnected` (240-245) | `EvtConnectRejected(r)`, then-branch | ✓ (new) |
| `WalletConnectRejected rid`, id mismatch or other state -> unchanged (246-251) | `EvtConnectRejected(r)`, else-branch | ✓ (new) |
| `WalletConnectPending _` -> unchanged, from **every** state (253-259) | `EvtConnectPending(r)`: `UNCHANGED fsm` unconditionally | ✓ (new) |
| `WalletConnectFailed rid _ msg` from matching `Connecting` -> `Error msg` (261-267) | `EvtConnectFailed(r)`, then-branch | ✓ (new) |
| `WalletConnectFailed`, id mismatch or other state -> unchanged (268-271) | `EvtConnectFailed(r)`, else-branch | ✓ (new) |

### Session lifecycle - unchanged since the 2026-07-02 audit

| Elm code path | TLA action | Conforms |
|---|---|---|
| disconnect round-trip: `WalletDisconnected` sends every state except `ReadOnly` to `Disconnected` (273-283) | `UserDisconnect` (enabled from all states except `Disconnected`, `ReadOnly`) + `EvtWalletDisconnected` | ✓ |
| `ChainChanged` from `Connected` -> `Connected`/`WrongChain` (290-299) | `EvtChainChanged(c)`, then-branch | ✓ |
| `ChainChanged` from `WrongChain` -> `Connected`/`WrongChain` (manual switch recovers) (301-315) | `EvtChainChanged(c)`, then-branch | ✓ |
| `ChainChanged` from `ReadOnly` / `Connecting` / others -> no-op (286-288, 317-318) | `EvtChainChanged(c)`, else-branch | ✓ |
| `AccountChanged`, valid address, from `Connected`/`WrongChain` -> address updated (326-331) | `EvtAccountChanged(a)`, then-branch | ✓ |
| `AccountChanged` otherwise (incl. `ReadOnly`, malformed address) -> no-op (321-334) | `EvtAccountChanged(a)`, else-branch (malformed addresses are abstracted; see below) | ✓ |
| `WalletError` -> `Error`, except `ReadOnly` sticky (336-342) | `EvtWalletError` | ✓ |
| `ReadOnlyMode` -> `ReadOnly` unless a live session exists (347-359) | `EvtReadOnlyMode` | ✓ |
| `SwitchChainOk` from `WrongChain` -> `Connected`/`WrongChain`; no-op elsewhere (366-377) | `EvtSwitchChainOk(c)` | ✓ - **but see D-W4** |
| `WalletsDiscovered` / `ChainAdded` / `AssetWatched` / `GotPermissions` -> no-op (344, 361-364, 379-383) | `EvtNoOp` | ✓ |

### Not modeled, deliberately

- `encode` / `decoder` (600-743). Codec correctness is a different obligation:
  Lean (`lean/WalletCodec.lean`) proves the round trip, and
  `scripts/check-port-parity.ts` checks the wire tags against the JS bridge.
- `isConnecting`, `connectingRequestId`, `isConnected`, `isReadOnly`,
  `getAddress`, `getChainId` (454-591). Pure queries over `State`; they add no
  transitions. `getChainId` is where D-W4 becomes observable.

### Abstractions (deliberate, and each one is a claim about scope)

- **Chain ids are strings** (`{"1", "369"}`); the Elm code only ever compares
  them for equality, and TLC needs the `NONE` sentinel to be type-comparable.
- **The model's `chain` variable is `ConnectedInfo.chainId`** - the chain the
  wallet reports. The `WrongChain ConnectedInfo T.ChainId` second field is the
  *expected* chain and is the constant `EXPECTED_CHAIN`.
- **`RequestId`s are bounded** by `MAX_REQUESTS` (3 in the .cfg). Two
  overlapping attempts suffice to exhibit supersession; the third gives TLC a
  chance to find anything that needs three. Behaviours that would mint a
  fourth id are truncated, so the properties are verified for up to three
  connect attempts per run, not for all runs.
- **Monotone id minting is an ASSUMPTION, not a proof.** `Wallet.elm:113-120`
  puts the counter in the caller's hands; the model mints from `nextRid` and
  increments. `SupersedeUsesFreshId` therefore says "given a caller that
  increments, an older attempt can never reclaim the slot". An app that reuses
  or decrements ids is outside the model - and outside the module's contract.
- **`ConnectFailureReason` is abstracted away.** `Wallet.update` ignores it
  (`WalletConnectFailed rid _ errorMessage`, 261), so it cannot affect a
  transition. The decode itself is covered by unit tests.
- **Error strings are abstracted to `hasError`.** No transition inspects them.
- **Malformed addresses appear only on the `WalletConnected` path.** The Elm
  `AccountChanged` arm no-ops on a malformed address (333-334), which is
  modeled as a stutter rather than an explicit action.
- **`lastResp` is a history variable.** It records the `(id, kind)` a step
  delivered so the stale-drop properties can be stated as action formulas; it
  gates nothing.

### What TLC now checks (WalletSpec.cfg)

10 invariants and 6 properties, over 323 distinct states, deadlock check ON:

`TypeOK`, `ConnectedRequiresAddress`, `DisconnectedHasNoAddress`,
`ErrorHasNoAddress`, `ReadOnlyHasNoAddr`, `ConnectingHasNoAddress`,
`ConnectingIffActiveRequest`, `ActiveRidWasIssued`, `ErrorFlagMirrorsState`,
`WrongChainIsOffExpected`; `EventuallyAtRest`, `ConnectedStability`,
`ReadOnlySticky`, `StaleConnectResponseDropped`,
`ResolutionRequiresActiveRequest`, `SupersedeUsesFreshId`.

**Non-vacuity was demonstrated, not assumed.** Three mutations of the spec
were model-checked before the real one was accepted:

| Mutation | Expected | TLC said |
|---|---|---|
| `EvtConnectRejected` drops the `r = activeRid` guard (i.e. the pre-2.0 machine) | violation | `Action property StaleConnectResponseDropped is violated`, 4-state counterexample: connect (id 1) -> connect again (id 2, supersedes) -> `connectRejected 1` arrives -> `Disconnected`, with attempt 2 still live in the wallet |
| `UserConnect` reuses id 1 when superseding | violation | `Action property SupersedeUsesFreshId is violated` |
| assert the dual `Connected => chain = EXPECTED_CHAIN` | violation (see D-W4) | `Invariant ConnectedChainIsExpected is violated`, 3-state counterexample |

`WrongChainCanResolve` remains defined but deliberately unchecked - it would
require assuming the user eventually fixes their chain. See the comment in the
spec.

## 2. TransactionSpec.tla <-> `Web3.Transaction.update`

*Carried forward from the 2026-07-02 audit; re-verified 2026-07-27 by diff
(doc comments only). Not re-read arm by arm.*

| Elm code path | TLA action | Conforms |
|---|---|---|
| app calls send: `Idle -> AwaitingSignature` | `UserSend` | ✓ |
| `TxReset` from **any** terminal (incl. `Confirmed`) -> `Idle`; no-op otherwise | `UserRetry` (enabled from all `TerminalStates`) | ✓ (spec fixed - see D-T1) |
| `TxSubmitted` valid hash, from `AwaitingSignature` -> `Submitted` | `GuardedTxSubmitted(h)` | ✓ |
| `TxSubmitted` invalid hash -> `Failed` | `GuardedTxSubmittedInvalid` | ✓ |
| `TxConfirmation` from `Submitted` (count >= 1) / `Confirming` (count > current) -> `Confirming`; stale counts dropped | `GuardedTxConfirmation(h, n)` (`n > confirmCount`) | ✓ (code fixed - see D-T5) |
| `TxConfirmation` invalid hash -> no-op | stutter | ✓ |
| `TxConfirmed` valid receipt from `Submitted`/`Confirming` -> `Confirmed` | `GuardedTxConfirmed(h)` | ✓ |
| `TxConfirmed` invalid receipt hash -> `Failed` | `GuardedTxConfirmedInvalid` | ✓ (spec fixed - see D-T4) |
| `TxFailed` from any non-terminal (**including `Idle`**) -> `Failed` | `GuardedTxFailed` (`PendingStates + {"Idle"}`) | ✓ (spec fixed - see D-T3) |
| `TxRejected` from `AwaitingSignature` -> `Rejected` | `GuardedTxRejected` | ✓ |
| `TxRejected` from `Submitted`/`Confirming` -> `Failed "transaction rejected by wallet"` | `GuardedTxRejectedLate` | ✓ (spec fixed - see D-T2) |
| `TxReceiptNotFound` -> no-op | stutter | ✓ |
| terminal + any port message -> no-op | top-of-update `isTerminal` guard <-> every guarded action excludes terminals | ✓ |

**Abstractions:** the hash in `Confirming` may differ from the submitted hash
(both in code and spec) - intentional: a wallet speed-up (EIP-1559
replacement) legitimately delivers confirmations under a new hash. Hash
*stability* is therefore deliberately **not** an invariant.

**Known pending divergence (D-T6, open):** the boundary-hardening goal splits
`Confirmed Receipt` into `Confirmed Receipt | RevertedOnChain Receipt`,
because a mined-and-reverted transaction is currently reported as success.
That is a new state and `TransactionSpec.tla` must change in the same commit.
The lockstep guard now enforces exactly that, so this entry closes itself.

## 3. SignSpec.tla <-> `Web3.Sign.startSign` / `signUpdate`

*Carried forward from the 2026-07-02 audit; re-verified 2026-07-27 by diff
(doc comments only). Not re-read arm by arm.*

| Elm code path | TLA action | Conforms |
|---|---|---|
| `startSign id` from `SignIdle` -> `SignPending id`; no-op from all other states | `StartSign(i)` (enabled only from `SignIdle`) | ✓ |
| `SignResponse id sig`, id matches -> `Signed` | `GuardedResponse(i)` | ✓ |
| `SignError id err`, id matches -> `SignFailed` | `GuardedError(i)` | ✓ |
| `SignCancel id`, id matches -> `SignRejected` | `GuardedCancel(i)` | ✓ |
| any message, id != pending id -> no-op | `GuardedMismatch(i)` | ✓ |
| any message in terminal state -> no-op (`isSignTerminal` guard) | no action enabled from terminals | ✓ |
| any message in `SignIdle` -> no-op | stutter | ✓ |

**Known gap (not a divergence):** the Elm `Sign` machine has **no reset** - a
terminal `SignState` stays terminal forever. Apps start a new signature by
constructing `SignIdle` directly (constructors are exposed). This is why
SignSpec's terminal states are genuine sinks and TLC runs with `-deadlock`.

**Worth noting for symmetry:** `Sign` guards one in-flight request by id and
refuses to start a second (`StartSign` only from `SignIdle`); `Wallet` mints a
new id and lets it supersede. Both are id-guarded, and both are checked - but
they are opposite policies, which is a deliberate difference, not an
inconsistency: a second signature request is a different signature, whereas a
second connect click is the same intent repeated.

---

## Divergence log

Every entry states what diverged, which side was wrong, and the resolution.

### Found 2026-07-27

- **D-W0 - the spec modeled a machine that had not existed for nine days.**
  `WalletSpec.tla` still had `Connecting` as a bare state after `837991a` /
  `1657054` gave it a `RequestId`, and this document still showed ✓ for a
  `startConnect` with no id argument. *Spec rewritten (v3): request ids,
  supersession, stale-response drop, `timeoutConnect`, and the three new port
  messages are all modeled and checked. Recurrence prevented by
  `scripts/check-spec-lockstep.ts`, wired into CI and demonstrated red against
  the two commits above.*

- **D-W4 - `SwitchChainOk` leaves a stale `chainId` in `Connected`. OPEN
  (code).** `Wallet.update SwitchChainOk` (366-377) rebuilds `Connected` from
  the existing `ConnectedInfo`, so after a successful app-initiated switch the
  state is `Connected` while `getChainId` still reports the pre-switch chain,
  until the wallet's own `chainChanged` event lands and corrects it. TLC finds
  it in three states: `WrongChain` on chain 1 -> `SwitchChainOk "369"` ->
  `Connected` with `chain = "1"`. *Modeled faithfully rather than smoothed
  over (`EvtSwitchChainOk` leaves `chain` UNCHANGED), and the tempting dual
  invariant `Connected => chain = EXPECTED_CHAIN` is deliberately NOT
  asserted, with the reason written into the spec.* Impact: an app reading
  `getChainId` in the window between `switchChainOk` and `chainChanged` gets a
  stale answer; every real wallet emits `chainChanged`, so the window is short
  but not empty. Fix is one line (`SwitchChainOk chain -> Connected { info |
  chainId = T.chainId chain }`) and is a behaviour change, so it belongs to a
  release, not to this audit.

- **D-W5 - the `readOnly` resolution of a connect attempt is not id-tagged.
  OPEN (port).** When no wallet is injected but an RPC pool is configured, the
  bridge answers a `connect` command with `{ tag: 'readOnly' }`, dropping
  `requestId` (`js/elm-web3-ports.ts:503-506`). `Wallet.update ReadOnlyMode`
  moves `Connecting _` to `ReadOnly` regardless of which attempt is in flight
  - the one connect-resolution path outside the `RequestId` scheme, so
  `StaleConnectResponseDropped` does not cover it. Low impact (the message is
  only emitted when there is no wallet at all, so no competing attempt can
  succeed either), but it is a hole in an otherwise total scheme. Recorded as
  F12 in `JS_PORT_PROOF.md`.

### Found 2026-07-02, all resolved

#### Code bugs found by the audit (Elm fixed, spec + tests updated)

- **D-W2 - `ChainChanged` ignored in `WrongChain`.** A user who fixed their
  chain manually in the wallet UI (the EIP-1193 `chainChanged` event) stayed
  stuck in `WrongChain` forever; only the app-initiated `switchChain`
  round-trip could recover. The old spec modeled the same gap, and the old
  `WrongChainCanResolve` "pass" leaned on TLC fairness the real world doesn't
  have. *Fixed in `Wallet.update` (WrongChain branch added), spec action
  added, regression tests added.*
- **D-W3 - `ReadOnlyMode` tore down live sessions.** A stray `readOnly`
  announcement (init race) moved `Connected`/`WrongChain` to `ReadOnly`,
  destroying the session. *Fixed in `Wallet.update` (ignored in live
  sessions), spec precondition tightened, regression tests added. This is
  also what makes the claimed-but-previously-unchecked `ConnectedStability`
  property true.*
- **D-T5 - confirmation counts were not monotonic in code.** The module docs
  and the spec both promised "confirmation counts only increase", but
  `update` accepted any count, including regressions from stale/reordered
  port messages. *Fixed in `updateNonTerminal` (`count > current` guard;
  `count >= 1` from `Submitted`), unit + fuzz regression tests added. The
  spec's `MonotonicConfirmations` was simultaneously a vacuous invariant
  (`confirmCount >= confirmCount`) - rewritten as a real action property and
  moved to PROPERTIES in the .cfg.*

#### Spec was wrong (TLA fixed to match code)

- **D-T1 - `UserRetry` too narrow.** Spec allowed retry only from
  `Failed`/`Rejected`; Elm `TxReset` resets **any** terminal, including
  `Confirmed`. This also caused a phantom TLC "deadlock" at `Confirmed` that
  had been suppressed with `-deadlock`. *Spec extended to all terminals;
  deadlock checking re-enabled for TransactionSpec.*
- **D-T2 - late rejection missing.** Elm maps `TxRejected` from
  `Submitted`/`Confirming` to `Failed` (you can't un-broadcast); spec had no
  such action. *`GuardedTxRejectedLate` added.*
- **D-T3 - `TxFailed` source set too narrow.** Elm accepts `TxFailed` from
  any non-terminal state including `Idle` (documented behavior); spec
  restricted it to pending states. *Spec made faithful. Flagged: a stray
  failure in `Idle` shows an error for a tx that never existed - defensible
  (fail loud) but worth revisiting at the next minor.*
- **D-T4 - invalid-receipt path missing.** Elm's `confirmReceipt` maps an
  invalid receipt hash to `Failed`; spec only modeled the happy path.
  *`GuardedTxConfirmedInvalid` added.*
- **D-W1 - `UserDisconnect` from `ReadOnly` modeled a nonexistent code
  path.** `WalletDisconnected` keeps `ReadOnly` sticky and no other path
  reaches `Disconnected` from `ReadOnly`; the spec allowed it, and the old
  `NoDeadlock == []<>(state = "Disconnected")` claim depended on it. The
  claim was **false for the real machine**. *Action precondition fixed;
  liveness reformulated as `EventuallyAtRest` (every session eventually
  reaches `Disconnected` **or** `ReadOnly`), which is true and checked.*

#### Stale/incorrect spec comments corrected

- TransactionSpec's "UNGUARDED = faithful to the Elm code" comment described
  an older version of the code and contradicted the file's own header. The
  Elm update guards every transition; `UnguardedNext` is a permissive
  baseline used to demonstrate which invariants the guards are load-bearing
  for.
- WalletSpec claimed "UserDisconnect can always return to Disconnected"
  (false from `ReadOnly`, see D-W1).

#### Previously defined but never checked

`ConnectedStability` and `ReadOnlySticky` existed in WalletSpec but were
absent from `WalletSpec.cfg` - `COVERAGE.md` listed the former as
model-checked when TLC had never evaluated it. Both have been in the .cfg
since 2026-07-02 and remain there.
