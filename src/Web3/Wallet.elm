module Web3.Wallet exposing
    ( State(..)
    , Msg(..)
    , WalletCmd(..)
    , WalletProvider
    , ChainConfig
    , update
    , startConnect
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

1. User clicks "Connect" → call `startConnect` on state, send `connect` via port.
2. `WalletsDiscovered providers` arrives → show picker if `providers` is non-empty.
3. User picks a wallet → send `selectWallet rdns` via port.
4. `WalletConnected addr chainId` arrives → `update` transitions to `Connected` or `WrongChain`.
5. If `WrongChain` → send `switchChain expectedChain` via port.

For native balance queries, use `Web3.Balance`. For adding chains, use `addChain` with
a `ChainConfig` record and follow up with `switchChain`.

@docs State, Msg, WalletCmd, WalletProvider, ChainConfig
@docs update, startConnect
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
    | Connecting
    | Connected ConnectedInfo
    | WrongChain ConnectedInfo T.ChainId
    | Error String


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
-}
type Msg
    = WalletConnected String Int
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
    = RequestConnect
    | RequestDisconnect
    | RequestSwitchChain Int
    | RequestSelectWallet String
    | RequestAddChain ChainConfig
    | RequestWatchAsset { address : T.Address, symbol : String, decimals : Int, image : String }
    | RequestPermissions
    | GetPermissions


{-| Update wallet state from a port message.
-}
update : T.ChainId -> Msg -> State -> State
update expectedChain msg state =
    case msg of
        WalletConnected addr chain ->
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


{-| Transition to `Connecting` state before sending the `connect` port command.

Call this when the user clicks the connect button, then send `connect` via the port:

    ( { model | wallet = Wallet.startConnect model.wallet }
    , web3Cmd (Wallet.encode Wallet.connect)
    )

Valid transitions: `Disconnected → Connecting`, `Error _ → Connecting`.
All other states are unchanged (connecting while already connected is a no-op).

-}
startConnect : State -> State
startConnect state =
    case state of
        Disconnected ->
            Connecting

        Error _ ->
            Connecting

        _ ->
            state


{-| Command to request wallet connection.
-}
connect : WalletCmd
connect =
    RequestConnect


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

    selectWallet "io.metamask"

-}
selectWallet : String -> WalletCmd
selectWallet rdns =
    RequestSelectWallet rdns


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
        RequestConnect ->
            E.object [ ( "tag", E.string "connect" ) ]

        RequestDisconnect ->
            E.object [ ( "tag", E.string "disconnect" ) ]

        RequestSwitchChain chain ->
            E.object
                [ ( "tag", E.string "switchChain" )
                , ( "chainId", E.int chain )
                ]

        RequestSelectWallet rdns ->
            E.object
                [ ( "tag", E.string "selectWallet" )
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
                        D.map2 WalletConnected
                            (D.field "address" D.string)
                            (D.field "chainId" D.int)

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

