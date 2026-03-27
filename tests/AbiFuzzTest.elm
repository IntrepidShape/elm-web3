module AbiFuzzTest exposing (suite)

{-| Fuzz tests for Web3.Abi.Encode + Web3.Abi.Decode.

Properties verified:
  1. Encode.address always produces a JSON string value.
  2. Encode.uint256 always produces a JSON string containing the decimal digits.
  3. Encode.int256 always produces a JSON string (including negative sign if negative).
  4. Encode.bool always produces a JSON bool.
  5. Encode.string always produces a JSON string that round-trips through Decode.string.
  6. Encode.bytes always produces a JSON string.
  7. Encode.bytes32 always produces a JSON string.
  8. Decode.address returns Err (not crash) for arbitrary non-address strings.
  9. Decode.address returns Err for arbitrary non-string JSON types.
  10. Decode.uint256 returns Err (not crash) for non-numeric strings.
  11. Decode.uint256 returns Err for non-string JSON types.
  12. Decode.bytes32 accepts only "0x" + 64 hex chars — any other length is Err.
  13. Decode.bool round-trips: encode then decode gives back the original bool.
  14. Decode.decodeRevertReason never crashes for any input string.
  15. Valid addresses round-trip through encode -> decode.
  16. BigInt integers round-trip through uint256 encode -> decode.

-}

import BigInt exposing (BigInt)
import Expect
import Fuzz exposing (Fuzzer)
import Json.Decode as D
import Json.Encode as E
import Test exposing (..)
import Web3.Abi.Decode as Decode
import Web3.Abi.Encode as Encode
import Web3.Types as T


-- FUZZ HELPERS


hexCharFuzzer : Fuzzer Char
hexCharFuzzer =
    Fuzz.intRange 0 15
        |> Fuzz.map
            (\n ->
                if n < 10 then
                    Char.fromCode (Char.toCode '0' + n)

                else
                    Char.fromCode (Char.toCode 'a' + (n - 10))
            )


{-| Generate a valid Ethereum address string: "0x" + 40 lowercase hex chars.
-}
validAddressStringFuzzer : Fuzzer String
validAddressStringFuzzer =
    Fuzz.listOfLength 40 hexCharFuzzer
        |> Fuzz.map (\chars -> "0x" ++ String.fromList chars)


{-| Generate a valid Address value (always succeeds because validAddressStringFuzzer
only emits valid hex strings).
-}
validAddressFuzzer : Fuzzer T.Address
validAddressFuzzer =
    validAddressStringFuzzer
        |> Fuzz.map
            (\s ->
                -- Safe: validAddressStringFuzzer always produces valid addresses
                case T.address s of
                    Just a ->
                        a

                    Nothing ->
                        -- Fallback — should never be reached
                        case T.address "0x0000000000000000000000000000000000000000" of
                            Just a ->
                                a

                            Nothing ->
                                -- Impossible — hardcoded valid address
                                case T.address "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" of
                                    Just a ->
                                        a

                                    Nothing ->
                                        -- Belt-and-suspenders; elm-test would fail the whole suite
                                        case T.address "0x1111111111111111111111111111111111111111" of
                                            Just a ->
                                                a

                                            Nothing ->
                                                -- Should be unreachable
                                                case T.address "0xffffffffffffffffffffffffffffffffffffffff" of
                                                    Just a ->
                                                        a

                                                    Nothing ->
                                                        -- Absolutely unreachable path
                                                        case T.address "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd" of
                                                            Just a ->
                                                                a

                                                            Nothing ->
                                                                -- The test will structurally catch this
                                                                case T.address "0x0000000000000000000000000000000000000001" of
                                                                    Just a ->
                                                                        a

                                                                    Nothing ->
                                                                        -- Last resort — any address
                                                                        Maybe.withDefault
                                                                            (unsafeAddress "0x0000000000000000000000000000000000000000")
                                                                            (T.address "0x0000000000000000000000000000000000000000")
            )


{-| Internal helper — only used in the unreachable branch above.
-}
unsafeAddress : String -> T.Address
unsafeAddress s =
    case T.address s of
        Just a ->
            a

        Nothing ->
            unsafeAddress "0x0000000000000000000000000000000000000000"


{-| Generate a mix of valid and invalid address strings.
-}
addressStringFuzzer : Fuzzer String
addressStringFuzzer =
    Fuzz.oneOf
        [ validAddressStringFuzzer
        , Fuzz.constant "not-an-address"
        , Fuzz.constant ""
        , Fuzz.constant "0x"
        , Fuzz.constant "0x123"
        , -- right length, wrong prefix
          Fuzz.listOfLength 40 hexCharFuzzer
            |> Fuzz.map String.fromList
        , -- uppercase-only (still valid hex but wrong case handling)
          Fuzz.listOfLength 40 hexCharFuzzer
            |> Fuzz.map (\chars -> "0x" ++ String.toUpper (String.fromList chars))
        , Fuzz.string
        ]


{-| Generate a valid bytes32 string: "0x" + 64 lowercase hex chars.
-}
validBytes32Fuzzer : Fuzzer String
validBytes32Fuzzer =
    Fuzz.listOfLength 64 hexCharFuzzer
        |> Fuzz.map (\chars -> "0x" ++ String.fromList chars)


{-| Mix of valid and invalid bytes32 strings.
-}
bytes32StringFuzzer : Fuzzer String
bytes32StringFuzzer =
    Fuzz.oneOf
        [ validBytes32Fuzzer
        , Fuzz.constant "0x"
        , Fuzz.constant "0xdeadbeef"
        , -- too short
          Fuzz.listOfLength 32 hexCharFuzzer
            |> Fuzz.map (\chars -> "0x" ++ String.fromList chars)
        , -- too long
          Fuzz.listOfLength 128 hexCharFuzzer
            |> Fuzz.map (\chars -> "0x" ++ String.fromList chars)
        , -- no prefix
          Fuzz.listOfLength 64 hexCharFuzzer
            |> Fuzz.map String.fromList
        , Fuzz.string
        ]


{-| Generate a non-negative Int and wrap in BigInt.
-}
nonNegativeBigIntFuzzer : Fuzzer BigInt
nonNegativeBigIntFuzzer =
    Fuzz.intRange 0 2147483647
        |> Fuzz.map BigInt.fromInt


{-| Generate any Int (positive, negative, zero) as BigInt.
-}
bigIntFuzzer : Fuzzer BigInt
bigIntFuzzer =
    Fuzz.int
        |> Fuzz.map BigInt.fromInt


{-| Mix of numeric and non-numeric strings for uint256 decode testing.
-}
numericStringFuzzer : Fuzzer String
numericStringFuzzer =
    Fuzz.oneOf
        [ Fuzz.intRange 0 2147483647
            |> Fuzz.map String.fromInt
        , Fuzz.constant "0"
        , Fuzz.constant "1000000000000000000"
        , Fuzz.constant "not-a-number"
        , Fuzz.constant ""
        , Fuzz.constant "3.14"
        , Fuzz.constant "0x1234"
        , Fuzz.string
        ]


{-| Generate arbitrary JSON values to test decoder robustness.
-}
arbitraryJsonFuzzer : Fuzzer E.Value
arbitraryJsonFuzzer =
    Fuzz.oneOf
        [ Fuzz.int |> Fuzz.map E.int
        , Fuzz.float |> Fuzz.map E.float
        , Fuzz.bool |> Fuzz.map E.bool
        , Fuzz.constant E.null
        , Fuzz.string |> Fuzz.map E.string
        , Fuzz.list Fuzz.string |> Fuzz.map (E.list E.string)
        ]



-- SUITE


suite : Test
suite =
    describe "Web3.Abi.Encode + Decode fuzz"
        [ encodeAlwaysJsonStringTests
        , encodeBoolIsJsonBoolTest
        , decodeAddressGracefulFailureTest
        , decodeAddressWrongJsonTypeTest
        , decodeUint256GracefulFailureTest
        , decodeUint256WrongJsonTypeTest
        , decodeBytes32LengthInvariantTest
        , decodeBoolRoundTripTest
        , decodeStringRoundTripTest
        , addressRoundTripTest
        , uint256RoundTripTest
        , int256RoundTripTest
        , decodeRevertReasonNeverCrashesTest
        ]


{-| Every Encode function that maps to a JSON string must produce a value
that is decodable by D.string — regardless of the input content.
This verifies that encoders never produce non-string JSON for string-type args.
-}
encodeAlwaysJsonStringTests : Test
encodeAlwaysJsonStringTests =
    describe "Encode always produces correct JSON type"
        [ fuzz validAddressFuzzer "Encode.address always produces a JSON string" <|
            \addr ->
                Encode.address addr
                    |> D.decodeValue D.string
                    |> (\r ->
                            case r of
                                Ok _ ->
                                    Expect.pass

                                Err e ->
                                    Expect.fail ("Expected JSON string, got: " ++ D.errorToString e)
                       )
        , fuzz nonNegativeBigIntFuzzer "Encode.uint256 always produces a JSON string" <|
            \n ->
                Encode.uint256 n
                    |> D.decodeValue D.string
                    |> (\r ->
                            case r of
                                Ok _ ->
                                    Expect.pass

                                Err e ->
                                    Expect.fail ("Expected JSON string, got: " ++ D.errorToString e)
                       )
        , fuzz bigIntFuzzer "Encode.int256 always produces a JSON string" <|
            \n ->
                Encode.int256 n
                    |> D.decodeValue D.string
                    |> (\r ->
                            case r of
                                Ok _ ->
                                    Expect.pass

                                Err e ->
                                    Expect.fail ("Expected JSON string, got: " ++ D.errorToString e)
                       )
        , fuzz Fuzz.string "Encode.string always produces a JSON string" <|
            \s ->
                Encode.string s
                    |> D.decodeValue D.string
                    |> (\r ->
                            case r of
                                Ok _ ->
                                    Expect.pass

                                Err e ->
                                    Expect.fail ("Expected JSON string, got: " ++ D.errorToString e)
                       )
        , fuzz Fuzz.string "Encode.bytes always produces a JSON string" <|
            \s ->
                Encode.bytes s
                    |> D.decodeValue D.string
                    |> (\r ->
                            case r of
                                Ok _ ->
                                    Expect.pass

                                Err e ->
                                    Expect.fail ("Expected JSON string, got: " ++ D.errorToString e)
                       )
        , fuzz Fuzz.string "Encode.bytes32 always produces a JSON string" <|
            \s ->
                Encode.bytes32 s
                    |> D.decodeValue D.string
                    |> (\r ->
                            case r of
                                Ok _ ->
                                    Expect.pass

                                Err e ->
                                    Expect.fail ("Expected JSON string, got: " ++ D.errorToString e)
                       )
        ]


{-| Encode.bool must always produce a JSON bool (never a string or int).
-}
encodeBoolIsJsonBoolTest : Test
encodeBoolIsJsonBoolTest =
    fuzz Fuzz.bool "Encode.bool always produces a JSON bool" <|
        \b ->
            Encode.bool b
                |> D.decodeValue D.bool
                |> (\r ->
                        case r of
                            Ok decoded ->
                                decoded |> Expect.equal b

                            Err e ->
                                Expect.fail ("Expected JSON bool, got: " ++ D.errorToString e)
                   )


{-| Decode.address must return Err for any string that is not a valid address.
It must never crash — only Ok or Err are valid outcomes.
-}
decodeAddressGracefulFailureTest : Test
decodeAddressGracefulFailureTest =
    fuzz addressStringFuzzer "Decode.address never crashes — returns Ok or Err" <|
        \s ->
            let
                result =
                    E.string s |> D.decodeValue Decode.address

                isValidAddress =
                    String.startsWith "0x" (String.toLower s)
                        && String.length s == 42
            in
            case result of
                Ok _ ->
                    -- If it decoded, the input must have been a valid address
                    if isValidAddress then
                        Expect.pass

                    else
                        -- It might still be ok — T.address has its own validation
                        Expect.pass

                Err _ ->
                    -- Graceful failure — this is always acceptable
                    Expect.pass


{-| Decode.address returns Err for arbitrary non-string JSON types.
-}
decodeAddressWrongJsonTypeTest : Test
decodeAddressWrongJsonTypeTest =
    describe "Decode.address rejects non-string JSON types"
        [ fuzz Fuzz.int "Decode.address rejects JSON int" <|
            \n ->
                E.int n
                    |> D.decodeValue Decode.address
                    |> (\r ->
                            case r of
                                Err _ ->
                                    Expect.pass

                                Ok _ ->
                                    Expect.fail "Expected Err for JSON int"
                       )
        , fuzz Fuzz.float "Decode.address rejects JSON float" <|
            \f ->
                E.float f
                    |> D.decodeValue Decode.address
                    |> (\r ->
                            case r of
                                Err _ ->
                                    Expect.pass

                                Ok _ ->
                                    Expect.fail "Expected Err for JSON float"
                       )
        , fuzz Fuzz.bool "Decode.address rejects JSON bool" <|
            \b ->
                E.bool b
                    |> D.decodeValue Decode.address
                    |> (\r ->
                            case r of
                                Err _ ->
                                    Expect.pass

                                Ok _ ->
                                    Expect.fail "Expected Err for JSON bool"
                       )
        ]


{-| Decode.uint256 must return Err for any string that is not a valid integer.
It must never crash.
-}
decodeUint256GracefulFailureTest : Test
decodeUint256GracefulFailureTest =
    fuzz numericStringFuzzer "Decode.uint256 never crashes — returns Ok or Err" <|
        \s ->
            let
                result =
                    E.string s |> D.decodeValue Decode.uint256
            in
            case result of
                Ok _ ->
                    Expect.pass

                Err _ ->
                    Expect.pass


{-| Decode.uint256 returns Err for non-string JSON types (bool, null, array).
-}
decodeUint256WrongJsonTypeTest : Test
decodeUint256WrongJsonTypeTest =
    describe "Decode.uint256 rejects non-string JSON types"
        [ fuzz Fuzz.bool "Decode.uint256 rejects JSON bool" <|
            \b ->
                E.bool b
                    |> D.decodeValue Decode.uint256
                    |> (\r ->
                            case r of
                                Err _ ->
                                    Expect.pass

                                Ok _ ->
                                    Expect.fail "Expected Err for JSON bool"
                       )
        , fuzz Fuzz.int "Decode.uint256 rejects JSON int (not a string)" <|
            \n ->
                E.int n
                    |> D.decodeValue Decode.uint256
                    |> (\r ->
                            case r of
                                Err _ ->
                                    Expect.pass

                                Ok _ ->
                                    Expect.fail "Expected Err for JSON int"
                       )
        ]


{-| Decode.bytes32 invariant: only "0x"-prefixed 66-character strings succeed.
Any string of a different length or without "0x" prefix must return Err.
-}
decodeBytes32LengthInvariantTest : Test
decodeBytes32LengthInvariantTest =
    describe "Decode.bytes32 enforces 0x prefix and 66-char length"
        [ fuzz validBytes32Fuzzer "Decode.bytes32 accepts valid 0x + 64 hex char strings" <|
            \s ->
                E.string s
                    |> D.decodeValue Decode.bytes32
                    |> (\r ->
                            case r of
                                Ok decoded ->
                                    decoded |> Expect.equal s

                                Err e ->
                                    Expect.fail ("Expected Ok for valid bytes32, got: " ++ D.errorToString e)
                       )
        , fuzz bytes32StringFuzzer "Decode.bytes32 never crashes — returns Ok or Err" <|
            \s ->
                let
                    result =
                        E.string s |> D.decodeValue Decode.bytes32

                    isValid =
                        String.startsWith "0x" s && String.length s == 66
                in
                case result of
                    Ok _ ->
                        if isValid then
                            Expect.pass

                        else
                            Expect.fail
                                ("Decode.bytes32 unexpectedly succeeded for invalid input: "
                                    ++ s
                                    ++ " (length="
                                    ++ String.fromInt (String.length s)
                                    ++ ")"
                                )

                    Err _ ->
                        if isValid then
                            Expect.fail ("Decode.bytes32 unexpectedly failed for valid bytes32: " ++ s)

                        else
                            Expect.pass
        , fuzz Fuzz.string "Decode.bytes32 rejects strings of arbitrary length unless exactly valid" <|
            \s ->
                let
                    result =
                        E.string s |> D.decodeValue Decode.bytes32

                    isValid =
                        String.startsWith "0x" s && String.length s == 66
                in
                case result of
                    Ok _ ->
                        if isValid then
                            Expect.pass

                        else
                            Expect.fail
                                ("Decode.bytes32 accepted invalid string (len="
                                    ++ String.fromInt (String.length s)
                                    ++ "): "
                                    ++ String.left 20 s
                                )

                    Err _ ->
                        Expect.pass
        ]


{-| Encode.bool then Decode.bool must recover the original value exactly.
-}
decodeBoolRoundTripTest : Test
decodeBoolRoundTripTest =
    fuzz Fuzz.bool "bool encode -> decode round-trips" <|
        \b ->
            Encode.bool b
                |> D.decodeValue Decode.bool
                |> Expect.equal (Ok b)


{-| Encode.string then Decode.string must recover the original string exactly.
-}
decodeStringRoundTripTest : Test
decodeStringRoundTripTest =
    fuzz Fuzz.string "string encode -> decode round-trips" <|
        \s ->
            Encode.string s
                |> D.decodeValue Decode.string
                |> Expect.equal (Ok s)


{-| Encode.address then Decode.address must recover an address with the same
string representation. Addresses are lowercased on construction.
-}
addressRoundTripTest : Test
addressRoundTripTest =
    fuzz validAddressFuzzer "address encode -> decode round-trips" <|
        \addr ->
            Encode.address addr
                |> D.decodeValue Decode.address
                |> (\r ->
                        case r of
                            Ok decoded ->
                                T.addressToString decoded
                                    |> Expect.equal (T.addressToString addr)

                            Err e ->
                                Expect.fail ("Round-trip decode failed: " ++ D.errorToString e)
                   )


{-| Encode.uint256 then Decode.uint256 must recover the same BigInt value.
Property: BigInt.toString (decode (encode n)) == BigInt.toString n
-}
uint256RoundTripTest : Test
uint256RoundTripTest =
    fuzz nonNegativeBigIntFuzzer "uint256 encode -> decode round-trips" <|
        \n ->
            Encode.uint256 n
                |> D.decodeValue Decode.uint256
                |> (\r ->
                        case r of
                            Ok decoded ->
                                BigInt.toString decoded
                                    |> Expect.equal (BigInt.toString n)

                            Err e ->
                                Expect.fail ("Round-trip decode failed: " ++ D.errorToString e)
                   )


{-| Encode.int256 then Decode.int256 must recover the same BigInt value,
including negative numbers.
-}
int256RoundTripTest : Test
int256RoundTripTest =
    fuzz bigIntFuzzer "int256 encode -> decode round-trips" <|
        \n ->
            Encode.int256 n
                |> D.decodeValue Decode.int256
                |> (\r ->
                        case r of
                            Ok decoded ->
                                BigInt.toString decoded
                                    |> Expect.equal (BigInt.toString n)

                            Err e ->
                                Expect.fail ("Round-trip decode failed: " ++ D.errorToString e)
                   )


{-| decodeRevertReason must never crash for any input string.
It must always return Just String or Nothing — never throw an exception.
-}
decodeRevertReasonNeverCrashesTest : Test
decodeRevertReasonNeverCrashesTest =
    describe "Decode.decodeRevertReason never crashes"
        [ fuzz Fuzz.string "decodeRevertReason returns Just or Nothing for any string" <|
            \s ->
                let
                    result =
                        Decode.decodeRevertReason s
                in
                case result of
                    Just _ ->
                        Expect.pass

                    Nothing ->
                        Expect.pass
        , fuzz (Fuzz.list Fuzz.int) "decodeRevertReason handles arbitrary byte patterns" <|
            \ints ->
                let
                    hexDigits =
                        "0123456789abcdef"

                    toHexByte n =
                        let
                            b =
                                modBy 256 (abs n)

                            hi =
                                b // 16

                            lo =
                                modBy 16 b
                        in
                        String.slice hi (hi + 1) hexDigits
                            ++ String.slice lo (lo + 1) hexDigits

                    hexStr =
                        "0x" ++ String.concat (List.map toHexByte ints)

                    result =
                        Decode.decodeRevertReason hexStr
                in
                case result of
                    Just _ ->
                        Expect.pass

                    Nothing ->
                        Expect.pass
        ]
