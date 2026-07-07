module Web3.Wallet exposing
    ( State(..)
    , RequestId
    , ConnectFailureReason(..)
    , Msg(..)
    , WalletCmd(..)
    , WalletProvider
    , ChainConfig
    , update
    , startConnect
    , timeoutConnect
    , isConnecting
    , connectingRequestId
    , connect
    , disconnect
    , switchChain
    , selectWallet
    , addChain
    , watchAsset
    , requestPermissions
    , getPermissions
    , isConnected
    , isReadOnly
    , getAddress
    , getChainId
    , encode
    , decoder
    )

{-| Wallet connection state machine.

The wallet is modeled as an explicit state — you can't accidentally
call a contract without a connected wallet because the compiler
won't give you an `Address` from a `Disconnected` state.

    case model.wallet of
        Connected info ->
            -- info.address : T.Address — only available here
            buy info.address amount

        WrongChain _ _ ->
            -- wallet is connected but on the wrong chain
            button [ onClick SwitchChain ] [ text "Switch chain" ]

        ReadOnly ->
            -- rpcUrl configured but no wallet; reads work, writes will fail
            viewReadOnlyBanner

        _ ->
            showConnectButton

**EIP-6963 multi-wallet discovery** — listen for `WalletsDiscovered` on the
port and present the list to the user; call `selectWallet rdns` when they pick.

**Typical connection flow:**

1. User clicks "Connect" → mint a fresh `RequestId` (an incrementing counter
   you own), call `startConnect requestId` on state, send `connect requestId`
   via port. Do this unconditionally, even if already `Connecting` — a
   second click (or picking a different wallet mid-prompt) is meant to
   supersede the in-flight attempt, not be swallowed as a no-op.
2. `WalletsDiscovered providers` arrives → show picker if `providers` is non-empty.
3. User picks a wallet → mint a fresh `RequestId` the same way, send
   `selectWallet requestId rdns` via port.
4. `WalletConnected (Just requestId) addr chainId` arrives → `update` checks
   the id against the active `Connecting` request (dropping it silently if a
   newer attempt has since superseded it) and transitions to `Connected` or
   `WrongChain`.
5. If `WalletConnectRejected`/`WalletConnectFailed` arrives instead, `update`
   returns to `Disconnected`/`Error` respectively (again only if the id still
   matches). Arm a timeout (e.g. 30s via `Process.sleep`) when entering
   `Connecting`; on fire, call `timeoutConnect requestId` — a no-op if the
   request already resolved.
6. If `WrongChain` → send `switchChain expectedChain` via port.

For native balance queries, use `Web3.Balance`. For adding chains, use `addChain` with
a `ChainConfig` record and follow up with `switchChain`.

@docs State, RequestId, ConnectFailureReason, Msg, WalletCmd, WalletProvider, ChainConfig
@docs update, startConnect, timeoutConnect, isConnecting, connectingRequestId
@docs connect, disconnect, switchChain, selectWallet, addChain
@docs watchAsset, requestPermissions, getPermissions
@docs isConnected, isReadOnly, getAddress, getChainId
@docs encode, decoder

-}

import Json.Decode as D
import Json.Encode as E
import Web3.Types as T


{-| Wallet connection state. Every possible state is explicit.

  - `Disconnected` — no wallet detected, no rpcUrl configured
  - `ReadOnly` — rpcUrl is present but no wallet; reads work, writes will fail
  - `Connecting` — wallet connection in progress
  - `Connected` — wallet connected on the expected chain
  - `WrongChain` — wallet connected but on the wrong chain
  - `Error` — unrecoverable error

-}
type State
    = Disconnected
    | ReadOnly
    | Connecting RequestId
    | Connected ConnectedInfo
    | WrongChain ConnectedInfo T.ChainId
    | Error String


{-| Identifies a single connect attempt so a stale response or timeout from a
superseded attempt (e.g. the user clicked Connect, gave up, and clicked again)
can never clobber a newer one. Callers own the counter (increment on every
`startConnect` call) — this module only compares ids, it never generates them.
-}
type alias RequestId =
    Int


{-| Why a connect attempt failed to resolve into `Connected`/`WrongChain`.
Does not cover explicit rejection ([`WalletConnectRejected`](#Msg)) or a
request that's still pending elsewhere ([`WalletConnectPending`](#Msg)) —
those are distinct, expected outcomes, not failures.
-}
type ConnectFailureReason
    = NotFound
    | NoAccounts
    | NetworkError


type alias ConnectedInfo =
    { address : T.Address
    , chainId : T.ChainId
    }


{-| A wallet provider discovered via EIP-6963.
-}
type alias WalletProvider =
    { name : String
    , icon : String
    , rdns : String
    }


{-| Configuration for adding a new chain to the wallet (EIP-3085).
-}
type alias ChainConfig =
    { chainId : Int
    , chainName : String
    , rpcUrls : List String
    , nativeCurrency : { name : String, symbol : String, decimals : Int }
    , blockExplorerUrls : List String
    }


{-| Messages from the JS wallet port.

`WalletConnected`'s `Maybe RequestId` is `Nothing` only for a silent,
non-prompting reconnect on page load (no request was ever "in flight" to
match against); every user-initiated connect carries `Just` the id passed to
`connect`/`selectWallet`.
-}
type Msg
    = WalletConnected (Maybe RequestId) String Int
    | WalletConnectRejected RequestId
    | WalletConnectPending RequestId
    | WalletConnectFailed RequestId ConnectFailureReason String
    | WalletDisconnected
    | ChainChanged Int
    | AccountChanged String
    | WalletError String
    | WalletsDiscovered (List WalletProvider)
    | ReadOnlyMode
    | ChainAdded
    | SwitchChainOk Int
    | AssetWatched
    | GotPermissions (List String)


{-| Commands to send to JS via port.
-}
type WalletCmd
    = RequestConnect RequestId
    | RequestDisconnect
    | RequestSwitchChain Int
    | RequestSelectWallet RequestId String
    | RequestAddChain ChainConfig
    | RequestWatchAsset { address : T.Address, symbol : String, decimals : Int, image : String }
    | RequestPermissions
    | GetPermissions


{-| Update wallet state from a port message.
-}
update : T.ChainId -> Msg -> State -> State
update expectedChain msg state =
    case msg of
        WalletConnected maybeRid addr chain ->
            let
                -- A response only gets dropped as stale if we're actively
                -- Connecting on a DIFFERENT, newer request. Every other case
                -- (silent reconnect with no id, or the state has already
                -- moved on) is accepted — a late-arriving success is still
                -- good news, never a reason to leave the user stuck.
                isStale =
                    case ( state, maybeRid ) of
                        ( Connecting activeId, Just rid ) ->
                            rid /= activeId

                        _ ->
                            False
            in
            if isStale then
                state

            else
                case T.address addr of
                    Just a ->
                        let
                            info =
                                { address = a, chainId = T.chainId chain }
                        in
                        if chain == T.chainIdToInt expectedChain then
                            Connected info

                        else
                            WrongChain info expectedChain

                    Nothing ->
                        Error ("Invalid address: " ++ addr)

        WalletConnectRejected rid ->
            case state of
                Connecting activeId ->
                    if rid == activeId then
                        Disconnected

                    else
                        -- Stale rejection from a superseded attempt.
                        state

                _ ->
                    state

        WalletConnectPending _ ->
            -- MetaMask -32002 "already processing eth_requestAccounts" —
            -- purely informational (the app should surface a toast telling
            -- the user to check their wallet); the FSM itself has nothing to
            -- transition, since we're already correctly sitting in
            -- Connecting from the original attempt.
            state

        WalletConnectFailed rid _ errorMessage ->
            case state of
                Connecting activeId ->
                    if rid == activeId then
                        Error errorMessage

                    else
                        state

                _ ->
                    state

        WalletDisconnected ->
            case state of
                ReadOnly ->
                    ReadOnly

                Error _ ->
                    -- explicit recovery: Error state exits via disconnect
                    Disconnected

                _ ->
                    Disconnected

        ChainChanged chain ->
            case state of
                ReadOnly ->
                    ReadOnly

                Connected info ->
                    let
                        newInfo =
                            { info | chainId = T.chainId chain }
                    in
                    if chain == T.chainIdToInt expectedChain then
                        Connected newInfo

                    else
                        WrongChain newInfo expectedChain

                WrongChain info _ ->
                    -- The user switched chains in the wallet UI itself (no
                    -- app-initiated switchChain round-trip). If they landed on
                    -- the expected chain, recover to Connected — otherwise
                    -- we'd stay stuck in WrongChain with the wallet already
                    -- on the right chain.
                    let
                        newInfo =
                            { info | chainId = T.chainId chain }
                    in
                    if chain == T.chainIdToInt expectedChain then
                        Connected newInfo

                    else
                        WrongChain newInfo expectedChain

                _ ->
                    state

        AccountChanged addr ->
            case state of
                ReadOnly ->
                    ReadOnly

                _ ->
                    case ( state, T.address addr ) of
                        ( Connected info, Just a ) ->
                            Connected { info | address = a }

                        ( WrongChain info chain, Just a ) ->
                            WrongChain { info | address = a } chain

                        _ ->
                            state

        WalletError err ->
            case state of
                ReadOnly ->
                    ReadOnly

                _ ->
                    Error err

        WalletsDiscovered _ ->
            state

        ReadOnlyMode ->
            -- "rpcUrl configured but no wallet injected" — only meaningful
            -- when there is no live wallet session. A stray readOnly event
            -- must not tear down Connected/WrongChain.
            case state of
                Connected _ ->
                    state

                WrongChain _ _ ->
                    state

                _ ->
                    ReadOnly

        ChainAdded ->
            -- The chain has been added to the wallet but the active chain has not changed.
            -- Send `switchChain` next to activate it.
            state

        SwitchChainOk chain ->
            case state of
                WrongChain info _ ->
                    if chain == T.chainIdToInt expectedChain then
                        Connected info

                    else
                        -- Switched but landed on yet another wrong chain
                        WrongChain info expectedChain

                _ ->
                    state

        AssetWatched ->
            state

        GotPermissions _ ->
            state


{-| Transition to `Connecting requestId` before sending the `connect` port command.

Call this when the user clicks the connect button — mint a fresh `RequestId`
(an incrementing counter you own) — then send `connect` via the port:

    ( { model
        | wallet = Wallet.startConnect requestId model.wallet
        , nextConnectId = requestId + 1
      }
    , web3Cmd (Wallet.encode (Wallet.connect requestId))
    )

Valid transitions: `Disconnected → Connecting`, `Error _ → Connecting`, and
— deliberately — `Connecting _ → Connecting` with the NEW id. That last one
is what lets overlapping attempts work elegantly: the user can click Connect
again (or pick a different wallet mid-prompt) while one is already in
flight, and the new attempt simply supersedes the old one. No app-side
"already connecting, ignore this click" guard is needed — `update` already
drops any response tagged with a `RequestId` that no longer matches the
CURRENT `Connecting` id, so a stale response from the superseded attempt
(if it ever resolves at all) is safely a no-op. `Connected`/`WrongChain`/
`ReadOnly` remain no-ops here, same as before — there's no "already
connected, reconnect" use case this module needs to support.

-}
startConnect : RequestId -> State -> State
startConnect rid state =
    case state of
        Disconnected ->
            Connecting rid

        Error _ ->
            Connecting rid

        Connecting _ ->
            Connecting rid

        _ ->
            state


{-| Time out a `Connecting requestId` back to `Disconnected` if it's still
the active request — a no-op if the request already resolved (into
`Connected`, `WrongChain`, `Error`, or back to `Disconnected`) or has already
been superseded by a newer one. Call this from a `Process.sleep`-armed
timeout started alongside `startConnect`, mirroring this codebase's existing
tx-timeout-watchdog pattern.
-}
timeoutConnect : RequestId -> State -> State
timeoutConnect rid state =
    case state of
        Connecting activeId ->
            if rid == activeId then
                Disconnected

            else
                state

        _ ->
            state


{-| True while a connect attempt is in flight — use this to drive a
"Connecting…" spinner/disabled visual state. Not meant for gating the click
handler itself: `startConnect` deliberately allows a fresh attempt to
supersede one already in flight (see its doc comment), so the click handler
should call `startConnect` unconditionally rather than checking this first.
-}
isConnecting : State -> Bool
isConnecting state =
    case state of
        Connecting _ ->
            True

        _ ->
            False


{-| The `RequestId` of the in-flight connect attempt, if any.
-}
connectingRequestId : State -> Maybe RequestId
connectingRequestId state =
    case state of
        Connecting rid ->
            Just rid

        _ ->
            Nothing


{-| Command to request wallet connection. Pass the same `RequestId` given to
`startConnect` so the eventual response can be matched back to this attempt.
-}
connect : RequestId -> WalletCmd
connect rid =
    RequestConnect rid


{-| Command to request wallet disconnection.
-}
disconnect : WalletCmd
disconnect =
    RequestDisconnect


{-| Command to switch chain.
-}
switchChain : T.ChainId -> WalletCmd
switchChain c =
    RequestSwitchChain (T.chainIdToInt c)


{-| Command to select a specific wallet by its RDNS identifier (EIP-6963).
Pass the same `RequestId` given to `startConnect`.

    selectWallet requestId "io.metamask"

-}
selectWallet : RequestId -> String -> WalletCmd
selectWallet rid rdns =
    RequestSelectWallet rid rdns


{-| Request wallet_addEthereumChain (EIP-3085) to add a new network.

    addChain
        { chainId = 369
        , chainName = "PulseChain"
        , rpcUrls = [ "https://rpc.pulsechain.com" ]
        , nativeCurrency = { name = "Pulse", symbol = "PLS", decimals = 18 }
        , blockExplorerUrls = [ "https://scan.pulsechain.com" ]
        }

-}
addChain : ChainConfig -> WalletCmd
addChain config =
    RequestAddChain config


{-| Command to add a token to the wallet UI (EIP-747).
-}
watchAsset : { address : T.Address, symbol : String, decimals : Int, image : String } -> WalletCmd
watchAsset opts =
    RequestWatchAsset opts


{-| Command to request wallet permissions (EIP-2255).
-}
requestPermissions : WalletCmd
requestPermissions =
    RequestPermissions


{-| Command to get current wallet permissions (EIP-2255).
-}
getPermissions : WalletCmd
getPermissions =
    GetPermissions


{-| True if the wallet is in the Connected state.
-}
isConnected : State -> Bool
isConnected state =
    case state of
        Connected _ ->
            True

        _ ->
            False


{-| True if in ReadOnly mode (rpcUrl present, no wallet). Reads work; writes will fail.
-}
isReadOnly : State -> Bool
isReadOnly state =
    case state of
        ReadOnly ->
            True

        _ ->
            False


{-| Extract the connected address, if any.
-}
getAddress : State -> Maybe T.Address
getAddress state =
    case state of
        Connected info ->
            Just info.address

        _ ->
            Nothing


{-| Extract the connected chain ID, if any.
-}
getChainId : State -> Maybe T.ChainId
getChainId state =
    case state of
        Connected info ->
            Just info.chainId

        _ ->
            Nothing



-- JSON ENCODING (for port communication)


{-| Encode a WalletCmd for the JS port.
-}
encode : WalletCmd -> E.Value
encode cmd =
    case cmd of
        RequestConnect rid ->
            E.object
                [ ( "tag", E.string "connect" )
                , ( "requestId", E.int rid )
                ]

        RequestDisconnect ->
            E.object [ ( "tag", E.string "disconnect" ) ]

        RequestSwitchChain chain ->
            E.object
                [ ( "tag", E.string "switchChain" )
                , ( "chainId", E.int chain )
                ]

        RequestSelectWallet rid rdns ->
            E.object
                [ ( "tag", E.string "selectWallet" )
                , ( "requestId", E.int rid )
                , ( "rdns", E.string rdns )
                ]

        RequestAddChain config ->
            E.object
                [ ( "tag", E.string "addChain" )
                , ( "chainId", E.int config.chainId )
                , ( "chainName", E.string config.chainName )
                , ( "rpcUrls", E.list E.string config.rpcUrls )
                , ( "nativeCurrency"
                  , E.object
                        [ ( "name", E.string config.nativeCurrency.name )
                        , ( "symbol", E.string config.nativeCurrency.symbol )
                        , ( "decimals", E.int config.nativeCurrency.decimals )
                        ]
                  )
                , ( "blockExplorerUrls", E.list E.string config.blockExplorerUrls )
                ]

        RequestWatchAsset opts ->
            E.object
                [ ( "tag", E.string "watchAsset" )
                , ( "address", E.string (T.addressToString opts.address) )
                , ( "symbol", E.string opts.symbol )
                , ( "decimals", E.int opts.decimals )
                , ( "image", E.string opts.image )
                ]

        RequestPermissions ->
            E.object [ ( "tag", E.string "requestPermissions" ) ]

        GetPermissions ->
            E.object [ ( "tag", E.string "getPermissions" ) ]


{-| Decode a Msg from the JS wallet port.
-}
decoder : D.Decoder Msg
decoder =
    D.field "tag" D.string
        |> D.andThen
            (\tag ->
                case tag of
                    "connected" ->
                        D.map3 WalletConnected
                            (D.maybe (D.field "requestId" D.int))
                            (D.field "address" D.string)
                            (D.field "chainId" D.int)

                    "connectRejected" ->
                        D.map WalletConnectRejected (D.field "requestId" D.int)

                    "connectPending" ->
                        D.map WalletConnectPending (D.field "requestId" D.int)

                    "connectFailed" ->
                        D.map3 WalletConnectFailed
                            (D.field "requestId" D.int)
                            (D.field "reason" D.string |> D.andThen decodeConnectFailureReason)
                            (D.field "error" D.string)

                    "disconnected" ->
                        D.succeed WalletDisconnected

                    "chainChanged" ->
                        D.map ChainChanged (D.field "chainId" D.int)

                    "accountChanged" ->
                        D.map AccountChanged (D.field "address" D.string)

                    "failed" ->
                        D.map WalletError (D.field "error" D.string)

                    "walletsDiscovered" ->
                        D.map WalletsDiscovered
                            (D.field "wallets"
                                (D.list
                                    (D.map3 WalletProvider
                                        (D.field "name" D.string)
                                        (D.field "icon" D.string)
                                        (D.field "rdns" D.string)
                                    )
                                )
                            )

                    "readOnly" ->
                        D.succeed ReadOnlyMode

                    "chainAdded" ->
                        D.succeed ChainAdded

                    "switchChainOk" ->
                        D.map SwitchChainOk (D.field "chainId" D.int)

                    "assetWatched" ->
                        D.succeed AssetWatched

                    "permissions" ->
                        D.map GotPermissions (D.field "permissions" (D.list D.string))

                    _ ->
                        D.fail ("Unknown wallet message: " ++ tag)
            )


{-| Decode the JS-supplied `reason` string on a `connectFailed` message.
Defaults to `NetworkError` for anything unrecognized rather than failing the
whole decoder — a forwards-compatible reason string from a newer JS build
should still degrade to a generic (but real) error, not crash the app.
-}
decodeConnectFailureReason : String -> D.Decoder ConnectFailureReason
decodeConnectFailureReason reason =
    case reason of
        "not_found" ->
            D.succeed NotFound

        "no_accounts" ->
            D.succeed NoAccounts

        _ ->
            D.succeed NetworkError

