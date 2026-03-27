module Web3.Query exposing
    ( Cmd(..)
    , Msg(..)
    , TransactionInfo
    , getTxCount
    , getStorageAt
    , getCode
    , getTransaction
    , encode
    , decoder
    )

{-| Typed decoders for on-chain read queries: transaction count (nonce),
storage slot reads, contract bytecode, and transaction lookup by hash.

Each query carries a correlation `id` that is echoed back so responses can
be matched when multiple queries are in flight.

    -- Send via your port:
    web3Cmd (Web3.Query.encode (Web3.Query.getTxCount address "nonce-1"))

    -- Receive via your port:
    case D.decodeValue Web3.Query.decoder incoming of
        Ok (Web3.Query.GotTxCount id nonce) -> ...
        Ok (Web3.Query.GotStorageAt id val) -> ...
        Ok (Web3.Query.GotCode id bytecode) -> ...
        Ok (Web3.Query.GotTransaction id info) -> ...
        Ok (Web3.Query.TransactionNotFound id) -> ...
        Err _ -> -- not a query response

@docs Cmd, Msg, TransactionInfo
@docs getTxCount, getStorageAt, getCode, getTransaction, encode, decoder

-}

import Json.Decode as D
import Json.Encode as E
import Web3.BigInt as BigInt
import Web3.Types as T


{-| Commands to send to the JS query port.
-}
type Cmd
    = RequestTxCount T.Address String
    | RequestStorageAt T.Address Int String
    | RequestCode T.Address String
    | RequestTransaction T.TxHash String


{-| Messages from the JS query port.
-}
type Msg
    = GotTxCount String Int
    | GotStorageAt String String
    | GotCode String String
    | GotTransaction String TransactionInfo
    | TransactionNotFound String


{-| Information about a transaction fetched by hash.
-}
type alias TransactionInfo =
    { hash : T.TxHash
    , from : T.Address
    , to : Maybe T.Address
    , value : T.Wei
    , nonce : Int
    , data : String
    , gas : Int
    , blockNumber : Maybe Int
    , blockHash : Maybe String
    }


{-| Build a transaction count (nonce) query for `address`, tagged with `id`.
-}
getTxCount : T.Address -> String -> Cmd
getTxCount addr id =
    RequestTxCount addr id


{-| Build a storage slot query. `slot` is the integer slot index (converted to hex).
-}
getStorageAt : T.Address -> Int -> String -> Cmd
getStorageAt contract slot id =
    RequestStorageAt contract slot id


{-| Build a contract bytecode query for `contract`, tagged with `id`.
-}
getCode : T.Address -> String -> Cmd
getCode contract id =
    RequestCode contract id


{-| Request a transaction by hash. The second argument is a request ID.
-}
getTransaction : T.TxHash -> String -> Cmd
getTransaction hash id =
    RequestTransaction hash id


{-| Encode a `Cmd` for the JS port.
-}
encode : Cmd -> E.Value
encode cmd =
    case cmd of
        RequestTxCount addr id ->
            E.object
                [ ( "tag", E.string "getTransactionCount" )
                , ( "address", E.string (T.addressToString addr) )
                , ( "id", E.string id )
                ]

        RequestStorageAt contract slot id ->
            E.object
                [ ( "tag", E.string "getStorageAt" )
                , ( "contract", E.string (T.addressToString contract) )
                , ( "slot", E.string (intToHex slot) )
                , ( "id", E.string id )
                ]

        RequestCode contract id ->
            E.object
                [ ( "tag", E.string "getCode" )
                , ( "contract", E.string (T.addressToString contract) )
                , ( "id", E.string id )
                ]

        RequestTransaction hash id ->
            E.object
                [ ( "tag", E.string "getTransaction" )
                , ( "hash", E.string (T.txHashToString hash) )
                , ( "id", E.string id )
                ]


intToHex : Int -> String
intToHex n =
    let
        hexDigit d =
            if d < 10 then
                Char.fromCode (Char.toCode '0' + d)

            else
                Char.fromCode (Char.toCode 'a' + (d - 10))

        go acc remaining =
            if remaining == 0 then
                acc

            else
                go (hexDigit (modBy 16 remaining) :: acc) (remaining // 16)
    in
    if n == 0 then
        "0x0"

    else
        "0x" ++ String.fromList (go [] n)


{-| Decode query responses from the JS port.

Handles `txCount`, `storageAt`, `code`, `transaction`, and `transactionNotFound` tags.
Returns `Err` for unknown tags.

-}
decoder : D.Decoder Msg
decoder =
    D.field "tag" D.string
        |> D.andThen
            (\tag ->
                case tag of
                    "txCount" ->
                        D.map2 GotTxCount
                            (D.field "id" D.string)
                            (D.field "count" D.int)

                    "storageAt" ->
                        D.map2 GotStorageAt
                            (D.field "id" D.string)
                            (D.field "data" D.string)

                    "code" ->
                        D.map2 GotCode
                            (D.field "id" D.string)
                            (D.field "data" D.string)

                    "transaction" ->
                        D.map2 GotTransaction
                            (D.field "id" D.string)
                            transactionInfoDecoder

                    "transactionNotFound" ->
                        D.map TransactionNotFound
                            (D.field "id" D.string)

                    _ ->
                        D.fail ("Unknown query response tag: " ++ tag)
            )


decodeTxHash : D.Decoder T.TxHash
decodeTxHash =
    D.string
        |> D.andThen
            (\s ->
                case T.txHash s of
                    Just h ->
                        D.succeed h

                    Nothing ->
                        D.fail ("Invalid tx hash: " ++ s)
            )


decodeAddress : D.Decoder T.Address
decodeAddress =
    D.string
        |> D.andThen
            (\s ->
                case T.address s of
                    Just a ->
                        D.succeed a

                    Nothing ->
                        D.fail ("Invalid address: " ++ s)
            )


decodeWei : D.Decoder T.Wei
decodeWei =
    D.string
        |> D.andThen
            (\s ->
                case BigInt.fromString s of
                    Just n ->
                        D.succeed n

                    Nothing ->
                        D.fail ("Invalid wei value: " ++ s)
            )


transactionInfoDecoder : D.Decoder TransactionInfo
transactionInfoDecoder =
    D.map7
        (\hash from to value nonce data gas ->
            { hash = hash
            , from = from
            , to = to
            , value = value
            , nonce = nonce
            , data = data
            , gas = gas
            , blockNumber = Nothing
            , blockHash = Nothing
            }
        )
        (D.field "hash" decodeTxHash)
        (D.field "from" decodeAddress)
        (D.field "to" (D.nullable decodeAddress))
        (D.field "value" decodeWei)
        (D.field "nonce" D.int)
        (D.field "data" D.string)
        (D.field "gas" D.int)
        |> D.andThen
            (\info ->
                D.map2
                    (\blockNumber blockHash ->
                        { info | blockNumber = blockNumber, blockHash = blockHash }
                    )
                    (D.maybe (D.field "blockNumber" D.int))
                    (D.maybe (D.field "blockHash" D.string))
            )
