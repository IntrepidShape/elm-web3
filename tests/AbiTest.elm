module AbiTest exposing (suite)

import BigInt
import Expect
import Json.Decode as D
import Json.Encode as E
import Test exposing (..)
import Web3.Abi.Decode as Decode
import Web3.Abi.Encode as Encode
import Web3.Types as T


suite : Test
suite =
    describe "Web3.Abi"
        [ encodeTests
        , decodeTests
        , roundTripTests
        ]


encodeTests : Test
encodeTests =
    describe "Encode"
        [ test "address encodes to lowercase hex string" <|
            \_ ->
                case T.address "0xAbCdEfAbCdEfAbCdEfAbCdEfAbCdEfAbCdEfAbCd" of
                    Just a ->
                        Encode.address a
                            |> D.decodeValue D.string
                            |> Expect.equal (Ok "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd")

                    Nothing ->
                        Expect.fail "Invalid address"
        , test "uint256 encodes BigInt as string" <|
            \_ ->
                case BigInt.fromIntString "1000000000000000000" of
                    Just n ->
                        Encode.uint256 n
                            |> D.decodeValue D.string
                            |> Expect.equal (Ok "1000000000000000000")

                    Nothing ->
                        Expect.fail "Invalid BigInt"
        , test "uint256 encodes zero" <|
            \_ ->
                Encode.uint256 (BigInt.fromInt 0)
                    |> D.decodeValue D.string
                    |> Expect.equal (Ok "0")
        , test "uint256 encodes large number" <|
            \_ ->
                case BigInt.fromIntString "115792089237316195423570985008687907853269984665640564039457584007913129639935" of
                    Just n ->
                        Encode.uint256 n
                            |> D.decodeValue D.string
                            |> Expect.equal (Ok "115792089237316195423570985008687907853269984665640564039457584007913129639935")

                    Nothing ->
                        Expect.fail "Invalid BigInt"
        , test "int256 encodes negative BigInt as string" <|
            \_ ->
                Encode.int256 (BigInt.fromInt -42)
                    |> D.decodeValue D.string
                    |> Expect.equal (Ok "-42")
        , test "bool encodes True as JSON true" <|
            \_ ->
                Encode.bool True
                    |> D.decodeValue D.bool
                    |> Expect.equal (Ok True)
        , test "bool encodes False as JSON false" <|
            \_ ->
                Encode.bool False
                    |> D.decodeValue D.bool
                    |> Expect.equal (Ok False)
        , test "string encodes as JSON string" <|
            \_ ->
                Encode.string "hello world"
                    |> D.decodeValue D.string
                    |> Expect.equal (Ok "hello world")
        , test "string encodes empty string" <|
            \_ ->
                Encode.string ""
                    |> D.decodeValue D.string
                    |> Expect.equal (Ok "")
        , test "bytes encodes hex string" <|
            \_ ->
                Encode.bytes "0xdeadbeef"
                    |> D.decodeValue D.string
                    |> Expect.equal (Ok "0xdeadbeef")
        , test "bytes32 encodes 32-byte hex string" <|
            \_ ->
                let
                    b32 =
                        "0x0000000000000000000000000000000000000000000000000000000000000001"
                in
                Encode.bytes32 b32
                    |> D.decodeValue D.string
                    |> Expect.equal (Ok b32)
        ]


decodeTests : Test
decodeTests =
    describe "Decode"
        [ test "address decodes valid hex string" <|
            \_ ->
                E.string "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
                    |> D.decodeValue Decode.address
                    |> (\r ->
                            case r of
                                Ok a ->
                                    T.addressToString a
                                        |> Expect.equal "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"

                                Err e ->
                                    Expect.fail (D.errorToString e)
                       )
        , test "address rejects invalid hex string" <|
            \_ ->
                E.string "not-an-address"
                    |> D.decodeValue Decode.address
                    |> (\r ->
                            case r of
                                Err _ ->
                                    Expect.pass

                                Ok _ ->
                                    Expect.fail "Expected failure"
                       )
        , test "address rejects wrong type (int)" <|
            \_ ->
                E.int 42
                    |> D.decodeValue Decode.address
                    |> (\r ->
                            case r of
                                Err _ ->
                                    Expect.pass

                                Ok _ ->
                                    Expect.fail "Expected failure"
                       )
        , test "uint256 decodes numeric string" <|
            \_ ->
                E.string "1000000"
                    |> D.decodeValue Decode.uint256
                    |> (\r ->
                            case r of
                                Ok n ->
                                    BigInt.toString n |> Expect.equal "1000000"

                                Err e ->
                                    Expect.fail (D.errorToString e)
                       )
        , test "uint256 decodes zero" <|
            \_ ->
                E.string "0"
                    |> D.decodeValue Decode.uint256
                    |> (\r ->
                            case r of
                                Ok n ->
                                    BigInt.toString n |> Expect.equal "0"

                                Err e ->
                                    Expect.fail (D.errorToString e)
                       )
        , test "uint256 rejects non-numeric string" <|
            \_ ->
                E.string "not-a-number"
                    |> D.decodeValue Decode.uint256
                    |> (\r ->
                            case r of
                                Err _ ->
                                    Expect.pass

                                Ok _ ->
                                    Expect.fail "Expected failure"
                       )
        , test "uint256 rejects wrong type (bool)" <|
            \_ ->
                E.bool True
                    |> D.decodeValue Decode.uint256
                    |> (\r ->
                            case r of
                                Err _ ->
                                    Expect.pass

                                Ok _ ->
                                    Expect.fail "Expected failure"
                       )
        , test "int256 decodes negative numeric string" <|
            \_ ->
                E.string "-42"
                    |> D.decodeValue Decode.int256
                    |> (\r ->
                            case r of
                                Ok n ->
                                    BigInt.toString n |> Expect.equal "-42"

                                Err e ->
                                    Expect.fail (D.errorToString e)
                       )
        , test "bool decodes true" <|
            \_ ->
                E.bool True
                    |> D.decodeValue Decode.bool
                    |> Expect.equal (Ok True)
        , test "bool decodes false" <|
            \_ ->
                E.bool False
                    |> D.decodeValue Decode.bool
                    |> Expect.equal (Ok False)
        , test "bool rejects string" <|
            \_ ->
                E.string "true"
                    |> D.decodeValue Decode.bool
                    |> (\r ->
                            case r of
                                Err _ ->
                                    Expect.pass

                                Ok _ ->
                                    Expect.fail "Expected failure"
                       )
        , test "string decodes string value" <|
            \_ ->
                E.string "hello"
                    |> D.decodeValue Decode.string
                    |> Expect.equal (Ok "hello")
        , test "bytes32 decodes valid 0x-prefixed 66-char string" <|
            \_ ->
                let
                    b32 =
                        "0x0000000000000000000000000000000000000000000000000000000000000001"
                in
                E.string b32
                    |> D.decodeValue Decode.bytes32
                    |> Expect.equal (Ok b32)
        , test "bytes32 rejects wrong length" <|
            \_ ->
                E.string "0xdeadbeef"
                    |> D.decodeValue Decode.bytes32
                    |> (\r ->
                            case r of
                                Err _ ->
                                    Expect.pass

                                Ok _ ->
                                    Expect.fail "Expected failure"
                       )
        , test "bytes32 rejects missing 0x prefix" <|
            \_ ->
                E.string "0000000000000000000000000000000000000000000000000000000000000001"
                    |> D.decodeValue Decode.bytes32
                    |> (\r ->
                            case r of
                                Err _ ->
                                    Expect.pass

                                Ok _ ->
                                    Expect.fail "Expected failure"
                       )
        ]


roundTripTests : Test
roundTripTests =
    describe "Encode -> Decode round trips"
        [ test "address round-trips" <|
            \_ ->
                case T.address "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd" of
                    Just a ->
                        Encode.address a
                            |> D.decodeValue Decode.address
                            |> (\r ->
                                    case r of
                                        Ok decoded ->
                                            T.addressToString decoded
                                                |> Expect.equal (T.addressToString a)

                                        Err e ->
                                            Expect.fail (D.errorToString e)
                               )

                    Nothing ->
                        Expect.fail "Invalid address"
        , test "uint256 round-trips for 1 ETH in wei" <|
            \_ ->
                case BigInt.fromIntString "1000000000000000000" of
                    Just n ->
                        Encode.uint256 n
                            |> D.decodeValue Decode.uint256
                            |> (\r ->
                                    case r of
                                        Ok decoded ->
                                            BigInt.toString decoded
                                                |> Expect.equal "1000000000000000000"

                                        Err e ->
                                            Expect.fail (D.errorToString e)
                               )

                    Nothing ->
                        Expect.fail "Invalid BigInt"
        , test "uint256 round-trips for zero" <|
            \_ ->
                let
                    n =
                        BigInt.fromInt 0
                in
                Encode.uint256 n
                    |> D.decodeValue Decode.uint256
                    |> (\r ->
                            case r of
                                Ok decoded ->
                                    BigInt.toString decoded |> Expect.equal "0"

                                Err e ->
                                    Expect.fail (D.errorToString e)
                       )
        , test "bool True round-trips" <|
            \_ ->
                Encode.bool True
                    |> D.decodeValue Decode.bool
                    |> Expect.equal (Ok True)
        , test "bool False round-trips" <|
            \_ ->
                Encode.bool False
                    |> D.decodeValue Decode.bool
                    |> Expect.equal (Ok False)
        , test "string round-trips" <|
            \_ ->
                Encode.string "Transfer(address,address,uint256)"
                    |> D.decodeValue Decode.string
                    |> Expect.equal (Ok "Transfer(address,address,uint256)")
        ]
