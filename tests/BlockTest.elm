module BlockTest exposing (suite)

import Expect
import Json.Decode as D
import Test exposing (..)
import Web3.BigInt as BigInt
import Web3.Block as Block
import Web3.Fee as Fee
import Web3.Types as T


suite : Test
suite =
    describe "Web3.Block / Web3.Fee"
        [ blockEncodeTests
        , blockDecodeTests
        , blockTxCountTests
        , feeEncodeTests
        , feeDecodeTests
        ]


blockEncodeTests : Test
blockEncodeTests =
    describe "Block encode"
        [ test "getBlockNumber encodes tag and id" <|
            \_ ->
                Block.encode (Block.getBlockNumber "q1")
                    |> D.decodeValue
                        (D.map2 Tuple.pair
                            (D.field "tag" D.string)
                            (D.field "id" D.string)
                        )
                    |> Expect.equal (Ok ( "getBlockNumber", "q1" ))
        , test "getBlock encodes tag, block, and id" <|
            \_ ->
                Block.encode (Block.getBlock T.Latest "q2")
                    |> D.decodeValue
                        (D.map3 (\t b i -> ( t, b, i ))
                            (D.field "tag" D.string)
                            (D.field "block" D.string)
                            (D.field "id" D.string)
                        )
                    |> Expect.equal (Ok ( "getBlock", "latest", "q2" ))
        , test "watchBlockNumber encodes tag and id" <|
            \_ ->
                Block.encode (Block.watchBlockNumber "poll")
                    |> D.decodeValue
                        (D.map2 Tuple.pair
                            (D.field "tag" D.string)
                            (D.field "id" D.string)
                        )
                    |> Expect.equal (Ok ( "watchBlockNumber", "poll" ))
        ]


blockDecodeTests : Test
blockDecodeTests =
    describe "Block decoder"
        [ test "decodes blockNumber message" <|
            \_ ->
                """{"tag":"blockNumber","id":"q1","number":12345}"""
                    |> D.decodeString Block.decoder
                    |> (\r ->
                            case r of
                                Ok (Block.GotBlockNumber id num) ->
                                    Expect.all
                                        [ \_ -> id |> Expect.equal "q1"
                                        , \_ -> num |> Expect.equal 12345
                                        ]
                                        ()

                                _ ->
                                    Expect.fail "Expected GotBlockNumber"
                       )
        , test "decodes block message" <|
            \_ ->
                """{"tag":"block","id":"q2","number":100,"hash":"0xabc","timestamp":1700000000,"gasLimit":"30000000","gasUsed":"15000000","parentHash":"0xdef"}"""
                    |> D.decodeString Block.decoder
                    |> (\r ->
                            case r of
                                Ok (Block.GotBlock id block) ->
                                    Expect.all
                                        [ \_ -> id |> Expect.equal "q2"
                                        , \_ -> block.number |> Expect.equal 100
                                        , \_ -> BigInt.toString block.gasLimit |> Expect.equal "30000000"
                                        , \_ -> block.baseFeePerGas |> Expect.equal Nothing
                                        ]
                                        ()

                                _ ->
                                    Expect.fail "Expected GotBlock"
                       )
        , test "decodes block message with baseFeePerGas" <|
            \_ ->
                """{"tag":"block","id":"q3","number":200,"hash":"0xabc","timestamp":1700000001,"gasLimit":"30000000","gasUsed":"15000000","baseFeePerGas":"1000000000","parentHash":"0xdef"}"""
                    |> D.decodeString Block.decoder
                    |> (\r ->
                            case r of
                                Ok (Block.GotBlock _ block) ->
                                    block.baseFeePerGas
                                        |> Maybe.map BigInt.toString
                                        |> Expect.equal (Just "1000000000")

                                _ ->
                                    Expect.fail "Expected GotBlock with baseFeePerGas"
                       )
        , test "fails on unknown tag" <|
            \_ ->
                """{"tag":"unknown"}"""
                    |> D.decodeString Block.decoder
                    |> (\r ->
                            case r of
                                Err _ ->
                                    Expect.pass

                                Ok _ ->
                                    Expect.fail "Expected decode failure"
                       )
        ]


blockTxCountTests : Test
blockTxCountTests =
    describe "getBlockTransactionCount"
        [ test "getBlockTransactionCount encode has correct tag" <|
            \_ ->
                Block.encode (Block.getBlockTransactionCount (T.BlockNum 100) "req-1")
                    |> D.decodeValue (D.field "tag" D.string)
                    |> Expect.equal (Ok "getBlockTransactionCount")
        , test "getBlockTransactionCount encode with BlockNum has int block" <|
            \_ ->
                Block.encode (Block.getBlockTransactionCount (T.BlockNum 100) "req-1")
                    |> D.decodeValue (D.field "block" D.int)
                    |> Expect.equal (Ok 100)
        , test "getBlockTransactionCount encode with Latest has string block" <|
            \_ ->
                Block.encode (Block.getBlockTransactionCount T.Latest "req-1")
                    |> D.decodeValue (D.field "block" D.string)
                    |> Expect.equal (Ok "latest")
        , test "getBlockTransactionCount encode has id field" <|
            \_ ->
                Block.encode (Block.getBlockTransactionCount T.Latest "req-1")
                    |> D.decodeValue (D.field "id" D.string)
                    |> Expect.equal (Ok "req-1")
        , test "blockTxCount decodes to GotBlockTxCount" <|
            \_ ->
                """{"tag":"blockTxCount","id":"req-1","count":42}"""
                    |> D.decodeString Block.decoder
                    |> (\result ->
                            case result of
                                Ok (Block.GotBlockTxCount id count) ->
                                    Expect.all
                                        [ \_ -> id |> Expect.equal "req-1"
                                        , \_ -> count |> Expect.equal 42
                                        ]
                                        ()

                                _ ->
                                    Expect.fail "Expected GotBlockTxCount"
                       )
        ]


feeEncodeTests : Test
feeEncodeTests =
    describe "Fee encode"
        [ test "getGasPrice encodes tag and id" <|
            \_ ->
                Fee.encode (Fee.getGasPrice "gp1")
                    |> D.decodeValue
                        (D.map2 Tuple.pair
                            (D.field "tag" D.string)
                            (D.field "id" D.string)
                        )
                    |> Expect.equal (Ok ( "getGasPrice", "gp1" ))
        , test "getFeeHistory encodes tag, id, and blockCount" <|
            \_ ->
                Fee.encode (Fee.getFeeHistory "fh1" 10)
                    |> D.decodeValue
                        (D.map3 (\t i c -> ( t, i, c ))
                            (D.field "tag" D.string)
                            (D.field "id" D.string)
                            (D.field "blockCount" D.int)
                        )
                    |> Expect.equal (Ok ( "getFeeHistory", "fh1", 10 ))
        ]


feeDecodeTests : Test
feeDecodeTests =
    describe "Fee decoder"
        [ test "decodes gasPrice message" <|
            \_ ->
                """{"tag":"gasPrice","id":"gp1","wei":"1000000000"}"""
                    |> D.decodeString Fee.decoder
                    |> (\r ->
                            case r of
                                Ok (Fee.GotGasPrice id wei) ->
                                    Expect.all
                                        [ \_ -> id |> Expect.equal "gp1"
                                        , \_ -> BigInt.toString wei |> Expect.equal "1000000000"
                                        ]
                                        ()

                                _ ->
                                    Expect.fail "Expected GotGasPrice"
                       )
        , test "decodes feeHistory message" <|
            \_ ->
                """{"tag":"feeHistory","id":"fh1","baseFeePerGas":["1000000000","2000000000"],"gasUsedRatio":[0.5,0.6],"oldestBlock":100}"""
                    |> D.decodeString Fee.decoder
                    |> (\r ->
                            case r of
                                Ok (Fee.GotFeeHistory id history) ->
                                    Expect.all
                                        [ \_ -> id |> Expect.equal "fh1"
                                        , \_ -> List.length history.baseFeePerGas |> Expect.equal 2
                                        , \_ -> history.oldestBlock |> Expect.equal 100
                                        ]
                                        ()

                                _ ->
                                    Expect.fail "Expected GotFeeHistory"
                       )
        ]
