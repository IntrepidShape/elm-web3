module Web3 exposing
    ( Model
    , Msg(..)
    , init
    , update
    , subscriptions
    )

{-| Top-level Web3 module that composes wallet + transaction state.

Wire this into your Elm app's Model/update/subscriptions.

    import Web3

    type alias Model =
        { web3 : Web3.Model
        , ...
        }

    type Msg
        = Web3Msg Web3.Msg
        | ...

    update msg model =
        case msg of
            Web3Msg subMsg ->
                { model | web3 = Web3.update subMsg model.web3 }

@docs Model, Msg
@docs init, update, subscriptions

-}

import Json.Decode as D
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


{-| Placeholder for port subscriptions. Wire your port decoder here.
-}
subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.none
