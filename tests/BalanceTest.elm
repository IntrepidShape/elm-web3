module BalanceTest exposing (suite)

import Expect
import Json.Decode as D
import Json.Encode as E
import Test exposing (..)
import Web3.Balance as Balance
import Web3.Types as T


validAddress : String
validAddress =
    "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"


suite : Test
suite =
    describe "Web3.Balance"
        [ encodeTests
        , decodeTests
        ]


encodeTests : Test
encodeTests =
    describe "encode"
        [ test "encodes tag as 'getBalance'" <|
            \_ ->
                case T.address validAddress of
                    Just addr ->
                        Balance.encode (Balance.getBalance addr "query-1")
                            |> D.decodeValue (D.field "tag" D.string)
                            |> Expect.equal (Ok "getBalance")

                    Nothing ->
                        Expect.fail "Invalid address"
        , test "encodes address field" <|
            \_ ->
                case T.address validAddress of
                    Just addr ->
                        Balance.encode (Balance.getBalance addr "query-1")
                            |> D.decodeValue (D.field "address" D.string)
                            |> Expect.equal (Ok validAddress)

                    Nothing ->
                        Expect.fail "Invalid address"
        , test "encodes id field" <|
            \_ ->
                case T.address validAddress of
                    Just addr ->
                        Balance.encode (Balance.getBalance addr "my-id-42")
                            |> D.decodeValue (D.field "id" D.string)
                            |> Expect.equal (Ok "my-id-42")

                    Nothing ->
                        Expect.fail "Invalid address"
        , test "id round-trips: encoded id matches decoded id" <|
            \_ ->
                case T.address validAddress of
                    Just addr ->
                        let
                            encoded =
                                Balance.encode (Balance.getBalance addr "round-trip-id")

                            decodedId =
                                D.decodeValue (D.field "id" D.string) encoded
                        in
                        decodedId |> Expect.equal (Ok "round-trip-id")

                    Nothing ->
                        Expect.fail "Invalid address"
        ]


decodeTests : Test
decodeTests =
    describe "decoder"
        [ test "decodes balance response with valid wei" <|
            \_ ->
                """{"tag":"balance","id":"query-1","wei":"1000000000000000000"}"""
                    |> D.decodeString Balance.decoder
                    |> (\r ->
                            case r of
                                Ok (Balance.GotBalance id _) ->
                                    id |> Expect.equal "query-1"

                                Err e ->
                                    Expect.fail ("Decode error: " ++ D.errorToString e)
                       )
        , test "decoded GotBalance carries the correlation id" <|
            \_ ->
                """{"tag":"balance","id":"my-correlation","wei":"500"}"""
                    |> D.decodeString Balance.decoder
                    |> (\r ->
                            case r of
                                Ok (Balance.GotBalance id _) ->
                                    id |> Expect.equal "my-correlation"

                                Err e ->
                                    Expect.fail ("Decode error: " ++ D.errorToString e)
                       )
        , test "fails on wrong tag" <|
            \_ ->
                """{"tag":"getBalance","id":"q","wei":"1"}"""
                    |> D.decodeString Balance.decoder
                    |> (\r ->
                            case r of
                                Err _ ->
                                    Expect.pass

                                Ok _ ->
                                    Expect.fail "Expected decode failure for wrong tag"
                       )
        , test "fails on invalid wei string" <|
            \_ ->
                """{"tag":"balance","id":"q","wei":"not-a-number"}"""
                    |> D.decodeString Balance.decoder
                    |> (\r ->
                            case r of
                                Err _ ->
                                    Expect.pass

                                Ok _ ->
                                    Expect.fail "Expected decode failure for invalid wei"
                       )
        , test "fails on missing id field" <|
            \_ ->
                """{"tag":"balance","wei":"100"}"""
                    |> D.decodeString Balance.decoder
                    |> (\r ->
                            case r of
                                Err _ ->
                                    Expect.pass

                                Ok _ ->
                                    Expect.fail "Expected decode failure for missing id"
                       )
        ]
