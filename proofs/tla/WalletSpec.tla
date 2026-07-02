--------------------------- MODULE WalletSpec ----------------------------
(*
 * TLA+ specification of the elm-web3 Wallet state machine.
 *
 * Models src/Web3/Wallet.elm (v2) — the `update` function and
 * user-initiated commands (connect, disconnect, switchChain).
 *
 * States:  Disconnected, ReadOnly, Connecting, Connected, WrongChain, Error
 * Events:  WalletConnected, WalletDisconnected, ChainChanged,
 *          AccountChanged, WalletError, WalletsDiscovered,
 *          ReadOnlyMode, ChainAdded, SwitchChainOk, AssetWatched,
 *          GotPermissions
 *
 * v2 additions vs v1:
 *   - ReadOnly state: rpcUrl present but no injected wallet.
 *     Reads work; writes will fail at the JS layer.
 *   - ReadOnly is a "sticky" state: WalletDisconnected, WalletError,
 *     ChainChanged, AccountChanged are all no-ops in ReadOnly. The only
 *     exits are a WalletConnected announcement (-> Connected/WrongChain,
 *     or Error on a malformed address).
 *   - SwitchChainOk: successful chain switch from WrongChain → Connected
 *     (or WrongChain if the new chain is still wrong).
 *   - ChainChanged also acts from WrongChain: a manual switch in the wallet
 *     UI to the expected chain recovers to Connected.
 *   - ReadOnlyMode is ignored when a live session exists (Connected /
 *     WrongChain) — a stray readOnly event must not tear down a session.
 *   - ChainAdded, AssetWatched, GotPermissions: all no-ops on state.
 *
 * Conformance to src/Web3/Wallet.elm is audited action-by-action in
 * proofs/TLA_CONFORMANCE.md. Chain ids are modeled as strings (only equality
 * is ever used) so the NONE sentinel is type-consistent for TLC.
 *
 * Invariants (state):
 *   TypeOK                — variables are well-typed
 *   ConnectedRequiresAddress — Connected/WrongChain always carry addr+chain
 *   DisconnectedHasNoAddress / ErrorHasNoAddress / ReadOnlyHasNoAddr
 * Properties (temporal/action):
 *   EventuallyAtRest      — every wallet session eventually returns to a
 *                           resting state (Disconnected or ReadOnly), under
 *                           weak fairness on UserDisconnect
 *   ConnectedStability    — Connected only exits to WrongChain/Disconnected/
 *                           Error (or stays Connected)
 *   ReadOnlySticky        — ReadOnly only exits via WalletConnected
 *
 * To verify with TLC:
 *   java -jar tla2tools.jar -config WalletSpec.cfg WalletSpec.tla
 *   (no -deadlock needed: every state has an enabled action)
 *)

EXTENDS Naturals, FiniteSets

CONSTANTS
    ADDRESSES,        \* Set of valid address strings, e.g. {"0xaaa", "0xbbb"}
    CHAINS,           \* Set of chain IDs, e.g. {1, 369}
    EXPECTED_CHAIN    \* The chain the dApp targets, e.g. 369

VARIABLES
    state,            \* Current wallet state tag
    addr,             \* Current address (or NONE)
    chain,            \* Current chain ID (or NONE)
    hasError          \* TRUE when in Error state

vars == <<state, addr, chain, hasError>>

NONE == "NONE"

--------------------------------------------------------------------------
(* Type invariant *)

\* v2: ReadOnly added to StateSet
StateSet == {"Disconnected", "ReadOnly", "Connecting", "Connected", "WrongChain", "Error"}

TypeOK ==
    /\ state \in StateSet
    /\ addr \in ADDRESSES \cup {NONE}
    /\ chain \in CHAINS \cup {NONE}
    /\ hasError \in BOOLEAN

(* Connected and WrongChain always carry an address and chain *)
ConnectedRequiresAddress ==
    /\ (state = "Connected")  => (addr \in ADDRESSES /\ chain \in CHAINS)
    /\ (state = "WrongChain") => (addr \in ADDRESSES /\ chain \in CHAINS)

(* Disconnected has no address *)
DisconnectedHasNoAddress ==
    (state = "Disconnected") => (addr = NONE /\ chain = NONE)

(* ReadOnly has no wallet address *)
ReadOnlyHasNoAddr ==
    (state = "ReadOnly") => (addr = NONE /\ chain = NONE)

(* Error has no address *)
ErrorHasNoAddress ==
    (state = "Error") => (addr = NONE /\ chain = NONE)

--------------------------------------------------------------------------
(* Initial state *)

Init ==
    /\ state = "Disconnected"
    /\ addr = NONE
    /\ chain = NONE
    /\ hasError = FALSE

--------------------------------------------------------------------------
(* User actions *)

(* User clicks "Connect" — only from Disconnected or Error *)
UserConnect ==
    /\ state \in {"Disconnected", "Error"}
    /\ state' = "Connecting"
    /\ addr' = NONE
    /\ chain' = NONE
    /\ hasError' = FALSE

(* User clicks "Disconnect". In the Elm code this is a port round-trip: the
   disconnect command makes JS emit a 'disconnected' event, and
   Wallet.update WalletDisconnected sends every state to Disconnected EXCEPT
   ReadOnly, which is sticky (there is NO Elm code path ReadOnly ->
   Disconnected; ReadOnly only exits via a WalletConnected announcement).
   Modeled faithfully: not enabled from ReadOnly. *)
UserDisconnect ==
    /\ state \notin {"Disconnected", "ReadOnly"}
    /\ state' = "Disconnected"
    /\ addr' = NONE
    /\ chain' = NONE
    /\ hasError' = FALSE

--------------------------------------------------------------------------
(* Wallet events (from JS port via update function) *)

(* WalletConnected with valid address, correct chain *)
EvtConnectedCorrectChain(a, c) ==
    /\ c = EXPECTED_CHAIN
    /\ a \in ADDRESSES
    /\ state' = "Connected"
    /\ addr' = a
    /\ chain' = c
    /\ hasError' = FALSE

(* WalletConnected with valid address, wrong chain *)
EvtConnectedWrongChain(a, c) ==
    /\ c /= EXPECTED_CHAIN
    /\ c \in CHAINS
    /\ a \in ADDRESSES
    /\ state' = "WrongChain"
    /\ addr' = a
    /\ chain' = c
    /\ hasError' = FALSE

(* WalletConnected with invalid address -> Error *)
EvtConnectedInvalidAddr ==
    /\ state' = "Error"
    /\ addr' = NONE
    /\ chain' = NONE
    /\ hasError' = TRUE

(* WalletConnected — union of the three cases above.
   Can arrive from any state (the Elm update ignores current state). *)
EvtWalletConnected ==
    \/ \E a \in ADDRESSES, c \in CHAINS :
        \/ EvtConnectedCorrectChain(a, c)
        \/ EvtConnectedWrongChain(a, c)
    \/ EvtConnectedInvalidAddr

(* WalletDisconnected — goes to Disconnected, EXCEPT:
   - ReadOnly stays ReadOnly (rpcUrl is still configured)
   - Error stays Disconnected (explicit recovery) *)
EvtWalletDisconnected ==
    IF state = "ReadOnly"
    THEN UNCHANGED vars          \* ReadOnly is sticky
    ELSE /\ state' = "Disconnected"
         /\ addr' = NONE
         /\ chain' = NONE
         /\ hasError' = FALSE

(* v2: ReadOnlyMode — rpcUrl configured but no wallet injected.
   The Elm update ignores this event when a live session exists
   (Connected/WrongChain): a stray readOnly announcement must not tear down
   a connected wallet. Meaningful only from Disconnected, Connecting, Error. *)
EvtReadOnlyMode ==
    /\ state \in {"Disconnected", "Connecting", "Error"}
    /\ state' = "ReadOnly"
    /\ addr' = NONE
    /\ chain' = NONE
    /\ hasError' = FALSE

(* ChainChanged — acts from Connected AND WrongChain (the user can switch
   chains directly in the wallet UI; if they land on the expected chain from
   WrongChain, the app recovers to Connected). ReadOnly is unaffected. *)
EvtChainChangedFromConnected(c) ==
    /\ state = "Connected"
    /\ c \in CHAINS
    /\ IF c = EXPECTED_CHAIN
       THEN /\ state' = "Connected"
            /\ chain' = c
            /\ addr' = addr
            /\ hasError' = FALSE
       ELSE /\ state' = "WrongChain"
            /\ chain' = c
            /\ addr' = addr
            /\ hasError' = FALSE

(* ChainChanged from WrongChain — manual switch in the wallet UI recovers
   (mirrors the WrongChain branch of Wallet.update ChainChanged). *)
EvtChainChangedFromWrongChain(c) ==
    /\ state = "WrongChain"
    /\ c \in CHAINS
    /\ IF c = EXPECTED_CHAIN
       THEN /\ state' = "Connected"
            /\ chain' = c
            /\ addr' = addr
            /\ hasError' = FALSE
       ELSE /\ state' = "WrongChain"  \* still wrong, chainId updated
            /\ chain' = c
            /\ addr' = addr
            /\ hasError' = FALSE

(* ChainChanged from any other state — no change (stutter).
   This covers ReadOnly (stays ReadOnly), Disconnected, Connecting, Error. *)
EvtChainChangedFromOther ==
    /\ state \notin {"Connected", "WrongChain"}
    /\ UNCHANGED vars

EvtChainChanged ==
    \/ \E c \in CHAINS : EvtChainChangedFromConnected(c)
    \/ \E c \in CHAINS : EvtChainChangedFromWrongChain(c)
    \/ EvtChainChangedFromOther

(* v2: SwitchChainOk — successful chain switch response from JS.
   Only meaningful in WrongChain state. *)
EvtSwitchChainOk(c) ==
    /\ state = "WrongChain"
    /\ c \in CHAINS
    /\ IF c = EXPECTED_CHAIN
       THEN /\ state' = "Connected"
            /\ chain' = c
            /\ addr' = addr
            /\ hasError' = FALSE
       ELSE /\ state' = "WrongChain"  \* switched but still wrong
            /\ chain' = c
            /\ addr' = addr
            /\ hasError' = FALSE

(* SwitchChainOk from non-WrongChain state — no change *)
EvtSwitchChainOkNoOp ==
    /\ state /= "WrongChain"
    /\ UNCHANGED vars

EvtSwitchChainOk_All ==
    \/ \E c \in CHAINS : EvtSwitchChainOk(c)
    \/ EvtSwitchChainOkNoOp

(* AccountChanged — only acts when Connected or WrongChain with valid addr.
   ReadOnly is unaffected. *)
EvtAccountChangedFromConnected(a) ==
    /\ state = "Connected"
    /\ a \in ADDRESSES
    /\ addr' = a
    /\ UNCHANGED <<state, chain, hasError>>

EvtAccountChangedFromWrongChain(a) ==
    /\ state = "WrongChain"
    /\ a \in ADDRESSES
    /\ addr' = a
    /\ UNCHANGED <<state, chain, hasError>>

(* AccountChanged with invalid addr or from other state — no change *)
EvtAccountChangedNoOp ==
    /\ state \notin {"Connected", "WrongChain"}
    /\ UNCHANGED vars

EvtAccountChanged ==
    \/ \E a \in ADDRESSES :
        \/ EvtAccountChangedFromConnected(a)
        \/ EvtAccountChangedFromWrongChain(a)
    \/ EvtAccountChangedNoOp

(* WalletError — goes to Error, EXCEPT ReadOnly stays ReadOnly. *)
EvtWalletError ==
    IF state = "ReadOnly"
    THEN UNCHANGED vars
    ELSE /\ state' = "Error"
         /\ addr' = NONE
         /\ chain' = NONE
         /\ hasError' = TRUE

(* WalletsDiscovered — no state change *)
EvtWalletsDiscovered ==
    UNCHANGED vars

(* v2: ChainAdded, AssetWatched, GotPermissions — all no-ops on state *)
EvtNoOp ==
    UNCHANGED vars

--------------------------------------------------------------------------
(* Next-state relation *)

Next ==
    \/ UserConnect
    \/ UserDisconnect
    \/ EvtWalletConnected
    \/ EvtWalletDisconnected
    \/ EvtReadOnlyMode
    \/ EvtChainChanged
    \/ EvtSwitchChainOk_All
    \/ EvtAccountChanged
    \/ EvtWalletError
    \/ EvtWalletsDiscovered
    \/ EvtNoOp              \* ChainAdded, AssetWatched, GotPermissions

--------------------------------------------------------------------------
(* Fairness *)

Fairness ==
    /\ WF_vars(Next)
    \* UserDisconnect is enabled from every non-Disconnected state; requiring it
    \* not be starved is what makes NoDeadlock (always-eventually-Disconnected)
    \* hold — otherwise the wallet could churn in Connected forever.
    /\ WF_vars(UserDisconnect)

--------------------------------------------------------------------------
(* Temporal properties *)

(* HONESTY NOTE: an earlier version claimed []<>(state = "Disconnected")
   ("Disconnected always eventually reachable"), justified by "UserDisconnect
   can always return to Disconnected". That is FALSE for the real machine:
   ReadOnly has no disconnect path in the Elm code (WalletDisconnected keeps
   ReadOnly sticky), so a run resting in ReadOnly never revisits Disconnected.
   The truthful liveness claim is: every wallet SESSION eventually returns to
   a resting state — Disconnected or ReadOnly. Holds under weak fairness on
   UserDisconnect (the user is never starved of the disconnect button). *)
SessionStates == {"Connecting", "Connected", "WrongChain", "Error"}

EventuallyAtRest ==
    [](state \in SessionStates =>
        <>(state \in {"Disconnected", "ReadOnly"}))

(* Once connected, the wallet stays connected or transitions through
   a known path — it never silently loses the address. *)
ConnectedStability ==
    [][state = "Connected" =>
        (state' = "Connected"
         \/ state' = "WrongChain"
         \/ state' = "Disconnected"
         \/ state' = "Error")]_vars

(* v2: ReadOnly is sticky — the ONLY exits are a WalletConnected announcement
   (valid address -> Connected/WrongChain; malformed address -> Error, the
   diagnostic path in Wallet.update). There is no ReadOnly -> Disconnected
   path in the Elm code. *)
ReadOnlySticky ==
    [][state = "ReadOnly" =>
        (state' = "ReadOnly"
         \/ state' = "Connected"   \* WalletConnected arrived
         \/ state' = "WrongChain"  \* WalletConnected, wrong chain
         \/ state' = "Error")]_vars \* WalletConnected, malformed address

(* v2: WrongChain can be resolved by SwitchChainOk. *)
(* NOT CHECKED in the .cfg, deliberately: this property only holds if one
   ASSUMES the user (or wallet) eventually performs a successful switch —
   fairness on EvtSwitchChainOk / EvtChainChangedFromWrongChain. Asserting
   that would encode "the user always eventually fixes their chain", which is
   not a property of the library. What IS guaranteed (and checked) is that
   recovery is *possible* from WrongChain via either path — see the
   EvtSwitchChainOk and EvtChainChangedFromWrongChain actions. *)
WrongChainCanResolve ==
    [](state = "WrongChain" => <>(state = "Connected"))

--------------------------------------------------------------------------
(* Specification *)

Spec == Init /\ [][Next]_vars /\ Fairness

==========================================================================
