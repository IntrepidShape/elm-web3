module BigIntHexTest exposing (suite)

{-| Round-trip and edge cases for Web3.BigInt.toHexString.
-}

import Expect
import Test exposing (..)
import Web3.BigInt as B


suite : Test
suite =
    describe "BigInt.toHexString"
        [ test "zero" <|
            \_ -> Expect.equal "0" (B.toHexString B.zero)
        , test "fromInt 0" <|
            \_ -> Expect.equal "0" (B.toHexString (B.fromInt 0))
        , test "fromInt 1" <|
            \_ -> Expect.equal "1" (B.toHexString (B.fromInt 1))
        , test "fromInt 15 -> f" <|
            \_ -> Expect.equal "f" (B.toHexString (B.fromInt 15))
        , test "fromInt 16 -> 10" <|
            \_ -> Expect.equal "10" (B.toHexString (B.fromInt 16))
        , test "fromInt 255 -> ff" <|
            \_ -> Expect.equal "ff" (B.toHexString (B.fromInt 255))
        , test "fromInt 256 -> 100" <|
            \_ -> Expect.equal "100" (B.toHexString (B.fromInt 256))
        , test "fromInt 100 -> 64" <|
            \_ -> Expect.equal "64" (B.toHexString (B.fromInt 100))
        , test "fromInt 65535 -> ffff" <|
            \_ -> Expect.equal "ffff" (B.toHexString (B.fromInt 65535))
        , test "round-trip via fromHexString" <|
            \_ ->
                case B.fromHexString "0xdeadbeef" of
                    Just b ->
                        Expect.equal "deadbeef" (B.toHexString b)

                    Nothing ->
                        Expect.fail "parse failed"
        , test "uint256 max" <|
            \_ ->
                case B.fromHexString "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" of
                    Just b ->
                        Expect.equal (String.repeat 64 "f") (B.toHexString b)

                    Nothing ->
                        Expect.fail "parse failed"
        ]
