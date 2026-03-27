module Web3 exposing
    ( Model
    , Msg(..)
    , init
    , update
    , subscriptions
    , encodeTxCmd
    )

{-| Top-level module that composes wallet and transaction state.

This module bundles `Web3.Wallet.State` and a list of named `Web3.Transaction.Status`
values into a single `Model`. Wire it into your app's model/update/subscriptions
to get wallet connection, chain validation, and transaction tracking with a single
port pair.

    port web3Cmd : Json.Encode.Value -> Cmd msg
    port web3Sub : (Json.Decode.Value -> msg) -> Sub msg

    type alias Model =
        { web3 : Web3.Model
        , ...
        }

    type Msg
        = Web3Msg Web3.Msg
        | ...

    init : ( Model, Cmd Msg )
    init =
        ( { web3 = Web3.init (Web3.Types.chainId 369), ... }, Cmd.none )

    update msg model =
        case msg of
            Web3Msg subMsg ->
                ( { model | web3 = Web3.update subMsg model.web3 }, Cmd.none )

    subscriptions model =
        web3Sub (Json.Decode.decodeValue Web3.Wallet.decoder
                    >> Result.map Web3.WalletMsg
                    >> Result.withDefault (Web3Msg (Web3.WalletMsg Web3.Wallet.WalletDisconnected))
                )

For individual modules without the combined wrapper, import `Web3.Wallet`,
`Web3.Transaction`, `Web3.Balance`, `Web3.Block`, etc. directly.

@docs Model, Msg
@docs init, update, subscriptions, encodeTxCmd

-}

import Json.Decode as D
import Json.Encode as E
import Web3.Transaction as Tx
import Web3.Types as T
import Web3.Wallet as Wallet


{-| Combined wallet + transaction state.
-}
type alias Model =
    { wallet : Wallet.State
    , expectedChain : T.ChainId
    , transactions : List ( String, Tx.Status )
    }


{-| Messages for wallet and transaction updates.
-}
type Msg
    = WalletMsg Wallet.Msg
    | TxMsg String Tx.Msg
    | TxCmdMsg String Tx.TxCmd


{-| Initialize with the expected chain ID.
-}
init : T.ChainId -> Model
init chain =
    { wallet = Wallet.Disconnected
    , expectedChain = chain
    , transactions = []
    }


{-| Update wallet and transaction state from a port message.
-}
update : Msg -> Model -> Model
update msg model =
    case msg of
        WalletMsg walletMsg ->
            { model | wallet = Wallet.update model.expectedChain walletMsg model.wallet }

        TxMsg txId txMsg ->
            { model
                | transactions =
                    List.map
                        (\( id, status ) ->
                            if id == txId then
                                ( id, Tx.update txMsg status )

                            else
                                ( id, status )
                        )
                        model.transactions
            }

        TxCmdMsg _ _ ->
            -- TxCmdMsg carries an outbound command; state is unchanged.
            -- Use encodeTxCmd to get the Json.Encode.Value to send via your port.
            model


{-| Encode a `TxCmd` (e.g. `RequestReceipt`) for sending via your port.

    web3Cmd (Web3.encodeTxCmd (Tx.RequestReceipt hash "my-id"))

-}
encodeTxCmd : Tx.TxCmd -> E.Value
encodeTxCmd =
    Tx.encodeCmd


{-| Placeholder for port subscriptions. Wire your port decoder here.
-}
subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.none
