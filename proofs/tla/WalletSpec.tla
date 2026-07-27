--------------------------- MODULE WalletSpec ----------------------------
(*
 * TLA+ specification of the elm-web3 Wallet state machine.
 *
 * Models src/Web3/Wallet.elm as of 2.0.0 -- the `update` function, the
 * `startConnect` / `timeoutConnect` transitions, and the user-initiated
 * commands (connect, disconnect, switchChain).
 *
 * States:  Disconnected, ReadOnly, Connecting RequestId, Connected,
 *          WrongChain, Error
 * Events:  WalletConnected (Maybe RequestId), WalletConnectRejected,
 *          WalletConnectPending, WalletConnectFailed, WalletDisconnected,
 *          ChainChanged, AccountChanged, WalletError, WalletsDiscovered,
 *          ReadOnlyMode, ChainAdded, SwitchChainOk, AssetWatched,
 *          GotPermissions
 *
 * v3 (this revision, 2026-07-27) -- catches the spec up with commit 625d2d1
 * (2026-07-16), which shipped in 2.0.0 and which the v2 spec did NOT model:
 *   - `Connecting` carries a `RequestId`. The caller owns a monotonically
 *     incrementing counter and mints a fresh id per attempt; this module only
 *     ever COMPARES ids (`Wallet.elm:113-120`).
 *   - Supersession: `startConnect` is enabled from `Connecting` and replaces
 *     the in-flight id with the newer one, deliberately, so a second click or
 *     a mid-prompt wallet swap supersedes rather than being swallowed
 *     (`Wallet.elm:411-424`).
 *   - Stale-response drop: a response naming a superseded `RequestId` must
 *     never be applied (`Wallet.elm:206-271`). Modeled adversarially: the JS
 *     side may deliver a response for ANY id it was ever handed, in any
 *     order, at any time, including after the attempt was superseded.
 *   - `timeoutConnect` (`Wallet.elm:434-445`): an app-armed watchdog that
 *     returns `Connecting` to `Disconnected` only if its id is still active.
 *   - Three new port messages: `connectRejected` -> Disconnected,
 *     `connectPending` -> pure no-op (informational), `connectFailed` ->
 *     Error; each gated on the id matching the ACTIVE request.
 *
 * v2 behaviour that still holds (unchanged in 2.0.0):
 *   - ReadOnly: rpcUrl present but no injected wallet. Sticky -- the only
 *     exit is a WalletConnected announcement.
 *   - SwitchChainOk resolves WrongChain; ChainChanged also recovers from
 *     WrongChain when the user switches in the wallet UI.
 *   - ReadOnlyMode is ignored while a live session exists.
 *   - ChainAdded, AssetWatched, GotPermissions are no-ops on state.
 *
 * Modeling choices (all deliberate, all listed in proofs/TLA_CONFORMANCE.md):
 *   - `chain` models `ConnectedInfo.chainId` (the chain the wallet reports),
 *     NOT the `WrongChain` second field, which is the *expected* chain and is
 *     the constant EXPECTED_CHAIN here.
 *   - Chain ids are strings (only equality is ever used) so the NONE sentinel
 *     is type-consistent for TLC.
 *   - MAX_REQUESTS bounds how many connect attempts a behaviour may start,
 *     which is what makes the id space finite. Supersession needs only two
 *     overlapping attempts; the .cfg uses three.
 *   - `lastResp` is a history variable: the (id, kind) of the port response
 *     delivered by the current step, or NO_RESP. It carries no behaviour --
 *     it exists so the stale-drop property can be stated as an action
 *     formula.
 *
 * Invariants (state):
 *   TypeOK                   -- variables are well-typed
 *   ConnectedRequiresAddress -- Connected/WrongChain always carry addr+chain
 *   DisconnectedHasNoAddress / ErrorHasNoAddress / ReadOnlyHasNoAddr /
 *   ConnectingHasNoAddress
 *   ConnectingIffActiveRequest -- `Connecting` and "an id is in flight" are
 *                                 the same condition (the id cannot leak into
 *                                 or out of any other state)
 *   ActiveRidWasIssued       -- the in-flight id was actually minted
 *   ErrorFlagMirrorsState    -- Error is the only error-carrying state
 *   WrongChainIsOffExpected  -- WrongChain always reports a non-expected chain
 * Properties (temporal/action):
 *   EventuallyAtRest         -- every wallet session eventually returns to a
 *                               resting state (Disconnected or ReadOnly),
 *                               under weak fairness on UserDisconnect
 *   ConnectedStability       -- Connected only exits to WrongChain/
 *                               Disconnected/Error (or stays Connected)
 *   ReadOnlySticky           -- ReadOnly only exits via WalletConnected
 *   StaleConnectResponseDropped   -- THE supersession safety property: while
 *                               Connecting, a response naming any id other
 *                               than the active one leaves the machine
 *                               completely unchanged
 *   ResolutionRequiresActiveRequest -- rejected/failed/timeout only ever move
 *                               the machine when they name the active
 *                               in-flight request
 *   SupersedeUsesFreshId     -- Connecting -> Connecting only ever swaps in a
 *                               STRICTLY NEWER id (the supersede rule)
 *
 * NOT claimed, and false -- see the ConnectedChainMayBeStale note below.
 *
 * To verify with TLC:
 *   java -jar tla2tools.jar -config WalletSpec.cfg WalletSpec.tla
 *   (no -deadlock needed: every state has an enabled action)
 *)

EXTENDS Naturals

CONSTANTS
    ADDRESSES,        \* Set of valid address strings, e.g. {"0xaaa", "0xbbb"}
    CHAINS,           \* Set of chain IDs, e.g. {"1", "369"}
    EXPECTED_CHAIN,   \* The chain the dApp targets, e.g. "369"
    MAX_REQUESTS      \* Bound on connect attempts per behaviour (>= 2)

VARIABLES
    state,            \* Current wallet state tag
    addr,             \* Current ConnectedInfo.address (or NONE)
    chain,            \* Current ConnectedInfo.chainId (or NONE)
    hasError,         \* TRUE when in Error state
    activeRid,        \* RequestId inside `Connecting`, else NO_RID
    nextRid,          \* Next id the caller will mint (monotone counter)
    lastResp          \* History: the port response delivered by this step

\* The machine proper. Properties about "the response was dropped" are
\* statements about THIS tuple, not about the bookkeeping variables.
fsm  == <<state, addr, chain, hasError, activeRid>>
vars == <<state, addr, chain, hasError, activeRid, nextRid, lastResp>>

NONE   == "NONE"
NO_RID == 0

RIDS == 1..MAX_REQUESTS

\* Every id the app has already handed to JS. JS may answer any of them,
\* at any time, in any order -- including ids the app has since superseded.
IssuedRids == { r \in RIDS : r < nextRid }

RESP_KINDS == {"none", "connected", "rejected", "pending", "failed", "timeout"}
NO_RESP    == [rid |-> NO_RID, kind |-> "none"]

\* Response bookkeeping. `Resp` marks this step as delivering a port response
\* for request `r`; `NoResp` marks a step that delivers none.
Resp(r, k) == lastResp' = [rid |-> r, kind |-> k]
NoResp     == lastResp' = NO_RESP

--------------------------------------------------------------------------
(* Type invariant *)

StateSet == {"Disconnected", "ReadOnly", "Connecting", "Connected", "WrongChain", "Error"}

TypeOK ==
    /\ state \in StateSet
    /\ addr \in ADDRESSES \cup {NONE}
    /\ chain \in CHAINS \cup {NONE}
    /\ hasError \in BOOLEAN
    /\ activeRid \in RIDS \cup {NO_RID}
    /\ nextRid \in 1..(MAX_REQUESTS + 1)
    /\ lastResp \in [rid : RIDS \cup {NO_RID}, kind : RESP_KINDS]

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

(* Connecting has no address either -- `Connecting RequestId` carries an id
   and nothing else. *)
ConnectingHasNoAddress ==
    (state = "Connecting") => (addr = NONE /\ chain = NONE)

(* An id is in flight exactly when the machine is Connecting. This is what
   makes "match the response against the active request" total: there is no
   state in which a response could match a dangling id. *)
ConnectingIffActiveRequest ==
    (state = "Connecting") <=> (activeRid /= NO_RID)

(* The in-flight id was actually minted by the caller's counter. *)
ActiveRidWasIssued ==
    (activeRid /= NO_RID) => (activeRid < nextRid)

(* Error is the only error-carrying state. *)
ErrorFlagMirrorsState ==
    hasError <=> (state = "Error")

(* WrongChain always reports a chain that is not the expected one. *)
WrongChainIsOffExpected ==
    (state = "WrongChain") => (chain /= EXPECTED_CHAIN)

(* HONESTY NOTE -- the dual of WrongChainIsOffExpected is FALSE and is
   deliberately not asserted:

       ConnectedChainIsExpected ==
           (state = "Connected") => (chain = EXPECTED_CHAIN)

   `Wallet.update SwitchChainOk` (Wallet.elm:366-377) rebuilds `Connected`
   from the EXISTING `ConnectedInfo` -- it never writes the new chain id into
   `info.chainId`. So immediately after a successful app-initiated switch the
   machine is `Connected` while `getChainId` still reports the pre-switch
   chain, until the wallet's `chainChanged` event lands and corrects it. TLC
   finds this in seconds (WrongChain "1" -> SwitchChainOk "369" -> Connected
   with chain = "1"). Modeled faithfully above; logged as D-W4 in
   proofs/TLA_CONFORMANCE.md. *)

--------------------------------------------------------------------------
(* Initial state *)

Init ==
    /\ state = "Disconnected"
    /\ addr = NONE
    /\ chain = NONE
    /\ hasError = FALSE
    /\ activeRid = NO_RID
    /\ nextRid = 1
    /\ lastResp = NO_RESP

--------------------------------------------------------------------------
(* User actions *)

(* User clicks "Connect": mint a fresh RequestId, then apply `startConnect`.
   Faithful to Wallet.elm:411-424 -- enabled from Disconnected, Error AND
   Connecting (the supersede case, which is the whole point of the id), and a
   no-op on state from Connected/WrongChain/ReadOnly.

   The id is minted unconditionally, including on the no-op branch: the app
   increments its counter and sends the port command before `update` is ever
   consulted, so JS really can answer an id that never became active. Keeping
   that in the model is what makes the stale-drop property meaningful. *)
UserConnect ==
    /\ nextRid <= MAX_REQUESTS
    /\ nextRid' = nextRid + 1
    /\ NoResp
    /\ IF state \in {"Disconnected", "Error", "Connecting"}
       THEN /\ state' = "Connecting"
            /\ activeRid' = nextRid
            /\ addr' = NONE
            /\ chain' = NONE
            /\ hasError' = FALSE
       ELSE UNCHANGED fsm

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
    /\ activeRid' = NO_RID
    /\ UNCHANGED nextRid
    /\ NoResp

(* The app-armed connect watchdog (`timeoutConnect`, Wallet.elm:434-445).
   Fires for some previously issued id; only the ACTIVE one resolves. *)
EvtTimeoutConnect(r) ==
    /\ r \in IssuedRids
    /\ Resp(r, "timeout")
    /\ UNCHANGED nextRid
    /\ IF state = "Connecting" /\ r = activeRid
       THEN /\ state' = "Disconnected"
            /\ addr' = NONE
            /\ chain' = NONE
            /\ hasError' = FALSE
            /\ activeRid' = NO_RID
       ELSE UNCHANGED fsm

--------------------------------------------------------------------------
(* Wallet events (from JS port via update function) *)

(* `WalletConnected (Maybe RequestId) address chainId` with a well-formed
   address. `mrid = NO_RID` models `Nothing` -- the silent page-load
   reconnect, which is deliberately never treated as stale. *)
EvtConnectedOk(mrid, a, c) ==
    /\ Resp(mrid, "connected")
    /\ UNCHANGED nextRid
    /\ IF state = "Connecting" /\ mrid /= NO_RID /\ mrid /= activeRid
       THEN UNCHANGED fsm                       \* superseded attempt: dropped
       ELSE /\ state' = IF c = EXPECTED_CHAIN THEN "Connected" ELSE "WrongChain"
            /\ addr' = a
            /\ chain' = c
            /\ hasError' = FALSE
            /\ activeRid' = NO_RID

(* Same message with a malformed address -> Error. The staleness test runs
   FIRST in the Elm code, so a superseded malformed response is dropped
   rather than diagnosed. *)
EvtConnectedBadAddr(mrid) ==
    /\ Resp(mrid, "connected")
    /\ UNCHANGED nextRid
    /\ IF state = "Connecting" /\ mrid /= NO_RID /\ mrid /= activeRid
       THEN UNCHANGED fsm
       ELSE /\ state' = "Error"
            /\ addr' = NONE
            /\ chain' = NONE
            /\ hasError' = TRUE
            /\ activeRid' = NO_RID

EvtWalletConnected ==
    \E mrid \in IssuedRids \cup {NO_RID} :
        \/ \E a \in ADDRESSES, c \in CHAINS : EvtConnectedOk(mrid, a, c)
        \/ EvtConnectedBadAddr(mrid)

(* `connectRejected` -- the user dismissed the wallet prompt (EIP-1193 4001).
   Resolves only the attempt it names (Wallet.elm:240-251). *)
EvtConnectRejected(r) ==
    /\ r \in IssuedRids
    /\ Resp(r, "rejected")
    /\ UNCHANGED nextRid
    /\ IF state = "Connecting" /\ r = activeRid
       THEN /\ state' = "Disconnected"
            /\ addr' = NONE
            /\ chain' = NONE
            /\ hasError' = FALSE
            /\ activeRid' = NO_RID
       ELSE UNCHANGED fsm

(* `connectPending` -- MetaMask -32002 "already processing
   eth_requestAccounts". Purely informational: the FSM has nothing to do
   because it is already sitting in Connecting (Wallet.elm:253-259). A no-op
   for EVERY id, matching or not. *)
EvtConnectPending(r) ==
    /\ r \in IssuedRids
    /\ Resp(r, "pending")
    /\ UNCHANGED nextRid
    /\ UNCHANGED fsm

(* `connectFailed` -- not-found / no-accounts / network. Resolves only the
   attempt it names (Wallet.elm:261-271). The ConnectFailureReason is carried
   to the app but does not affect the transition, so it is abstracted away. *)
EvtConnectFailed(r) ==
    /\ r \in IssuedRids
    /\ Resp(r, "failed")
    /\ UNCHANGED nextRid
    /\ IF state = "Connecting" /\ r = activeRid
       THEN /\ state' = "Error"
            /\ addr' = NONE
            /\ chain' = NONE
            /\ hasError' = TRUE
            /\ activeRid' = NO_RID
       ELSE UNCHANGED fsm

(* WalletDisconnected -- goes to Disconnected, EXCEPT ReadOnly, which is
   sticky (rpcUrl is still configured). *)
EvtWalletDisconnected ==
    /\ NoResp
    /\ UNCHANGED nextRid
    /\ IF state = "ReadOnly"
       THEN UNCHANGED fsm
       ELSE /\ state' = "Disconnected"
            /\ addr' = NONE
            /\ chain' = NONE
            /\ hasError' = FALSE
            /\ activeRid' = NO_RID

(* ReadOnlyMode -- rpcUrl configured but no wallet injected. The Elm update
   ignores this event when a live session exists (Connected/WrongChain): a
   stray readOnly announcement must not tear down a connected wallet. From
   Connecting it DOES resolve the attempt -- and note it is not id-tagged, so
   an in-flight attempt cannot filter a stale one (see D-W5). *)
EvtReadOnlyMode ==
    /\ NoResp
    /\ UNCHANGED nextRid
    /\ IF state \in {"Connected", "WrongChain"}
       THEN UNCHANGED fsm
       ELSE /\ state' = "ReadOnly"
            /\ addr' = NONE
            /\ chain' = NONE
            /\ hasError' = FALSE
            /\ activeRid' = NO_RID

(* ChainChanged -- acts from Connected AND WrongChain (the user can switch
   chains directly in the wallet UI; landing on the expected chain from
   WrongChain recovers to Connected). Every other state, ReadOnly and
   Connecting included, is a no-op. *)
EvtChainChanged(c) ==
    /\ c \in CHAINS
    /\ NoResp
    /\ UNCHANGED nextRid
    /\ IF state \in {"Connected", "WrongChain"}
       THEN /\ state' = IF c = EXPECTED_CHAIN THEN "Connected" ELSE "WrongChain"
            /\ chain' = c
            /\ UNCHANGED <<addr, hasError, activeRid>>
       ELSE UNCHANGED fsm

(* SwitchChainOk -- the app-initiated switch resolved. Only meaningful in
   WrongChain. NOTE the `UNCHANGED chain`: the Elm arm rebuilds `Connected`
   from the existing ConnectedInfo and does not write the new chain id. That
   is modeled, not smoothed over -- see the honesty note above. *)
EvtSwitchChainOk(c) ==
    /\ c \in CHAINS
    /\ NoResp
    /\ UNCHANGED nextRid
    /\ IF state = "WrongChain"
       THEN /\ state' = IF c = EXPECTED_CHAIN THEN "Connected" ELSE "WrongChain"
            /\ UNCHANGED <<addr, chain, hasError, activeRid>>
       ELSE UNCHANGED fsm

(* AccountChanged -- only acts when Connected or WrongChain. ReadOnly and
   every other state are unaffected. *)
EvtAccountChanged(a) ==
    /\ a \in ADDRESSES
    /\ NoResp
    /\ UNCHANGED nextRid
    /\ IF state \in {"Connected", "WrongChain"}
       THEN /\ addr' = a
            /\ UNCHANGED <<state, chain, hasError, activeRid>>
       ELSE UNCHANGED fsm

(* WalletError -- goes to Error, EXCEPT ReadOnly stays ReadOnly. This is the
   untagged failure channel (the port's `failed`), distinct from the
   id-tagged connectFailed above. *)
EvtWalletError ==
    /\ NoResp
    /\ UNCHANGED nextRid
    /\ IF state = "ReadOnly"
       THEN UNCHANGED fsm
       ELSE /\ state' = "Error"
            /\ addr' = NONE
            /\ chain' = NONE
            /\ hasError' = TRUE
            /\ activeRid' = NO_RID

(* WalletsDiscovered, ChainAdded, AssetWatched, GotPermissions -- all no-ops
   on state. *)
EvtNoOp ==
    /\ NoResp
    /\ UNCHANGED nextRid
    /\ UNCHANGED fsm

--------------------------------------------------------------------------
(* Next-state relation *)

Next ==
    \/ UserConnect
    \/ UserDisconnect
    \/ \E r \in IssuedRids : EvtTimeoutConnect(r)
    \/ EvtWalletConnected
    \/ \E r \in IssuedRids : EvtConnectRejected(r)
    \/ \E r \in IssuedRids : EvtConnectPending(r)
    \/ \E r \in IssuedRids : EvtConnectFailed(r)
    \/ EvtWalletDisconnected
    \/ EvtReadOnlyMode
    \/ \E c \in CHAINS : EvtChainChanged(c)
    \/ \E c \in CHAINS : EvtSwitchChainOk(c)
    \/ \E a \in ADDRESSES : EvtAccountChanged(a)
    \/ EvtWalletError
    \/ EvtNoOp              \* WalletsDiscovered, ChainAdded, AssetWatched, GotPermissions

--------------------------------------------------------------------------
(* Fairness *)

Fairness ==
    /\ WF_vars(Next)
    \* UserDisconnect is enabled from every non-Disconnected, non-ReadOnly
    \* state; requiring it not be starved is what makes EventuallyAtRest
    \* hold -- otherwise the wallet could churn in Connected forever.
    /\ WF_vars(UserDisconnect)

--------------------------------------------------------------------------
(* Temporal properties *)

(* HONESTY NOTE: an earlier version claimed []<>(state = "Disconnected")
   ("Disconnected always eventually reachable"), justified by "UserDisconnect
   can always return to Disconnected". That is FALSE for the real machine:
   ReadOnly has no disconnect path in the Elm code (WalletDisconnected keeps
   ReadOnly sticky), so a run resting in ReadOnly never revisits Disconnected.
   The truthful liveness claim is: every wallet SESSION eventually returns to
   a resting state -- Disconnected or ReadOnly. Holds under weak fairness on
   UserDisconnect (the user is never starved of the disconnect button). *)
SessionStates == {"Connecting", "Connected", "WrongChain", "Error"}

EventuallyAtRest ==
    [](state \in SessionStates =>
        <>(state \in {"Disconnected", "ReadOnly"}))

(* Once connected, the wallet stays connected or transitions through
   a known path -- it never silently loses the address, and in particular a
   connect attempt started while Connected (which mints an id but is a
   startConnect no-op) never drags a live session back into Connecting. *)
ConnectedStability ==
    [][state = "Connected" =>
        (state' = "Connected"
         \/ state' = "WrongChain"
         \/ state' = "Disconnected"
         \/ state' = "Error")]_vars

(* ReadOnly is sticky -- the ONLY exits are a WalletConnected announcement
   (valid address -> Connected/WrongChain; malformed address -> Error, the
   diagnostic path in Wallet.update). There is no ReadOnly -> Disconnected
   path in the Elm code, and startConnect is a no-op there. *)
ReadOnlySticky ==
    [][state = "ReadOnly" =>
        (state' = "ReadOnly"
         \/ state' = "Connected"   \* WalletConnected arrived
         \/ state' = "WrongChain"  \* WalletConnected, wrong chain
         \/ state' = "Error")]_vars \* WalletConnected, malformed address

(* THE supersession safety property, and the reason RequestId exists.

   While a connect attempt is in flight, a port response naming ANY other id
   -- an attempt the user abandoned, a duplicate the wallet answered late, a
   watchdog for a superseded attempt -- leaves the machine completely
   unchanged. Not "usually", not "for rejections": no field of the FSM moves.

   This is the property that makes `startConnect` safe to call
   unconditionally on every click, which is what the module documents. *)
StaleConnectResponseDropped ==
    [][ (state = "Connecting"
         /\ lastResp'.kind /= "none"
         /\ lastResp'.rid /= NO_RID
         /\ lastResp'.rid /= activeRid)
        => UNCHANGED fsm ]_vars

(* The converse framing, for the three resolving responses: a rejection, a
   failure or a timeout only ever moves the machine when it names the request
   that is actually in flight. Arriving in any other state (including a
   `Connected` session that a stale watchdog might otherwise tear down) is a
   no-op. *)
ResolutionRequiresActiveRequest ==
    [][ (lastResp'.kind \in {"rejected", "failed", "timeout"}
         /\ ~(state = "Connecting" /\ lastResp'.rid = activeRid))
        => UNCHANGED fsm ]_vars

(* The supersede rule itself: Connecting -> Connecting can only ever install
   a STRICTLY NEWER id. An older attempt can never reclaim the slot, which is
   what makes "newest attempt wins" a property rather than a convention. *)
SupersedeUsesFreshId ==
    [][ (state = "Connecting" /\ state' = "Connecting" /\ activeRid' /= activeRid)
        => activeRid' > activeRid ]_vars

(* WrongChain can be resolved by SwitchChainOk. *)
(* NOT CHECKED in the .cfg, deliberately: this property only holds if one
   ASSUMES the user (or wallet) eventually performs a successful switch --
   fairness on EvtSwitchChainOk / EvtChainChanged. Asserting that would encode
   "the user always eventually fixes their chain", which is not a property of
   the library. What IS guaranteed (and checked) is that recovery is
   *possible* from WrongChain via either path -- see the EvtSwitchChainOk and
   EvtChainChanged actions. *)
WrongChainCanResolve ==
    [](state = "WrongChain" => <>(state = "Connected"))

--------------------------------------------------------------------------
(* Specification *)

Spec == Init /\ [][Next]_vars /\ Fairness

==========================================================================
