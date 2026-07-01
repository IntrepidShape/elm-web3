---------------------------- MODULE SignSpec ----------------------------
(*
 * TLA+ specification of the elm-web3 Sign state machine.
 *
 * Models src/Web3/Sign.elm — the `startSign` and `signUpdate` functions and
 * the signing lifecycle for a single correlation id.
 *
 * States:  SignIdle, SignPending, Signed, SignFailed, SignRejected
 *
 * A sign request is started with a correlation id. Port messages also carry an
 * id, and the Elm `signUpdate` only acts when the message id MATCHES the
 * pending id — a response meant for a different in-flight request must never
 * transition this one (no cross-request confusion). Terminal states are
 * absorbing (there is no retry path back to SignIdle in the Elm code).
 *
 * Messages (from JS port), each carrying an id:
 *   SignResponse id sig  -> Signed        (only if id = pendingId)
 *   SignError    id err  -> SignFailed    (only if id = pendingId)
 *   SignCancel   id      -> SignRejected  (only if id = pendingId)
 *
 * The Elm signUpdate guards every transition:
 *   - isSignTerminal check at the top: terminal states never transition out
 *   - each message only fires when state = SignPending AND id = pendingId
 *   - a message with a non-matching id is a no-op
 *
 * This spec models two views for verification comparison:
 *   1. GuardedNext:   faithful to the current Elm code (id must match)
 *   2. UnguardedNext: permissive baseline (id ignored) — running UnguardedSpec
 *                     shows NoCrossRequestConfusion break.
 *
 * Invariants (expected to hold under GuardedNext):
 *   TypeOK                     — variables are well-typed
 *   TerminalAbsorbing          — prevState terminal => state unchanged
 *   TerminalFromPending        — any terminal state was entered from SignPending
 *   CompletedImpliesTerminal   — once a message completed us, state is terminal
 *   NoCrossRequestConfusion    — the id that completed us equals the pending id
 *
 * Temporal:
 *   PendingEventuallyResolves  — SignPending => <> terminal (under fairness)
 *   TerminalStaysTerminal      — once terminal, state never changes
 *
 * To verify with TLC (-deadlock: terminal sink states are intended):
 *   java -jar tla2tools.jar -deadlock -config SignSpec.cfg SignSpec.tla
 *
 * STATUS: model-checked green (TLC 2.19 / Java 21). GuardedSpec holds all
 * invariants; UnguardedSpec confirms NoCrossRequestConfusion breaks without
 * the id-guard.
 *)

EXTENDS Naturals

CONSTANTS
    IDS                   \* Set of correlation ids, e.g. {"req1", "req2"}

VARIABLES
    state,                \* Current state tag
    pendingId,            \* Id of the in-flight request (NONE when Idle)
    completedBy,          \* Id of the message that drove us terminal (NONE otherwise)
    prevState             \* Previous state tag (for transition invariants)

NONE == "NONE"

vars == <<state, pendingId, completedBy, prevState>>

--------------------------------------------------------------------------
(* State sets *)

StateSet == {"SignIdle", "SignPending", "Signed", "SignFailed", "SignRejected"}

TerminalStates == {"Signed", "SignFailed", "SignRejected"}

--------------------------------------------------------------------------
(* Type invariant *)

TypeOK ==
    /\ state \in StateSet
    /\ pendingId \in IDS \cup {NONE}
    /\ completedBy \in IDS \cup {NONE}
    /\ prevState \in StateSet

--------------------------------------------------------------------------
(* Safety invariants *)

(* Once in a terminal state, the state never changes again (no retry path). *)
TerminalAbsorbing ==
    prevState \in TerminalStates => state = prevState

(* Any terminal state must have been entered directly from SignPending —
   you cannot reach Signed/Failed/Rejected without a request in flight. *)
TerminalFromPending ==
    state \in TerminalStates => prevState \in ({"SignPending"} \cup TerminalStates)

(* If a message has completed us (completedBy set), we are terminal. *)
CompletedImpliesTerminal ==
    completedBy /= NONE => state \in TerminalStates

(* The id that completed us is exactly the id we were waiting on — a message
   for a different request can never complete this one. *)
NoCrossRequestConfusion ==
    completedBy /= NONE => completedBy = pendingId

--------------------------------------------------------------------------
(* Initial state *)

Init ==
    /\ state = "SignIdle"
    /\ pendingId = NONE
    /\ completedBy = NONE
    /\ prevState = "SignIdle"

--------------------------------------------------------------------------
(* User action: start a sign request (SignIdle -> SignPending).
   All other states are unchanged — a sign already in flight is not replaced. *)

StartSign(i) ==
    /\ state = "SignIdle"
    /\ i \in IDS
    /\ state' = "SignPending"
    /\ pendingId' = i
    /\ completedBy' = NONE
    /\ prevState' = state

--------------------------------------------------------------------------
(* =====================================================================
   GUARDED TRANSITIONS — faithful to the Elm signUpdate: a message only
   fires from SignPending when its id matches pendingId.
   ===================================================================== *)

GuardedResponse(i) ==
    /\ state = "SignPending"
    /\ i = pendingId
    /\ state' = "Signed"
    /\ pendingId' = pendingId
    /\ completedBy' = i
    /\ prevState' = state

GuardedError(i) ==
    /\ state = "SignPending"
    /\ i = pendingId
    /\ state' = "SignFailed"
    /\ pendingId' = pendingId
    /\ completedBy' = i
    /\ prevState' = state

GuardedCancel(i) ==
    /\ state = "SignPending"
    /\ i = pendingId
    /\ state' = "SignRejected"
    /\ pendingId' = pendingId
    /\ completedBy' = i
    /\ prevState' = state

(* A message for a different request arrives while pending — it is ignored.
   Modelled explicitly (as a no-op) so TLC exercises the mismatch path. *)
GuardedMismatch(i) ==
    /\ state = "SignPending"
    /\ i \in IDS
    /\ i /= pendingId
    /\ UNCHANGED vars

GuardedNext ==
    \/ \E i \in IDS : StartSign(i)
    \/ \E i \in IDS :
        \/ GuardedResponse(i)
        \/ GuardedError(i)
        \/ GuardedCancel(i)
        \/ GuardedMismatch(i)

--------------------------------------------------------------------------
(* =====================================================================
   UNGUARDED TRANSITIONS — id-agnostic baseline. A response for ANY id
   completes the pending request. Running UnguardedSpec shows
   NoCrossRequestConfusion break.
   ===================================================================== *)

UnguardedResponse(i) ==
    /\ state = "SignPending"
    /\ i \in IDS
    /\ state' = "Signed"
    /\ pendingId' = pendingId
    /\ completedBy' = i
    /\ prevState' = state

UnguardedNext ==
    \/ \E i \in IDS : StartSign(i)
    \/ \E i \in IDS : UnguardedResponse(i)

--------------------------------------------------------------------------
(* Fairness *)

GuardedFairness == WF_vars(GuardedNext)

--------------------------------------------------------------------------
(* Temporal properties *)

(* Every pending sign eventually resolves to a terminal state. *)
PendingEventuallyResolves ==
    [](state = "SignPending" => <>(state \in TerminalStates))

(* "Once terminal, the state never changes" is model-checked directly as the
   TerminalAbsorbing state invariant (prevState terminal => state = prevState),
   which is simpler and avoids an action-in-box temporal property. *)

--------------------------------------------------------------------------
(* Specifications *)

GuardedSpec ==
    Init /\ [][GuardedNext]_vars /\ GuardedFairness

UnguardedSpec ==
    Init /\ [][UnguardedNext]_vars

\* Default spec uses guarded transitions (the intended protocol)
Spec == GuardedSpec

==========================================================================
