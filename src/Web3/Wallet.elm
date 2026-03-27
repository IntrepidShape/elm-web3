module Web3.Wallet exposing
    ( State(..)
    , Msg(..)
    , WalletCmd(..)
    , WalletProvider
    , update
    , connect
    , disconnect
    , switchChain
    , selectWallet
    , isConnected
    , getAddress
    , getChainId
    , encode
    , decoder
    )

{-| Wallet connection state machine.

The wallet is modeled as an explicit state — you can't accidentally
call a contract without a connected wallet because the compiler
won't give you an Address from a Disconnected state.

    case model.wallet of
        Connected info ->
            -- info.address is available here
            buy info.address amount

        _ ->
            -- can't buy, no address to use
            showConnectButton

@docs State, Msg, WalletCmd, WalletProvider
@docs update
@docs connect, disconnect, switchChain, selectWallet
@docs isConnected, getAddress, getChainId
@docs encode, decoder

-}

import Json.Decode as D
import Json.Encode as E
import Web3.Types as T


{-| Wallet connection state. Every possible state is explicit.
-}
type State
    = Disconnected
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


{-| Messages from the JS wallet port.
-}
type Msg
    = WalletConnected String Int
    | WalletDisconnected
    | ChainChanged Int
    | AccountChanged String
    | WalletError String
    | WalletsDiscovered (List WalletProvider)


{-| Commands to send to JS via port.
-}
type WalletCmd
    = RequestConnect
    | RequestDisconnect
    | RequestSwitchChain Int
    | RequestSelectWallet String


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
            Disconnected

        ChainChanged chain ->
            case state of
                Connected info ->
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
            case ( state, T.address addr ) of
                ( Connected info, Just a ) ->
                    Connected { info | address = a }

                ( WrongChain info chain, Just a ) ->
                    WrongChain { info | address = a } chain

                _ ->
                    state

        WalletError err ->
            Error err

        WalletsDiscovered _ ->
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


{-| True if the wallet is in the Connected state.
-}
isConnected : State -> Bool
isConnected state =
    case state of
        Connected _ ->
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

                    "error" ->
                        D.map WalletError (D.field "message" D.string)

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

                    _ ->
                        D.fail ("Unknown wallet message: " ++ tag)
            )
