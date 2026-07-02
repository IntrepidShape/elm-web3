------------------------ MODULE TransactionSpec --------------------------
(*
 * TLA+ specification of the elm-web3 Transaction state machine.
 *
 * Models src/Web3/Transaction.elm — the `update` function and the
 * transaction lifecycle from user-initiated send through confirmation.
 *
 * States:  Idle, AwaitingSignature, Submitted, Confirming, Confirmed,
 *          Failed, Rejected
 *
 * Messages (from JS port):
 *   TxSubmitted hash       -> Submitted hash
 *   TxConfirmation hash n  -> Confirming hash n
 *   TxConfirmed receipt    -> Confirmed receipt
 *   TxFailed err           -> Failed err
 *   TxRejected             -> Rejected
 *
 * The Elm update function (src/Web3/Transaction.elm) guards every transition
 * (conformance audited action-by-action — see proofs/TLA_CONFORMANCE.md):
 *   - Terminal states never transition out on port messages (isTerminal check
 *     at the top of update); TxReset resets ANY terminal state to Idle
 *   - TxSubmitted    only accepted from AwaitingSignature
 *                    (invalid hash -> Failed)
 *   - TxConfirmation only accepted from Submitted or Confirming, count must
 *                    strictly increase (stale/lower counts dropped)
 *   - TxConfirmed    only accepted from Submitted or Confirming
 *                    (invalid receipt hash -> Failed)
 *   - TxFailed       accepted from any non-terminal state, INCLUDING Idle
 *   - TxRejected     from AwaitingSignature -> Rejected;
 *                    from Submitted/Confirming -> Failed (can't un-broadcast)
 *
 * This spec models two views for verification comparison:
 *   1. GuardedNext:    faithful to the current Elm code (matches above)
 *   2. UnguardedNext:  permissive baseline (any message in any state)
 *
 * All invariants hold under GuardedNext (verified by TLC).
 *
 * Invariants (state):
 *   TypeOK                 — variables are well-typed
 *   TerminalIsTerminal     — no port message moves a terminal state; the only
 *                            exit is the explicit TxReset to Idle
 *   SubmittedNeedsSignature — Submitted only reachable from AwaitingSignature
 *   ConfirmingHasHash      — Confirming state always carries a valid hash
 * Properties (temporal/action):
 *   EventuallyTerminal     — every pending tx eventually reaches terminal
 *   MonotonicConfirmations — count strictly increases while Confirming
 *
 * To verify with TLC:
 *   java -jar tla2tools.jar -config TransactionSpec.cfg TransactionSpec.tla
 *   (no -deadlock needed: TxReset from every terminal state means the state
 *    graph has no sink states)
 *)

EXTENDS Naturals, FiniteSets

CONSTANTS
    TX_HASHES,            \* Set of valid tx hashes, e.g. {"0xaaa", "0xbbb"}
    MAX_CONFIRMATIONS     \* Upper bound on confirmation count for model checking

VARIABLES
    state,                \* Current state tag
    txHash,               \* Current tx hash (or NONE)
    confirmCount,         \* Current confirmation count (0 when not confirming)
    prevState             \* Previous state tag (for transition invariants)

NONE == "NONE"

vars == <<state, txHash, confirmCount, prevState>>

--------------------------------------------------------------------------
(* State sets *)

StateSet == {"Idle", "AwaitingSignature", "Submitted", "Confirming",
             "Confirmed", "Failed", "Rejected"}

TerminalStates == {"Confirmed", "Failed", "Rejected"}

PendingStates == {"AwaitingSignature", "Submitted", "Confirming"}

--------------------------------------------------------------------------
(* Type invariant *)

TypeOK ==
    /\ state \in StateSet
    /\ txHash \in TX_HASHES \cup {NONE}
    /\ confirmCount \in 0..MAX_CONFIRMATIONS
    /\ prevState \in StateSet

--------------------------------------------------------------------------
(* Safety invariants *)

(* No PORT MESSAGE transitions a terminal state. The only way out of a terminal
   state is an explicit user retry (UserRetry), which resets to Idle — this
   mirrors the Elm `update`, whose isTerminal guard drops all incoming messages
   in a terminal state. So from a terminal prevState, state either stays put or
   becomes Idle (never jumps to another mid-lifecycle state via a message). *)
TerminalIsTerminal ==
    prevState \in TerminalStates => (state = prevState \/ state = "Idle")

(* Submitted is only reachable from AwaitingSignature.
   This ensures the user must have initiated a send before
   a hash can appear. *)
SubmittedNeedsSignature ==
    state = "Submitted" => prevState \in {"AwaitingSignature", "Submitted"}

(* Whenever in Confirming or Submitted or Confirmed state,
   we must have a valid hash. *)
ConfirmingHasHash ==
    /\ (state = "Confirming") => txHash \in TX_HASHES
    /\ (state = "Submitted")  => txHash \in TX_HASHES
    /\ (state = "Confirmed")  => txHash \in TX_HASHES

(* Confirmation count strictly increases while Confirming — an ACTION property
   (mentions primed variables), so it lives under PROPERTIES in the .cfg, not
   INVARIANTS. This replaces an earlier vacuous state-invariant formulation
   (confirmCount >= confirmCount) that could never fail.
   The Elm update enforces this since the monotonicity guard was added to
   Web3.Transaction.updateNonTerminal (stale/lower counts are dropped). *)
MonotonicConfirmations ==
    [][(state = "Confirming" /\ state' = "Confirming")
        => confirmCount' > confirmCount]_vars

--------------------------------------------------------------------------
(* Initial state *)

Init ==
    /\ state = "Idle"
    /\ txHash = NONE
    /\ confirmCount = 0
    /\ prevState = "Idle"

--------------------------------------------------------------------------
(* User action: initiate a send (transitions Idle -> AwaitingSignature) *)

UserSend ==
    /\ state = "Idle"
    /\ state' = "AwaitingSignature"
    /\ txHash' = NONE
    /\ confirmCount' = 0
    /\ prevState' = state

(* User action: TxReset — from ANY terminal state (including Confirmed) back
   to Idle. Mirrors Web3.Transaction.update TxReset, which resets whenever
   isTerminal status; from non-terminal states it is a no-op. *)
UserRetry ==
    /\ state \in TerminalStates
    /\ state' = "Idle"
    /\ txHash' = NONE
    /\ confirmCount' = 0
    /\ prevState' = state

--------------------------------------------------------------------------
(* =====================================================================
   GUARDED TRANSITIONS — the intended transaction protocol.
   Messages only arrive in the correct lifecycle order.
   ===================================================================== *)

(* TxSubmitted: wallet signed, tx submitted to mempool.
   Only valid from AwaitingSignature. *)
GuardedTxSubmitted(h) ==
    /\ state = "AwaitingSignature"
    /\ h \in TX_HASHES
    /\ state' = "Submitted"
    /\ txHash' = h
    /\ confirmCount' = 0
    /\ prevState' = state

(* TxConfirmation: a new confirmation arrived.
   Only valid from Submitted or Confirming, and count must increase. *)
GuardedTxConfirmation(h, n) ==
    /\ state \in {"Submitted", "Confirming"}
    /\ h \in TX_HASHES
    /\ n \in 1..MAX_CONFIRMATIONS
    /\ n > confirmCount               \* monotonic increase
    /\ state' = "Confirming"
    /\ txHash' = h
    /\ confirmCount' = n
    /\ prevState' = state

(* TxConfirmed: transaction fully confirmed with receipt.
   Only valid from Submitted or Confirming. *)
GuardedTxConfirmed(h) ==
    /\ state \in {"Submitted", "Confirming"}
    /\ h \in TX_HASHES
    /\ state' = "Confirmed"
    /\ txHash' = h
    /\ confirmCount' = confirmCount
    /\ prevState' = state

(* TxFailed: transaction failed (revert, out of gas, etc).
   The Elm update accepts TxFailed from ANY non-terminal state — including
   Idle (a stray failure message moves Idle to Failed; documented behavior,
   see Web3.Transaction.update docs). Modeled faithfully. *)
GuardedTxFailed ==
    /\ state \in PendingStates \cup {"Idle"}
    /\ state' = "Failed"
    /\ txHash' = txHash       \* preserve hash if we had one
    /\ confirmCount' = 0
    /\ prevState' = state

(* TxRejected: user rejected in the wallet.
   From AwaitingSignature -> Rejected.
   From Submitted/Confirming the Elm update maps rejection to
   Failed "transaction rejected by wallet" (can't un-broadcast). *)
GuardedTxRejected ==
    /\ state = "AwaitingSignature"
    /\ state' = "Rejected"
    /\ txHash' = NONE
    /\ confirmCount' = 0
    /\ prevState' = state

GuardedTxRejectedLate ==
    /\ state \in {"Submitted", "Confirming"}
    /\ state' = "Failed"
    /\ txHash' = txHash
    /\ confirmCount' = 0
    /\ prevState' = state

(* TxSubmitted with invalid hash -> Failed *)
GuardedTxSubmittedInvalid ==
    /\ state = "AwaitingSignature"
    /\ state' = "Failed"
    /\ txHash' = NONE
    /\ confirmCount' = 0
    /\ prevState' = state

(* TxConfirmed with an invalid receipt hash -> Failed
   (Web3.Transaction.confirmReceipt Nothing branch). *)
GuardedTxConfirmedInvalid ==
    /\ state \in {"Submitted", "Confirming"}
    /\ state' = "Failed"
    /\ txHash' = txHash
    /\ confirmCount' = 0
    /\ prevState' = state

--------------------------------------------------------------------------
(* Guarded next-state relation *)

GuardedNext ==
    \/ UserSend
    \/ UserRetry
    \/ \E h \in TX_HASHES :
        \/ GuardedTxSubmitted(h)
        \/ GuardedTxConfirmed(h)
        \/ \E n \in 1..MAX_CONFIRMATIONS : GuardedTxConfirmation(h, n)
    \/ GuardedTxFailed
    \/ GuardedTxRejected
    \/ GuardedTxRejectedLate
    \/ GuardedTxSubmittedInvalid
    \/ GuardedTxConfirmedInvalid

--------------------------------------------------------------------------
(* =====================================================================
   UNGUARDED TRANSITIONS — permissive baseline (any message in any state).
   This is NOT the Elm code (a stale comment once claimed it was): the Elm
   update guards every transition, matching GuardedNext above. Running TLC
   with UnguardedSpec shows which invariants the guards are load-bearing for.
   ===================================================================== *)

(* TxSubmitted: any state -> Submitted (or Failed if invalid hash) *)
UnguardedTxSubmitted(h) ==
    /\ h \in TX_HASHES
    /\ state' = "Submitted"
    /\ txHash' = h
    /\ confirmCount' = 0
    /\ prevState' = state

(* TxConfirmation: any state -> Confirming (no monotonicity guard) *)
UnguardedTxConfirmation(h, n) ==
    /\ h \in TX_HASHES
    /\ n \in 1..MAX_CONFIRMATIONS
    /\ state' = "Confirming"
    /\ txHash' = h
    /\ confirmCount' = n
    /\ prevState' = state

(* TxConfirmed: any state -> Confirmed *)
UnguardedTxConfirmed(h) ==
    /\ h \in TX_HASHES
    /\ state' = "Confirmed"
    /\ txHash' = h
    /\ confirmCount' = confirmCount
    /\ prevState' = state

(* TxFailed: any state -> Failed *)
UnguardedTxFailed ==
    /\ state' = "Failed"
    /\ txHash' = NONE
    /\ confirmCount' = 0
    /\ prevState' = state

(* TxRejected: any state -> Rejected *)
UnguardedTxRejected ==
    /\ state' = "Rejected"
    /\ txHash' = NONE
    /\ confirmCount' = 0
    /\ prevState' = state

UnguardedNext ==
    \/ UserSend
    \/ UserRetry
    \/ \E h \in TX_HASHES :
        \/ UnguardedTxSubmitted(h)
        \/ UnguardedTxConfirmed(h)
        \/ \E n \in 1..MAX_CONFIRMATIONS : UnguardedTxConfirmation(h, n)
    \/ UnguardedTxFailed
    \/ UnguardedTxRejected

--------------------------------------------------------------------------
(* Fairness *)

GuardedFairness == WF_vars(GuardedNext)
UnguardedFairness == WF_vars(UnguardedNext)

--------------------------------------------------------------------------
(* Temporal properties *)

(* Every pending transaction eventually reaches a terminal state. *)
EventuallyTerminal ==
    [](state \in PendingStates => <>(state \in TerminalStates))

(* Once terminal (under guarded spec), stays terminal until user retries.
   The absorbing property is model-checked directly as the TerminalIsTerminal
   state invariant (prevState terminal => state unchanged). *)

--------------------------------------------------------------------------
(* Specifications *)

GuardedSpec ==
    Init /\ [][GuardedNext]_vars /\ GuardedFairness

UnguardedSpec ==
    Init /\ [][UnguardedNext]_vars /\ UnguardedFairness

\* Default spec uses guarded transitions (the intended protocol)
Spec == GuardedSpec

==========================================================================
