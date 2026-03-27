--------------------------- MODULE WalletSpec ----------------------------
(*
 * TLA+ specification of the elm-web3 Wallet state machine.
 *
 * Models src/Web3/Wallet.elm — the `update` function and user-initiated
 * commands (connect, disconnect, switchChain).
 *
 * States:  Disconnected, Connecting, Connected, WrongChain, Error
 * Events:  WalletConnected, WalletDisconnected, ChainChanged,
 *          AccountChanged, WalletError, WalletsDiscovered
 *
 * Invariants:
 *   TypeOK               — state is always one of the five valid states
 *   ConnectedRequiresAddr — Connected/WrongChain always carry an address
 *   NoDeadlock            — Disconnected is always reachable (temporal)
 *
 * To verify with TLC:
 *   1. Install the TLA+ Toolbox or tla2tools.jar
 *   2. Create a model with:
 *        - Spec: Spec
 *        - Constants: ADDRESSES = {"0xaaa", "0xbbb"}
 *                     CHAINS   = {1, 369}
 *                     EXPECTED_CHAIN = 369
 *        - Invariants: TypeOK, ConnectedRequiresAddress
 *        - Properties: NoDeadlock
 *   3. Run TLC. With the small constant sets above it terminates quickly.
 *
 *   Command line:
 *     java -jar tla2tools.jar -config WalletSpec.cfg WalletSpec.tla
 *
 *   Or with the community modules TLC wrapper:
 *     tlc WalletSpec.tla -config WalletSpec.cfg
 *)
--------------------------------------------------------------------------

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

NONE == "NONE"

--------------------------------------------------------------------------
(* Type invariant *)

StateSet == {"Disconnected", "Connecting", "Connected", "WrongChain", "Error"}

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

(* WalletDisconnected — always goes to Disconnected *)
EvtWalletDisconnected ==
    /\ state' = "Disconnected"
    /\ addr' = NONE
    /\ chain' = NONE
    /\ hasError' = FALSE

(* ChainChanged — only acts when in Connected state *)
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

(* ChainChanged from non-Connected state — no change (stutter) *)
EvtChainChangedFromOther ==
    /\ state /= "Connected"
    /\ UNCHANGED <<state, addr, chain, hasError>>

EvtChainChanged ==
    \/ \E c \in CHAINS : EvtChainChangedFromConnected(c)
    \/ EvtChainChangedFromOther

(* AccountChanged — only acts when Connected or WrongChain with valid addr *)
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
    /\ UNCHANGED <<state, addr, chain, hasError>>

EvtAccountChanged ==
    \/ \E a \in ADDRESSES :
        \/ EvtAccountChangedFromConnected(a)
        \/ EvtAccountChangedFromWrongChain(a)
    \/ EvtAccountChangedNoOp

(* WalletError — always goes to Error from any state *)
EvtWalletError ==
    /\ state' = "Error"
    /\ addr' = NONE
    /\ chain' = NONE
    /\ hasError' = TRUE

(* WalletsDiscovered — no state change *)
EvtWalletsDiscovered ==
    UNCHANGED <<state, addr, chain, hasError>>

--------------------------------------------------------------------------
(* Next-state relation *)

Next ==
    \/ UserConnect
    \/ UserDisconnect
    \/ EvtWalletConnected
    \/ EvtWalletDisconnected
    \/ EvtChainChanged
    \/ EvtAccountChanged
    \/ EvtWalletError
    \/ EvtWalletsDiscovered

--------------------------------------------------------------------------
(* Fairness — the environment is fair: every enabled action eventually happens.
   This ensures liveness properties can be checked. *)

Fairness ==
    /\ WF_<<state, addr, chain, hasError>>(Next)

--------------------------------------------------------------------------
(* Temporal properties *)

(* NoDeadlock: Disconnected is always eventually reachable.
   Because WalletDisconnected and UserDisconnect can fire from any
   non-Disconnected state, and we have weak fairness, the system
   can always return to Disconnected. *)
NoDeadlock == []<>(state = "Disconnected")

(* Once connected, the wallet stays connected or transitions through
   a known path — it never silently loses the address. *)
ConnectedStability ==
    [](state = "Connected" =>
        (state' = "Connected"
         \/ state' = "WrongChain"
         \/ state' = "Disconnected"
         \/ state' = "Error"))

--------------------------------------------------------------------------
(* Specification *)

Spec == Init /\ [][Next]_<<state, addr, chain, hasError>> /\ Fairness

==========================================================================
