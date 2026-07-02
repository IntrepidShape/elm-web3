# TLA+ ↔ Elm conformance audit

Action-by-action mapping between the three TLA+ specs and the Elm `update`
functions they claim to model. Audited 2026-07-02 against the current source;
every divergence found is logged at the bottom with its resolution. A spec that
doesn't match the code proves the wrong machine — this document is what makes
the "Model-checked" grade in `COVERAGE.md` meaningful.

Conventions: "stutter" means the Elm arm returns the state unchanged and the
TLA models it as either an explicit `UNCHANGED vars` action or nothing (both
are equivalent under `[][Next]_vars`).

---

## 1. WalletSpec.tla ↔ `Web3.Wallet.update` / `startConnect`

| Elm code path | TLA action | Conforms |
|---|---|---|
| `startConnect`: `Disconnected\|Error → Connecting`, else no-op | `UserConnect` (enabled from `{Disconnected, Error}`) | ✓ |
| disconnect round-trip: `WalletDisconnected` sends every state except `ReadOnly` to `Disconnected` | `UserDisconnect` (enabled from all states except `Disconnected`, `ReadOnly`) + `EvtWalletDisconnected` | ✓ (fixed — see D-W1) |
| `WalletConnected addr chain`, valid addr, `chain == expected` → `Connected` (from **any** state) | `EvtConnectedCorrectChain(a, c)` (no state precondition) | ✓ |
| `WalletConnected`, valid addr, wrong chain → `WrongChain` | `EvtConnectedWrongChain(a, c)` | ✓ |
| `WalletConnected`, invalid addr → `Error` (from any state, incl. `ReadOnly`) | `EvtConnectedInvalidAddr` | ✓ |
| `ChainChanged` from `Connected` → `Connected`/`WrongChain` | `EvtChainChangedFromConnected(c)` | ✓ |
| `ChainChanged` from `WrongChain` → `Connected`/`WrongChain` (manual switch recovers) | `EvtChainChangedFromWrongChain(c)` | ✓ (code + spec fixed — see D-W2) |
| `ChainChanged` from `ReadOnly`/others → no-op | `EvtChainChangedFromOther` | ✓ |
| `AccountChanged` valid addr from `Connected`/`WrongChain` → address updated | `EvtAccountChangedFromConnected/FromWrongChain(a)` | ✓ |
| `AccountChanged` otherwise → no-op | `EvtAccountChangedNoOp` | ✓ |
| `WalletError` → `Error`, except `ReadOnly` sticky | `EvtWalletError` | ✓ |
| `ReadOnlyMode` → `ReadOnly` only from `Disconnected`/`Connecting`/`Error`; no-op in a live session | `EvtReadOnlyMode` (precondition `{Disconnected, Connecting, Error}`) | ✓ (code + spec fixed — see D-W3) |
| `SwitchChainOk` from `WrongChain` → `Connected`/`WrongChain`; no-op elsewhere | `EvtSwitchChainOk(c)` / `EvtSwitchChainOkNoOp` | ✓ |
| `WalletsDiscovered`/`ChainAdded`/`AssetWatched`/`GotPermissions` → no-op | `EvtWalletsDiscovered`/`EvtNoOp` | ✓ |

**Abstractions (deliberate, documented):**
- Chain ids are modeled as strings (`{"1", "369"}`) — the Elm code only ever
  compares them for equality, and TLC needs the `NONE` sentinel to be
  type-comparable.
- `Connecting` timeout/failure is modeled by `EvtWalletError` /
  `EvtWalletDisconnected` arriving in `Connecting`; the Elm code has no
  dedicated timeout message.
- The Elm `WrongChain ConnectedInfo T.ChainId` second field (the *expected*
  chain) is a constant (`EXPECTED_CHAIN`) in the model, not a variable.

## 2. TransactionSpec.tla ↔ `Web3.Transaction.update`

| Elm code path | TLA action | Conforms |
|---|---|---|
| app calls send: `Idle → AwaitingSignature` | `UserSend` | ✓ |
| `TxReset` from **any** terminal (incl. `Confirmed`) → `Idle`; no-op otherwise | `UserRetry` (enabled from all `TerminalStates`) | ✓ (spec fixed — see D-T1) |
| `TxSubmitted` valid hash, from `AwaitingSignature` → `Submitted` | `GuardedTxSubmitted(h)` | ✓ |
| `TxSubmitted` invalid hash → `Failed` | `GuardedTxSubmittedInvalid` | ✓ |
| `TxConfirmation` from `Submitted` (count ≥ 1) / `Confirming` (count > current) → `Confirming`; stale counts dropped | `GuardedTxConfirmation(h, n)` (`n > confirmCount`) | ✓ (code fixed — see D-T5) |
| `TxConfirmation` invalid hash → no-op | stutter | ✓ |
| `TxConfirmed` valid receipt from `Submitted`/`Confirming` → `Confirmed` | `GuardedTxConfirmed(h)` | ✓ |
| `TxConfirmed` invalid receipt hash → `Failed` | `GuardedTxConfirmedInvalid` | ✓ (spec fixed — see D-T4) |
| `TxFailed` from any non-terminal (**including `Idle`**) → `Failed` | `GuardedTxFailed` (`PendingStates ∪ {"Idle"}`) | ✓ (spec fixed — see D-T3) |
| `TxRejected` from `AwaitingSignature` → `Rejected` | `GuardedTxRejected` | ✓ |
| `TxRejected` from `Submitted`/`Confirming` → `Failed "transaction rejected by wallet"` | `GuardedTxRejectedLate` | ✓ (spec fixed — see D-T2) |
| `TxReceiptNotFound` → no-op | stutter | ✓ |
| terminal + any port message → no-op | top-of-update `isTerminal` guard ↔ every guarded action excludes terminals | ✓ |

**Abstractions:** the hash in `Confirming` may differ from the submitted hash
(both in code and spec) — this is intentional: a wallet speed-up (EIP-1559
replacement) legitimately delivers confirmations under a new hash. Hash
*stability* is therefore deliberately **not** an invariant.

## 3. SignSpec.tla ↔ `Web3.Sign.startSign` / `signUpdate`

| Elm code path | TLA action | Conforms |
|---|---|---|
| `startSign id` from `SignIdle` → `SignPending id`; no-op from all other states | `StartSign(i)` (enabled only from `SignIdle`) | ✓ |
| `SignResponse id sig`, id matches → `Signed` | `GuardedResponse(i)` | ✓ |
| `SignError id err`, id matches → `SignFailed` | `GuardedError(i)` | ✓ |
| `SignCancel id`, id matches → `SignRejected` | `GuardedCancel(i)` | ✓ |
| any message, id ≠ pending id → no-op | `GuardedMismatch(i)` | ✓ |
| any message in terminal state → no-op (`isSignTerminal` guard) | no action enabled from terminals | ✓ |
| any message in `SignIdle` → no-op | stutter | ✓ |

**Known gap (not a divergence):** the Elm `Sign` machine has **no reset** — a
terminal `SignState` stays terminal forever. Apps start a new signature by
constructing `SignIdle` directly (constructors are exposed). This is why
SignSpec's terminal states are genuine sinks and TLC runs with `-deadlock`.

---

## Divergence log (found 2026-07-02, all resolved)

Every entry states what diverged, which side was wrong, and the resolution.

### Code bugs found by the audit (Elm fixed, spec + tests updated)

- **D-W2 — `ChainChanged` ignored in `WrongChain`.** A user who fixed their
  chain manually in the wallet UI (the EIP-1193 `chainChanged` event) stayed
  stuck in `WrongChain` forever; only the app-initiated `switchChain`
  round-trip could recover. The old spec modeled the same gap, and the old
  `WrongChainCanResolve` "pass" leaned on TLC fairness the real world doesn't
  have. *Fixed in `Wallet.update` (WrongChain branch added), spec action
  `EvtChainChangedFromWrongChain` added, regression tests added.*
- **D-W3 — `ReadOnlyMode` tore down live sessions.** A stray `readOnly`
  announcement (init race) moved `Connected`/`WrongChain` to `ReadOnly`,
  destroying the session. *Fixed in `Wallet.update` (ignored in live
  sessions), spec precondition tightened, regression tests added. This is
  also what makes the claimed-but-previously-unchecked `ConnectedStability`
  property true.*
- **D-T5 — confirmation counts were not monotonic in code.** The module docs
  and the spec both promised "confirmation counts only increase", but
  `update` accepted any count, including regressions from stale/reordered
  port messages. *Fixed in `updateNonTerminal` (`count > current` guard;
  `count ≥ 1` from `Submitted`), unit + fuzz regression tests added. The
  spec's `MonotonicConfirmations` was simultaneously a vacuous invariant
  (`confirmCount >= confirmCount`) — rewritten as a real action property and
  moved to PROPERTIES in the .cfg.*

### Spec was wrong (TLA fixed to match code)

- **D-T1 — `UserRetry` too narrow.** Spec allowed retry only from
  `Failed`/`Rejected`; Elm `TxReset` resets **any** terminal, including
  `Confirmed`. This also caused a phantom TLC "deadlock" at `Confirmed` that
  had been suppressed with `-deadlock`. *Spec extended to all terminals;
  deadlock checking re-enabled for TransactionSpec.*
- **D-T2 — late rejection missing.** Elm maps `TxRejected` from
  `Submitted`/`Confirming` to `Failed` (you can't un-broadcast); spec had no
  such action. *`GuardedTxRejectedLate` added.*
- **D-T3 — `TxFailed` source set too narrow.** Elm accepts `TxFailed` from
  any non-terminal state including `Idle` (documented behavior); spec
  restricted it to pending states. *Spec made faithful (`∪ {"Idle"}`).
  Flagged: a stray failure in `Idle` shows an error for a tx that never
  existed — defensible (fail loud) but worth revisiting at the next minor.*
- **D-T4 — invalid-receipt path missing.** Elm's `confirmReceipt` maps an
  invalid receipt hash to `Failed`; spec only modeled the happy path.
  *`GuardedTxConfirmedInvalid` added.*
- **D-W1 — `UserDisconnect` from `ReadOnly` modeled a nonexistent code
  path.** `WalletDisconnected` keeps `ReadOnly` sticky and no other path
  reaches `Disconnected` from `ReadOnly`; the spec allowed it, and the old
  `NoDeadlock == []<>(state = "Disconnected")` claim depended on it. The
  claim was **false for the real machine**. *Action precondition fixed;
  liveness reformulated as `EventuallyAtRest` (every session eventually
  reaches `Disconnected` **or** `ReadOnly`), which is true and checked.*

### Stale/incorrect spec comments corrected

- TransactionSpec's "UNGUARDED = faithful to the Elm code" comment described
  an older version of the code and contradicted the file's own header. The
  Elm update guards every transition; `UnguardedNext` is a permissive
  baseline used to demonstrate which invariants the guards are load-bearing
  for.
- WalletSpec claimed "UserDisconnect can always return to Disconnected"
  (false from `ReadOnly`, see D-W1).

### Previously defined but never checked

`ConnectedStability` and `ReadOnlySticky` existed in WalletSpec but were
absent from `WalletSpec.cfg` — `COVERAGE.md` listed the former as
model-checked when TLC had never evaluated it. Both are now in the .cfg and
pass (`ReadOnlySticky`'s allowed-exit set corrected to
`{ReadOnly, Connected, WrongChain, Error}` to match the code's
malformed-address diagnostic path). `WrongChainCanResolve` remains defined
but deliberately unchecked — it would require assuming the user eventually
fixes their chain; see the comment in the spec.
