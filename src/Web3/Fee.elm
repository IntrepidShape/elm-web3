module Web3.Fee exposing
    ( Cmd(..)
    , Msg(..)
    , FeeHistory
    , getGasPrice
    , getFeeHistory
    , encode
    , decoder
    )

{-| Gas price and fee history queries.

    fetchGasPrice : Platform.Cmd msg
    fetchGasPrice =
        web3Cmd (Fee.encode (Fee.getGasPrice "gas-query"))

@docs Cmd, Msg, FeeHistory
@docs getGasPrice, getFeeHistory
@docs encode, decoder

-}

import Json.Decode as D
import Json.Encode as E
import Web3.BigInt as BigInt exposing (BigInt)


{-| Commands to query fee data via port.
-}
type Cmd
    = RequestGasPrice String
    | RequestFeeHistory String Int


{-| Messages from the JS fee port.
-}
type Msg
    = GotGasPrice String BigInt
    | GotFeeHistory String FeeHistory


{-| Historical fee data from eth_feeHistory.
-}
type alias FeeHistory =
    { baseFeePerGas : List BigInt
    , gasUsedRatio : List Float
    , oldestBlock : Int
    }


{-| Request the current gas price (eth_gasPrice). The `id` is echoed back.
-}
getGasPrice : String -> Cmd
getGasPrice id =
    RequestGasPrice id


{-| Request fee history for the last `blockCount` blocks.
-}
getFeeHistory : String -> Int -> Cmd
getFeeHistory id blockCount =
    RequestFeeHistory id blockCount


{-| Encode a Cmd for the JS port.
-}
encode : Cmd -> E.Value
encode cmd =
    case cmd of
        RequestGasPrice id ->
            E.object
                [ ( "tag", E.string "getGasPrice" )
                , ( "id", E.string id )
                ]

        RequestFeeHistory id blockCount ->
            E.object
                [ ( "tag", E.string "getFeeHistory" )
                , ( "id", E.string id )
                , ( "blockCount", E.int blockCount )
                ]


{-| Decode Msg responses from the JS port.
-}
decoder : D.Decoder Msg
decoder =
    D.field "tag" D.string
        |> D.andThen
            (\tag ->
                case tag of
                    "gasPrice" ->
                        D.map2 GotGasPrice
                            (D.field "id" D.string)
                            (D.field "wei" BigInt.decoder)

                    "feeHistory" ->
                        D.map2 GotFeeHistory
                            (D.field "id" D.string)
                            feeHistoryDecoder

                    _ ->
                        D.fail ("Unknown fee message: " ++ tag)
            )


feeHistoryDecoder : D.Decoder FeeHistory
feeHistoryDecoder =
    D.map3 FeeHistory
        (D.field "baseFeePerGas" (D.list BigInt.decoder))
        (D.field "gasUsedRatio" (D.list D.float))
        (D.field "oldestBlock" D.int)


