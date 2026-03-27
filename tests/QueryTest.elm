module QueryTest exposing (suite)

import Expect
import Json.Decode as D
import Test exposing (..)
import Web3.Query as Query
import Web3.Types as T


validAddress : String
validAddress =
    "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"


validHash : String
validHash =
    "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd"


suite : Test
suite =
    describe "Web3.Query"
        [ encodeTests
        , decodeTests
        , getTransactionTests
        ]


encodeTests : Test
encodeTests =
    describe "encode"
        [ test "getTxCount encodes correct tag" <|
            \_ ->
                case T.address validAddress of
                    Just addr ->
                        Query.encode (Query.getTxCount addr "nonce-1")
                            |> D.decodeValue (D.field "tag" D.string)
                            |> Expect.equal (Ok "getTransactionCount")

                    Nothing ->
                        Expect.fail "Invalid address"
        , test "getTxCount encodes id" <|
            \_ ->
                case T.address validAddress of
                    Just addr ->
                        Query.encode (Query.getTxCount addr "nonce-42")
                            |> D.decodeValue (D.field "id" D.string)
                            |> Expect.equal (Ok "nonce-42")

                    Nothing ->
                        Expect.fail "Invalid address"
        , test "getStorageAt encodes correct tag" <|
            \_ ->
                case T.address validAddress of
                    Just addr ->
                        Query.encode (Query.getStorageAt addr 0 "slot-1")
                            |> D.decodeValue (D.field "tag" D.string)
                            |> Expect.equal (Ok "getStorageAt")

                    Nothing ->
                        Expect.fail "Invalid address"
        , test "getStorageAt encodes slot as hex" <|
            \_ ->
                case T.address validAddress of
                    Just addr ->
                        Query.encode (Query.getStorageAt addr 255 "slot-1")
                            |> D.decodeValue (D.field "slot" D.string)
                            |> Expect.equal (Ok "0xff")

                    Nothing ->
                        Expect.fail "Invalid address"
        , test "getCode encodes correct tag" <|
            \_ ->
                case T.address validAddress of
                    Just addr ->
                        Query.encode (Query.getCode addr "code-1")
                            |> D.decodeValue (D.field "tag" D.string)
                            |> Expect.equal (Ok "getCode")

                    Nothing ->
                        Expect.fail "Invalid address"
        , test "getCode encodes id" <|
            \_ ->
                case T.address validAddress of
                    Just addr ->
                        Query.encode (Query.getCode addr "my-code-id")
                            |> D.decodeValue (D.field "id" D.string)
                            |> Expect.equal (Ok "my-code-id")

                    Nothing ->
                        Expect.fail "Invalid address"
        ]


decodeTests : Test
decodeTests =
    describe "decoder"
        [ test "decodes txCount response" <|
            \_ ->
                """{"tag":"txCount","id":"nonce-1","count":42}"""
                    |> D.decodeString Query.decoder
                    |> Expect.equal (Ok (Query.GotTxCount "nonce-1" 42))
        , test "decodes storageAt response" <|
            \_ ->
                """{"tag":"storageAt","id":"slot-1","data":"0xabcdef"}"""
                    |> D.decodeString Query.decoder
                    |> Expect.equal (Ok (Query.GotStorageAt "slot-1" "0xabcdef"))
        , test "decodes code response" <|
            \_ ->
                """{"tag":"code","id":"code-1","data":"0x6080"}"""
                    |> D.decodeString Query.decoder
                    |> Expect.equal (Ok (Query.GotCode "code-1" "0x6080"))
        , test "fails on unknown tag" <|
            \_ ->
                """{"tag":"balance","id":"x","count":1}"""
                    |> D.decodeString Query.decoder
                    |> (\r ->
                            case r of
                                Err _ ->
                                    Expect.pass

                                Ok _ ->
                                    Expect.fail "Expected decode failure for unknown tag"
                       )
        , test "fails on missing count field for txCount" <|
            \_ ->
                """{"tag":"txCount","id":"nonce-1"}"""
                    |> D.decodeString Query.decoder
                    |> (\r ->
                            case r of
                                Err _ ->
                                    Expect.pass

                                Ok _ ->
                                    Expect.fail "Expected decode failure for missing count"
                       )
        ]


getTransactionTests : Test
getTransactionTests =
    describe "getTransaction"
        [ test "getTransaction encode has correct tag" <|
            \_ ->
                case T.txHash validHash of
                    Just h ->
                        Query.encode (Query.getTransaction h "req-1")
                            |> D.decodeValue (D.field "tag" D.string)
                            |> Expect.equal (Ok "getTransaction")

                    Nothing ->
                        Expect.fail "Invalid hash"
        , test "getTransaction encode has hash field" <|
            \_ ->
                case T.txHash validHash of
                    Just h ->
                        Query.encode (Query.getTransaction h "req-1")
                            |> D.decodeValue (D.field "hash" D.string)
                            |> Expect.equal (Ok validHash)

                    Nothing ->
                        Expect.fail "Invalid hash"
        , test "getTransaction encode has id field" <|
            \_ ->
                case T.txHash validHash of
                    Just h ->
                        Query.encode (Query.getTransaction h "req-1")
                            |> D.decodeValue (D.field "id" D.string)
                            |> Expect.equal (Ok "req-1")

                    Nothing ->
                        Expect.fail "Invalid hash"
        , test "GotTransaction decodes from transaction message" <|
            \_ ->
                let
                    json =
                        """{"tag":"transaction","id":"req-1","hash":"""
                            ++ "\""
                            ++ validHash
                            ++ "\""
                            ++ ""","from":"""
                            ++ "\""
                            ++ validAddress
                            ++ "\""
                            ++ ""","to":null,"value":"1000000000000000000","nonce":5,"data":"0x","gas":21000,"blockNumber":12345,"blockHash":"0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}"""
                in
                json
                    |> D.decodeString Query.decoder
                    |> (\result ->
                            case result of
                                Ok (Query.GotTransaction id info) ->
                                    Expect.all
                                        [ \_ -> id |> Expect.equal "req-1"
                                        , \_ -> info.nonce |> Expect.equal 5
                                        , \_ -> info.gas |> Expect.equal 21000
                                        ]
                                        ()

                                _ ->
                                    Expect.fail "Expected GotTransaction"
                       )
        , test "TransactionNotFound decodes from transactionNotFound message" <|
            \_ ->
                """{"tag":"transactionNotFound","id":"req-2"}"""
                    |> D.decodeString Query.decoder
                    |> (\result ->
                            case result of
                                Ok (Query.TransactionNotFound id) ->
                                    id |> Expect.equal "req-2"

                                _ ->
                                    Expect.fail "Expected TransactionNotFound"
                       )
        ]
