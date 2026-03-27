port module Main exposing (main)

{-| Basic elm-web3 integration example.

Shows:
  - Wallet connection state machine
  - Reading an ERC-20 token balance (eth_call)
  - Sending a transfer (eth_sendTransaction)
  - Full transaction lifecycle display

Wire up in index.html with elm-web3-ports.js.

-}

import Web3.BigInt as BigInt
import Browser
import Html exposing (Html, button, div, h1, h2, input, label, p, text)
import Html.Attributes exposing (disabled, placeholder, style, value)
import Html.Events exposing (onClick, onInput)
import Json.Decode as D
import Json.Encode as E
import Web3.Abi.Encode as AbiEncode
import Web3.Contract.Call as Call
import Web3.Contract.Send as Send
import Web3.Transaction as Tx
import Web3.Types as T
import Web3.Wallet as Wallet


-- PORTS


port web3Cmd : E.Value -> Cmd msg


port web3Sub : (D.Value -> msg) -> Sub msg


-- CONFIG
-- Change this to match the network your wallet is on.


expectedChain : T.ChainId
expectedChain =
    T.chainId 1



-- MODEL


type BalanceState
    = BalanceIdle
    | BalanceLoading
    | BalanceLoaded String
    | BalanceError String


type alias Model =
    { wallet : Wallet.State
    , tokenAddress : String
    , balance : BalanceState
    , recipient : String
    , amount : String
    , transferTx : Tx.Status
    }


init : () -> ( Model, Cmd Msg )
init _ =
    ( { wallet = Wallet.Disconnected
      , tokenAddress = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
      , balance = BalanceIdle
      , recipient = ""
      , amount = ""
      , transferTx = Tx.Idle
      }
    , Cmd.none
    )



-- MSG


type Msg
    = ConnectWallet
    | DisconnectWallet
    | TokenAddressChanged String
    | ReadBalance
    | RecipientChanged String
    | AmountChanged String
    | SendTransfer
    | Web3Response D.Value



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        ConnectWallet ->
            ( { model | wallet = Wallet.Connecting }
            , web3Cmd (Wallet.encode Wallet.connect)
            )

        DisconnectWallet ->
            ( { model | wallet = Wallet.Disconnected }
            , web3Cmd (Wallet.encode Wallet.disconnect)
            )

        TokenAddressChanged s ->
            ( { model | tokenAddress = s, balance = BalanceIdle }, Cmd.none )

        ReadBalance ->
            case ( Wallet.getAddress model.wallet, T.address model.tokenAddress ) of
                ( Just userAddr, Just contractAddr ) ->
                    let
                        call =
                            Call.readCall
                                { contract = contractAddr
                                , method = "balanceOf(address)"
                                , args = [ AbiEncode.address userAddr ]
                                , decoder = D.string
                                , id = "balance"
                                }
                    in
                    ( { model | balance = BalanceLoading }
                    , web3Cmd (Call.encode call)
                    )

                _ ->
                    ( { model | balance = BalanceError "Connect wallet and enter a valid token address first" }
                    , Cmd.none
                    )

        RecipientChanged s ->
            ( { model | recipient = s }, Cmd.none )

        AmountChanged s ->
            ( { model | amount = s }, Cmd.none )

        SendTransfer ->
            case ( T.address model.tokenAddress, T.address model.recipient ) of
                ( Just contractAddr, Just recipientAddr ) ->
                    case ( Wallet.getAddress model.wallet, BigInt.fromString model.amount ) of
                        ( Just _, Just amountBig ) ->
                            let
                                call =
                                    Send.writeCall
                                        { contract = contractAddr
                                        , method = "transfer(address,uint256)"
                                        , args =
                                            [ AbiEncode.address recipientAddr
                                            , AbiEncode.uint256 amountBig
                                            ]
                                        }
                            in
                            ( { model | transferTx = Tx.AwaitingSignature }
                            , web3Cmd (Send.encode call)
                            )

                        _ ->
                            ( { model | transferTx = Tx.Failed "Connect wallet and enter a valid decimal amount" }
                            , Cmd.none
                            )

                _ ->
                    ( { model | transferTx = Tx.Failed "Enter valid token and recipient addresses (0x...)" }
                    , Cmd.none
                    )

        Web3Response value ->
            handleWeb3Response value model


handleWeb3Response : D.Value -> Model -> ( Model, Cmd Msg )
handleWeb3Response value model =
    let
        tag =
            D.decodeValue (D.field "tag" D.string) value
                |> Result.withDefault ""
    in
    case tag of
        -- Wallet messages
        "connected" ->
            routeWalletMsg value model

        "disconnected" ->
            ( { model | wallet = Wallet.Disconnected }, Cmd.none )

        "chainChanged" ->
            routeWalletMsg value model

        "accountChanged" ->
            routeWalletMsg value model

        "error" ->
            routeWalletMsg value model

        -- Call result
        "callResult" ->
            let
                rawData =
                    D.decodeValue (D.field "data" D.string) value
                        |> Result.withDefault "0x"
            in
            ( { model | balance = BalanceLoaded rawData }, Cmd.none )

        -- Transaction lifecycle
        "submitted" ->
            routeTxMsg value model

        "confirmation" ->
            routeTxMsg value model

        "confirmed" ->
            routeTxMsg value model

        "failed" ->
            routeTxMsg value model

        "rejected" ->
            -- rejected can come from wallet connect or tx signing.
            -- Route to tx if one is pending, otherwise treat as wallet rejection.
            if Tx.isPending model.transferTx then
                routeTxMsg value model

            else
                ( { model | wallet = Wallet.Disconnected }, Cmd.none )

        _ ->
            ( model, Cmd.none )


routeWalletMsg : D.Value -> Model -> ( Model, Cmd Msg )
routeWalletMsg value model =
    case D.decodeValue Wallet.decoder value of
        Ok walletMsg ->
            ( { model | wallet = Wallet.update expectedChain walletMsg model.wallet }
            , Cmd.none
            )

        Err _ ->
            ( model, Cmd.none )


routeTxMsg : D.Value -> Model -> ( Model, Cmd Msg )
routeTxMsg value model =
    case D.decodeValue Tx.decoder value of
        Ok txMsg ->
            ( { model | transferTx = Tx.update txMsg model.transferTx }, Cmd.none )

        Err _ ->
            ( model, Cmd.none )



-- VIEW


view : Model -> Html Msg
view model =
    div
        [ style "font-family" "monospace"
        , style "padding" "24px"
        , style "max-width" "640px"
        ]
        [ h1 [] [ text "elm-web3 basic example" ]
        , viewWallet model
        , if Wallet.isConnected model.wallet then
            div []
                [ viewBalance model
                , viewTransfer model
                ]

          else
            text ""
        ]


viewWallet : Model -> Html Msg
viewWallet model =
    div [ style "margin-bottom" "24px" ]
        [ h2 [] [ text "Wallet" ]
        , case model.wallet of
            Wallet.Disconnected ->
                button [ onClick ConnectWallet ] [ text "Connect Wallet" ]

            Wallet.Connecting ->
                p [] [ text "Connecting..." ]

            Wallet.Connected info ->
                div []
                    [ p [] [ text ("Address: " ++ T.addressToString info.address) ]
                    , p [] [ text ("Chain ID: " ++ String.fromInt (T.chainIdToInt info.chainId)) ]
                    , button [ onClick DisconnectWallet ] [ text "Disconnect" ]
                    ]

            Wallet.WrongChain info _ ->
                div []
                    [ p [] [ text ("Wrong network. Connected to chain " ++ String.fromInt (T.chainIdToInt info.chainId)) ]
                    , p [] [ text ("Expected chain " ++ String.fromInt (T.chainIdToInt expectedChain)) ]
                    , button
                        [ onClick (ConnectWallet) ]
                        [ text "Switch Network" ]
                    ]

            Wallet.Error err ->
                div []
                    [ p [] [ text ("Wallet error: " ++ err) ]
                    , button [ onClick ConnectWallet ] [ text "Try Again" ]
                    ]
        ]


viewBalance : Model -> Html Msg
viewBalance model =
    div [ style "margin-bottom" "24px" ]
        [ h2 [] [ text "Token Balance" ]
        , div []
            [ label [] [ text "Token address: " ]
            , input
                [ value model.tokenAddress
                , onInput TokenAddressChanged
                , style "width" "400px"
                , style "font-family" "monospace"
                ]
                []
            ]
        , div [ style "margin-top" "8px" ]
            [ button [ onClick ReadBalance ] [ text "Read Balance" ] ]
        , case model.balance of
            BalanceIdle ->
                text ""

            BalanceLoading ->
                p [] [ text "Loading..." ]

            BalanceLoaded raw ->
                p []
                    [ text "Balance (ABI-encoded hex): "
                    , text raw
                    ]

            BalanceError err ->
                p [ style "color" "red" ] [ text err ]
        ]


viewTransfer : Model -> Html Msg
viewTransfer model =
    div [ style "margin-bottom" "24px" ]
        [ h2 [] [ text "Transfer" ]
        , div []
            [ label [] [ text "Recipient: " ]
            , input
                [ value model.recipient
                , onInput RecipientChanged
                , placeholder "0x..."
                , style "width" "400px"
                , style "font-family" "monospace"
                ]
                []
            ]
        , div [ style "margin-top" "8px" ]
            [ label [] [ text "Amount (smallest unit, e.g. 1000000 for 1 USDC): " ]
            , input
                [ value model.amount
                , onInput AmountChanged
                , placeholder "1000000"
                , style "font-family" "monospace"
                ]
                []
            ]
        , div [ style "margin-top" "8px" ]
            [ button
                [ onClick SendTransfer
                , disabled (Tx.isPending model.transferTx)
                ]
                [ text "Send Transfer" ]
            ]
        , viewTxStatus model.transferTx
        ]


viewTxStatus : Tx.Status -> Html Msg
viewTxStatus status =
    case status of
        Tx.Idle ->
            text ""

        Tx.AwaitingSignature ->
            p [] [ text "Waiting for wallet signature..." ]

        Tx.Submitted hash ->
            p [] [ text ("Submitted: " ++ T.txHashToString hash) ]

        Tx.Confirming hash count ->
            p []
                [ text
                    ("Confirming "
                        ++ T.txHashToString hash
                        ++ " ("
                        ++ String.fromInt count
                        ++ " blocks)"
                    )
                ]

        Tx.Confirmed receipt ->
            div []
                [ p [] [ text ("Confirmed in block " ++ String.fromInt receipt.blockNumber) ]
                , p [] [ text ("Gas used: " ++ receipt.gasUsed) ]
                , p []
                    [ text
                        ("Status: "
                            ++ (if receipt.status then
                                    "success"

                                else
                                    "reverted"
                               )
                        )
                    ]
                , p [] [ text ("Tx: " ++ T.txHashToString receipt.txHash) ]
                ]

        Tx.Failed err ->
            p [ style "color" "red" ] [ text ("Failed: " ++ err) ]

        Tx.Rejected ->
            p [] [ text "Transaction rejected by user." ]



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions _ =
    web3Sub Web3Response



-- MAIN


main : Program () Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
