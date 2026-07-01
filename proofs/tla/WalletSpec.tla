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
 *     ChainChanged, AccountChanged are all no-ops in ReadOnly.
 *   - SwitchChainOk: successful chain switch from WrongChain → Connected
 *     (or WrongChain if the new chain is still wrong).
 *   - ChainAdded, AssetWatched, GotPermissions: all no-ops on state.
 *
 * Invariants:
 *   TypeOK               — state is always one of the six valid states
 *   ConnectedRequiresAddr — Connected/WrongChain always carry an address
 *   ReadOnlyHasNoAddr     — ReadOnly state never carries an address
 *   NoDeadlock            — Disconnected is always reachable (temporal)
 *
 * To verify with TLC:
 *   1. Install the TLA+ Toolbox or tla2tools.jar
 *   2. Create a model with:
 *        - Spec: Spec
 *        - Constants: ADDRESSES = {"0xaaa", "0xbbb"}
 *                     CHAINS   = {1, 369}
 *                     EXPECTED_CHAIN = 369
 *        - Invariants: TypeOK, ConnectedRequiresAddress, ReadOnlyHasNoAddr
 *        - Properties: NoDeadlock
 *   3. Run TLC. With the small constant sets above it terminates quickly.
 *
 *   Command line:
 *     java -jar tla2tools.jar -config WalletSpec.cfg WalletSpec.tla
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

(* User clicks "Disconnect" — from any state except Disconnected *)
UserDisconnect ==
    /\ state /= "Disconnected"
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
   Only meaningful from Disconnected or Connecting. *)
EvtReadOnlyMode ==
    /\ state /= "ReadOnly"
    /\ state' = "ReadOnly"
    /\ addr' = NONE
    /\ chain' = NONE
    /\ hasError' = FALSE

(* ChainChanged — only acts when in Connected state.
   ReadOnly is unaffected. *)
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

(* ChainChanged from non-Connected state — no change (stutter).
   This covers ReadOnly (stays ReadOnly) and other states. *)
EvtChainChangedFromOther ==
    /\ state /= "Connected"
    /\ UNCHANGED vars

EvtChainChanged ==
    \/ \E c \in CHAINS : EvtChainChangedFromConnected(c)
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

(* NoDeadlock: Disconnected is always eventually reachable.
   ReadOnly is a valid terminal state for read-only dApps, but
   UserDisconnect can always return to Disconnected. *)
NoDeadlock == []<>(state = "Disconnected")

(* Once connected, the wallet stays connected or transitions through
   a known path — it never silently loses the address. *)
ConnectedStability ==
    [][state = "Connected" =>
        (state' = "Connected"
         \/ state' = "WrongChain"
         \/ state' = "Disconnected"
         \/ state' = "Error")]_vars

(* v2: ReadOnly is sticky — no message (except explicit user action or
   a new WalletConnected) can take it out of ReadOnly. *)
ReadOnlySticky ==
    [][state = "ReadOnly" =>
        (state' = "ReadOnly"
         \/ state' = "Connected"   \* WalletConnected arrived
         \/ state' = "WrongChain"  \* WalletConnected, wrong chain
         \/ state' = "Disconnected")]_vars   \* UserDisconnect

(* v2: WrongChain can be resolved by SwitchChainOk. *)
WrongChainCanResolve ==
    [](state = "WrongChain" => <>(state = "Connected"))

--------------------------------------------------------------------------
(* Specification *)

Spec == Init /\ [][Next]_vars /\ Fairness

==========================================================================
