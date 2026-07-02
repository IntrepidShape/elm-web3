module AbiDecodeHexTest exposing (suite)

import Expect
import Json.Decode as D
import Test exposing (..)
import Web3.Abi.Decode as Decode
import Web3.BigInt as BigInt
import Web3.Types as T


suite : Test
suite =
    describe "Web3.Abi.Decode — hex slot API"
        [ hexSlotTests
        , realRevertVectorsTest
        , uint256SlotTests
        , addressSlotTests
        , boolSlotTests
        , stringSlotTests
        , listSlotTests
        , tuple2HexTests
        , sizedIntDecoderTests
        , uint256HexDecoderTests
        ]


{-| Build a 64-char hex slot for an integer value.
e.g. slot 100 = "0000000000000000000000000000000000000000000000000000000000000064"
-}
slot : Int -> String
slot n =
    let
        hexN =
            String.fromInt n
                |> hexFromDecimal

        padLen =
            64 - String.length hexN
    in
    String.repeat padLen "0" ++ hexN


{-| Minimal decimal-to-hex for small ints used in tests.
-}
hexFromDecimal : String -> String
hexFromDecimal s =
    case String.toInt s of
        Nothing ->
            "0"

        Just n ->
            if n == 0 then
                "0"

            else
                hexFromDecimal (String.fromInt (n // 16))
                    |> (\prefix ->
                            let
                                digit =
                                    n |> modBy 16
                            in
                            let
                                ch =
                                    if digit < 10 then
                                        String.fromInt digit

                                    else
                                        case digit of
                                            10 -> "a"
                                            11 -> "b"
                                            12 -> "c"
                                            13 -> "d"
                                            14 -> "e"
                                            15 -> "f"
                                            _  -> "0"
                            in
                            if prefix == "0" then ch else prefix ++ ch
                       )


{-| ABI-encoded address slot (12 zero-bytes + 20 address bytes).
address = 0xabcdefabcdefabcdefabcdefabcdefabcdefabcd
-}
addressSlotHex : String
addressSlotHex =
    String.repeat 24 "0" ++ "abcdefabcdefabcdefabcdefabcdefabcdefabcd"


hexSlotTests : Test
hexSlotTests =
    describe "hexSlot"
        [ test "slot 0 of single-slot hex returns 64 chars" <|
            \_ ->
                let
                    s = "0x" ++ slot 100
                in
                Decode.hexSlot 0 s
                    |> String.length
                    |> Expect.equal 64
        , test "slot 0 of single-slot hex has correct value" <|
            \_ ->
                let
                    s = "0x" ++ slot 100
                in
                Decode.hexSlot 0 s
                    |> Expect.equal (slot 100)
        , test "slot 1 from two-slot hex" <|
            \_ ->
                let
                    hex =
                        "0x" ++ slot 0 ++ slot 100
                in
                Decode.hexSlot 1 hex
                    |> Expect.equal (slot 100)
        ]


uint256SlotTests : Test
uint256SlotTests =
    describe "uint256Slot"
        [ test "decodes 100 from slot 0" <|
            \_ ->
                Decode.uint256Slot 0 ("0x" ++ slot 100)
                    |> Expect.equal (Just (BigInt.fromInt 100))
        , test "decodes 0 from slot 0" <|
            \_ ->
                Decode.uint256Slot 0 ("0x" ++ slot 0)
                    |> Expect.equal (Just BigInt.zero)
        , test "decodes 255 from slot 0" <|
            \_ ->
                Decode.uint256Slot 0 ("0x" ++ slot 255)
                    |> Expect.equal (Just (BigInt.fromInt 255))
        ]


addressSlotTests : Test
addressSlotTests =
    describe "addressSlot"
        [ test "decodes address from slot 0" <|
            \_ ->
                Decode.addressSlot 0 ("0x" ++ addressSlotHex)
                    |> Maybe.map T.addressToString
                    |> Expect.equal (Just "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd")
        ]


boolSlotTests : Test
boolSlotTests =
    describe "boolSlot"
        [ test "decodes true (last char = 1)" <|
            \_ ->
                Decode.boolSlot 0 ("0x" ++ slot 1)
                    |> Expect.equal (Just True)
        , test "decodes false (all zeros)" <|
            \_ ->
                Decode.boolSlot 0 ("0x" ++ slot 0)
                    |> Expect.equal (Just False)
        ]


stringSlotTests : Test
stringSlotTests =
    describe "stringSlot"
        [ test "decodes ABI-encoded string 'Hi'" <|
            \_ ->
                -- ABI encoding of string "Hi":
                -- slot 0 = offset word = 0x20 = 32 (points to length word)
                -- slot 1 = length word = 2 (2 bytes)
                -- slot 2 = data "Hi" = 0x4869 left-aligned, right-padded
                let
                    offsetWord =
                        slot 32

                    lenWord =
                        slot 2

                    -- "Hi" = 0x4869, left-aligned in 32-byte word
                    dataWord =
                        "4869" ++ String.repeat 60 "0"

                    hex =
                        "0x" ++ offsetWord ++ lenWord ++ dataWord
                in
                Decode.stringSlot 0 hex
                    |> Expect.equal (Just "Hi")
        , test "decodes empty string" <|
            \_ ->
                -- offset points to length word (32)
                -- length = 0, no data
                let
                    hex =
                        "0x" ++ slot 32 ++ slot 0 ++ String.repeat 64 "0"
                in
                Decode.stringSlot 0 hex
                    |> Expect.equal (Just "")
        ]


listSlotTests : Test
listSlotTests =
    describe "listSlot"
        [ test "decodes uint256[] with two elements [1, 2]" <|
            \_ ->
                -- ABI encoding of [1, 2] as uint256[]:
                -- slot 0 = offset = 0x20 = 32 (array data starts at byte 32)
                -- slot 1 = length = 2
                -- slot 2 = element 0 = 1
                -- slot 3 = element 1 = 2
                let
                    hex =
                        "0x"
                            ++ slot 32
                            ++ slot 2
                            ++ slot 1
                            ++ slot 2
                in
                Decode.listSlot 0 Decode.uint256Slot hex
                    |> Expect.equal
                        (Just
                            [ BigInt.fromInt 1
                            , BigInt.fromInt 2
                            ]
                        )
        , test "decodes empty array" <|
            \_ ->
                let
                    hex =
                        "0x" ++ slot 32 ++ slot 0
                in
                Decode.listSlot 0 Decode.uint256Slot hex
                    |> Expect.equal (Just [])
        ]


tuple2HexTests : Test
tuple2HexTests =
    describe "tuple2Hex"
        [ test "decodes (uint256 100, address)" <|
            \_ ->
                let
                    hex =
                        "0x" ++ slot 100 ++ addressSlotHex
                in
                Decode.tuple2Hex Decode.uint256Slot Decode.addressSlot hex
                    |> (\result ->
                            case result of
                                Just ( n, addr ) ->
                                    Expect.all
                                        [ \_ -> BigInt.toString n |> Expect.equal "100"
                                        , \_ ->
                                            T.addressToString addr
                                                |> Expect.equal "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
                                        ]
                                        ()

                                Nothing ->
                                    Expect.fail "Expected Just (n, addr)"
                       )
        ]


sizedIntDecoderTests : Test
sizedIntDecoderTests =
    describe "sized integer decoders"
        [ test "uint8 decodes 255" <|
            \_ ->
                D.decodeString Decode.uint8 "\"255\""
                    |> Expect.equal (Ok 255)
        , test "uint8 decodes 0" <|
            \_ ->
                D.decodeString Decode.uint8 "\"0\""
                    |> Expect.equal (Ok 0)
        , test "uint8 fails on 256" <|
            \_ ->
                D.decodeString Decode.uint8 "\"256\""
                    |> (\r ->
                            case r of
                                Err _ ->
                                    Expect.pass

                                Ok _ ->
                                    Expect.fail "Expected failure for 256"
                       )
        , test "uint16 decodes 65535" <|
            \_ ->
                D.decodeString Decode.uint16 "\"65535\""
                    |> Expect.equal (Ok 65535)
        , test "uint16 fails on 65536" <|
            \_ ->
                D.decodeString Decode.uint16 "\"65536\""
                    |> (\r ->
                            case r of
                                Err _ ->
                                    Expect.pass

                                Ok _ ->
                                    Expect.fail "Expected failure for 65536"
                       )
        , test "uint32 decodes 4294967295" <|
            \_ ->
                D.decodeString Decode.uint32 "\"4294967295\""
                    |> Expect.equal (Ok 4294967295)
        , test "uint32 fails on 4294967296" <|
            \_ ->
                D.decodeString Decode.uint32 "\"4294967296\""
                    |> (\r ->
                            case r of
                                Err _ ->
                                    Expect.pass

                                Ok _ ->
                                    Expect.fail "Expected failure for 4294967296"
                       )
        , test "uint64 decodes large value" <|
            \_ ->
                D.decodeString Decode.uint64 "\"18446744073709551615\""
                    |> (\r ->
                            case r of
                                Ok n ->
                                    BigInt.toString n |> Expect.equal "18446744073709551615"

                                Err e ->
                                    Expect.fail (D.errorToString e)
                       )
        , test "uint128 decodes large value" <|
            \_ ->
                D.decodeString Decode.uint128 "\"340282366920938463463374607431768211455\""
                    |> (\r ->
                            case r of
                                Ok _ ->
                                    Expect.pass

                                Err e ->
                                    Expect.fail (D.errorToString e)
                       )
        ]


uint256HexDecoderTests : Test
uint256HexDecoderTests =
    describe "uint256 hex string support"
        [ test "uint256 decodes hex string 0x64 as 100" <|
            \_ ->
                D.decodeString Decode.uint256 "\"0x64\""
                    |> (\r ->
                            case r of
                                Ok n ->
                                    BigInt.toString n |> Expect.equal "100"

                                Err e ->
                                    Expect.fail (D.errorToString e)
                       )
        , test "uint256 still decodes decimal string '100'" <|
            \_ ->
                D.decodeString Decode.uint256 "\"100\""
                    |> (\r ->
                            case r of
                                Ok n ->
                                    BigInt.toString n |> Expect.equal "100"

                                Err e ->
                                    Expect.fail (D.errorToString e)
                       )
        , test "uint256 decodes 0xff as 255" <|
            \_ ->
                D.decodeString Decode.uint256 "\"0xff\""
                    |> (\r ->
                            case r of
                                Ok n ->
                                    BigInt.toString n |> Expect.equal "255"

                                Err e ->
                                    Expect.fail (D.errorToString e)
                       )
        ]


{-| REGRESSION — the Error(string) selector is 0x08c379a0 (keccak256 of
"Error(string)" truncated to 4 bytes). The library shipped for months
comparing against 08c379a2 — a typo'd constant that meant NO real on-chain
revert reason ever decoded, while the Lean proofs correctly verified the
wrong constant. These vectors are real-world-canonical: what solc 0.8+
actually returns on `revert("...")`. They must decode, forever.
-}
realRevertVectorsTest : Test
realRevertVectorsTest =
    describe "decodeRevertReason: canonical real-world vectors"
        [ test "solc revert(\"Insufficient funds\") decodes" <|
            \_ ->
                Decode.decodeRevertReason
                    ("0x08c379a0"
                        ++ "0000000000000000000000000000000000000000000000000000000000000020"
                        ++ "0000000000000000000000000000000000000000000000000000000000000012"
                        ++ "496e73756666696369656e742066756e64730000000000000000000000000000"
                    )
                    |> Expect.equal (Just "Insufficient funds")
        , test "solc revert(\"Insufficient balance for this purchase\") decodes" <|
            \_ ->
                Decode.decodeRevertReason
                    ("0x08c379a0"
                        ++ "0000000000000000000000000000000000000000000000000000000000000020"
                        ++ "0000000000000000000000000000000000000000000000000000000000000026"
                        ++ "496e73756666696369656e742062616c616e636520666f722074686973207075"
                        ++ "7263686173650000000000000000000000000000000000000000000000000000"
                    )
                    |> Expect.equal (Just "Insufficient balance for this purchase")
        , test "the old typo'd selector 08c379a2 does NOT decode" <|
            \_ ->
                Decode.decodeRevertReason
                    ("0x08c379a2"
                        ++ "0000000000000000000000000000000000000000000000000000000000000020"
                        ++ "0000000000000000000000000000000000000000000000000000000000000012"
                        ++ "496e73756666696369656e742066756e64730000000000000000000000000000"
                    )
                    |> Expect.equal Nothing
        , test "Panic(uint256) selector 0x4e487b71 does not decode as a string" <|
            \_ ->
                Decode.decodeRevertReason
                    "0x4e487b710000000000000000000000000000000000000000000000000000000000000011"
                    |> Expect.equal Nothing
        ]
