module Web3.Block exposing
    ( Cmd(..)
    , Msg(..)
    , Block
    , getBlockNumber
    , getBlock
    , watchBlockNumber
    , getBlockTransactionCount
    , encode
    , decoder
    )

{-| Block number and block data queries.

    -- One-shot block number query:
    port web3Cmd : Json.Encode.Value -> Cmd msg
    port web3Sub : (Json.Decode.Value -> msg) -> Sub msg

    type Msg = GotBlock Block.Msg | ...

    subscriptions model =
        web3Sub (Json.Decode.decodeValue Block.decoder >> Result.toMaybe >> Maybe.map GotBlock)

    fetchBlock : Platform.Cmd msg
    fetchBlock =
        web3Cmd (Block.encode (Block.getBlockNumber "my-id"))

@docs Cmd, Msg, Block
@docs getBlockNumber, getBlock, watchBlockNumber, getBlockTransactionCount
@docs encode, decoder

-}

import Json.Decode as D
import Json.Encode as E
import Web3.BigInt as BigInt exposing (BigInt)
import Web3.Types as T


{-| Commands to query block data via port.
-}
type Cmd
    = RequestBlockNumber String
    | RequestBlock T.BlockNumber String
    | WatchBlockNumber String
    | RequestBlockTxCount T.BlockNumber String


{-| Messages from the JS block port.
-}
type Msg
    = GotBlockNumber String Int
    | GotBlock String Block
    | GotBlockTxCount String Int


{-| A block header with key fields.
-}
type alias Block =
    { number : Int
    , hash : String
    , timestamp : Int
    , gasLimit : BigInt
    , gasUsed : BigInt
    , baseFeePerGas : Maybe BigInt
    , parentHash : String
    }


{-| Request the current block number. The `id` is echoed back in the response.
-}
getBlockNumber : String -> Cmd
getBlockNumber id =
    RequestBlockNumber id


{-| Request a specific block by block number. The `id` is echoed back.
-}
getBlock : T.BlockNumber -> String -> Cmd
getBlock blockNum id =
    RequestBlock blockNum id


{-| Start polling the block number every 4 seconds. The `id` tags each
GotBlockNumber response so you can distinguish multiple watchers.
-}
watchBlockNumber : String -> Cmd
watchBlockNumber id =
    WatchBlockNumber id


{-| Request the number of transactions in a block. The second argument is a request ID.
-}
getBlockTransactionCount : T.BlockNumber -> String -> Cmd
getBlockTransactionCount blockNumber id =
    RequestBlockTxCount blockNumber id


{-| Encode a Cmd for the JS port.
-}
encode : Cmd -> E.Value
encode cmd =
    case cmd of
        RequestBlockNumber id ->
            E.object
                [ ( "tag", E.string "getBlockNumber" )
                , ( "id", E.string id )
                ]

        RequestBlock blockNum id ->
            E.object
                [ ( "tag", E.string "getBlock" )
                , ( "block", T.encodeBlockNumber blockNum )
                , ( "id", E.string id )
                ]

        WatchBlockNumber id ->
            E.object
                [ ( "tag", E.string "watchBlockNumber" )
                , ( "id", E.string id )
                ]

        RequestBlockTxCount blockNumber id ->
            E.object
                [ ( "tag", E.string "getBlockTransactionCount" )
                , ( "block", T.encodeBlockNumber blockNumber )
                , ( "id", E.string id )
                ]


{-| Decode Msg responses from the JS port.
-}
decoder : D.Decoder Msg
decoder =
    D.field "tag" D.string
        |> D.andThen
            (\tag ->
                case tag of
                    "blockNumber" ->
                        D.map2 GotBlockNumber
                            (D.field "id" D.string)
                            (D.field "number" D.int)

                    "block" ->
                        D.map2 GotBlock
                            (D.field "id" D.string)
                            blockDecoder

                    "blockTxCount" ->
                        D.map2 GotBlockTxCount
                            (D.field "id" D.string)
                            (D.field "count" D.int)

                    _ ->
                        D.fail ("Unknown block message: " ++ tag)
            )


blockDecoder : D.Decoder Block
blockDecoder =
    D.map7 Block
        (D.field "number" D.int)
        (D.field "hash" D.string)
        (D.field "timestamp" D.int)
        (D.field "gasLimit" BigInt.decoder)
        (D.field "gasUsed" BigInt.decoder)
        (D.maybe (D.field "baseFeePerGas" BigInt.decoder))
        (D.field "parentHash" D.string)
