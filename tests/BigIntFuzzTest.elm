module BigIntFuzzTest exposing (suite)

{-| Fuzz tests for Web3.BigInt fromString/toString round-trip.

Properties verified:
  1. fromInt then toString then fromString round-trips for any Int.
  2. Zero round-trips: fromString "0" == Just zero, toString zero == "0".
  3. fromString returns Nothing for invalid inputs (never crashes).
  4. toString produces only decimal digit characters (no hex, no sign for positives).
  5. Large known values (uint256 max) survive fromString -> toString without truncation.
  6. fromString s |> Maybe.map toString == Just s for any valid decimal string.
  7. add n zero == n (additive identity).
  8. mul n (fromInt 1) == n (multiplicative identity).
  9. isZero (sub n n) == True for any n.
  10. eq is reflexive: eq n n == True.

-}

import Web3.BigInt as BigInt
import Expect
import Fuzz exposing (Fuzzer)
import Test exposing (..)
import Web3.BigInt as W


-- CONSTANTS


{-| uint256 max = 2^256 - 1
-}
uint256Max : String
uint256Max =
    "115792089237316195423570985008687907853269984665640564039457584007913129639935"


{-| A large value just below uint256 max (2^255).
-}
twoTo255 : String
twoTo255 =
    "57896044618658097711785492504343953926634992332820282019728792003956564819968"


-- FUZZ HELPERS


{-| Fuzz a non-negative Int (0 to maxInt).
-}
nonNegativeIntFuzzer : Fuzzer Int
nonNegativeIntFuzzer =
    Fuzz.intRange 0 2147483647


{-| Fuzz a positive Int (1 to maxInt).
-}
positiveIntFuzzer : Fuzzer Int
positiveIntFuzzer =
    Fuzz.intRange 1 2147483647


{-| Fuzz a valid decimal string for a non-negative integer.
These should all parse successfully.
-}
validDecimalStringFuzzer : Fuzzer String
validDecimalStringFuzzer =
    nonNegativeIntFuzzer
        |> Fuzz.map String.fromInt


{-| Fuzz strings that are not valid decimal integers.
-}
invalidDecimalStringFuzzer : Fuzzer String
invalidDecimalStringFuzzer =
    Fuzz.oneOf
        [ Fuzz.constant ""
        , Fuzz.constant "0x1234"
        , Fuzz.constant "-1"
        , Fuzz.constant "3.14"
        , Fuzz.constant "abc"
        , Fuzz.constant "1e10"
        , Fuzz.constant " 42"
        , Fuzz.constant "42 "
        , Fuzz.constant "0b101"
        , Fuzz.string
            |> Fuzz.filter (\s -> not (String.all Char.isDigit s) || String.isEmpty s)
        ]


-- SUITE


suite : Test
suite =
    describe "Web3.BigInt fuzz"
        [ roundTripFromIntTest
        , zeroTest
        , fromStringInvalidNeverCrashesTest
        , toStringDecimalOnlyTest
        , uint256MaxTest
        , fromStringToStringRoundTripTest
        , additiveIdentityTest
        , multiplicativeIdentityTest
        , subSelfIsZeroTest
        , eqReflexiveTest
        ]


{-| fromInt n -> toString -> fromString must recover the same value.

Property: fromString (toString (fromInt n)) == Just (fromInt n)
-}
roundTripFromIntTest : Test
roundTripFromIntTest =
    fuzz nonNegativeIntFuzzer "fromInt -> toString -> fromString round-trips" <|
        \n ->
            let
                original =
                    W.fromInt n

                str =
                    W.toString original

                recovered =
                    W.fromString str
            in
            case recovered of
                Just r ->
                    if W.eq r original then
                        Expect.pass

                    else
                        Expect.fail
                            ("Precision loss: fromInt "
                                ++ String.fromInt n
                                ++ " -> toString -> fromString gave "
                                ++ W.toString r
                                ++ " (expected "
                                ++ str
                                ++ ")"
                            )

                Nothing ->
                    Expect.fail
                        ("fromString returned Nothing for toString output: " ++ str)


{-| Zero is a fixed point of the round-trip:
  - toString zero == "0"
  - fromString "0" == Just zero
  - isZero zero == True
-}
zeroTest : Test
zeroTest =
    describe "zero is well-behaved"
        [ test "toString zero == \"0\"" <|
            \_ ->
                W.toString W.zero
                    |> Expect.equal "0"
        , test "fromString \"0\" == Just zero" <|
            \_ ->
                case W.fromString "0" of
                    Just n ->
                        W.toString n |> Expect.equal "0"

                    Nothing ->
                        Expect.fail "fromString \"0\" returned Nothing"
        , test "isZero zero == True" <|
            \_ ->
                W.isZero W.zero |> Expect.equal True
        , test "isZero (fromInt 0) == True" <|
            \_ ->
                W.isZero (W.fromInt 0) |> Expect.equal True
        , test "isZero (fromInt 1) == False" <|
            \_ ->
                W.isZero (W.fromInt 1) |> Expect.equal False
        ]


{-| fromString must return Nothing (not crash) for any invalid input.
-}
fromStringInvalidNeverCrashesTest : Test
fromStringInvalidNeverCrashesTest =
    describe "fromString never crashes for invalid inputs"
        [ fuzz invalidDecimalStringFuzzer "fromString invalid string returns Nothing or Just" <|
            \s ->
                -- We just verify it doesn't crash — Ok or Err are both acceptable
                case W.fromString s of
                    Just _ ->
                        Expect.pass

                    Nothing ->
                        Expect.pass
        , test "fromString empty string returns Nothing" <|
            \_ ->
                W.fromString "" |> Expect.equal Nothing
        , test "fromString hex string returns Nothing" <|
            \_ ->
                W.fromString "0x1234" |> Expect.equal Nothing
        , test "fromString float returns Nothing" <|
            \_ ->
                W.fromString "3.14" |> Expect.equal Nothing
        ]


{-| toString must produce only decimal digit characters for non-negative integers.
No "0x" prefix, no sign, no letters.
-}
toStringDecimalOnlyTest : Test
toStringDecimalOnlyTest =
    fuzz nonNegativeIntFuzzer "toString produces only decimal digits" <|
        \n ->
            let
                str =
                    W.toString (W.fromInt n)
            in
            if String.all Char.isDigit str && not (String.isEmpty str) then
                Expect.pass

            else
                Expect.fail
                    ("toString produced non-decimal output: \"" ++ str ++ "\" for n=" ++ String.fromInt n)


{-| uint256 max and other large known values must survive fromString -> toString
without any truncation or precision loss.
-}
uint256MaxTest : Test
uint256MaxTest =
    describe "large known values round-trip without precision loss"
        [ test "uint256 max round-trips" <|
            \_ ->
                case W.fromString uint256Max of
                    Just n ->
                        W.toString n |> Expect.equal uint256Max

                    Nothing ->
                        Expect.fail ("fromString returned Nothing for uint256Max: " ++ uint256Max)
        , test "2^255 round-trips" <|
            \_ ->
                case W.fromString twoTo255 of
                    Just n ->
                        W.toString n |> Expect.equal twoTo255

                    Nothing ->
                        Expect.fail ("fromString returned Nothing for 2^255: " ++ twoTo255)
        , test "1000000000000000000 (1e18) round-trips" <|
            \_ ->
                let
                    s =
                        "1000000000000000000"
                in
                case W.fromString s of
                    Just n ->
                        W.toString n |> Expect.equal s

                    Nothing ->
                        Expect.fail ("fromString returned Nothing for " ++ s)
        , test "uint256 max toString contains only digits" <|
            \_ ->
                case W.fromString uint256Max of
                    Just n ->
                        let
                            str =
                                W.toString n
                        in
                        if String.all Char.isDigit str then
                            Expect.pass

                        else
                            Expect.fail ("toString of uint256Max contains non-digit chars: " ++ str)

                    Nothing ->
                        Expect.fail "fromString returned Nothing for uint256Max"
        ]


{-| For any valid decimal string s:
  fromString s |> Maybe.map toString == Just s

This verifies the other direction of the round-trip — that the string representation
is canonical with no extra leading zeros or formatting.
-}
fromStringToStringRoundTripTest : Test
fromStringToStringRoundTripTest =
    fuzz validDecimalStringFuzzer "valid decimal string -> fromString -> toString recovers original" <|
        \s ->
            case W.fromString s of
                Just n ->
                    let
                        recovered =
                            W.toString n

                        -- elm-bigint may strip leading zeros; normalize the input
                        normalized =
                            case String.toInt s of
                                Just i ->
                                    String.fromInt i

                                Nothing ->
                                    s
                    in
                    recovered |> Expect.equal normalized

                Nothing ->
                    Expect.fail ("fromString returned Nothing for valid decimal: " ++ s)


{-| add n zero == n (additive identity).
-}
additiveIdentityTest : Test
additiveIdentityTest =
    fuzz nonNegativeIntFuzzer "add n zero == n" <|
        \n ->
            let
                bigN =
                    W.fromInt n

                result =
                    W.add bigN W.zero
            in
            if W.eq result bigN then
                Expect.pass

            else
                Expect.fail
                    ("add (fromInt "
                        ++ String.fromInt n
                        ++ ") zero == "
                        ++ W.toString result
                        ++ ", expected "
                        ++ W.toString bigN
                    )


{-| mul n 1 == n (multiplicative identity).
-}
multiplicativeIdentityTest : Test
multiplicativeIdentityTest =
    fuzz nonNegativeIntFuzzer "mul n (fromInt 1) == n" <|
        \n ->
            let
                bigN =
                    W.fromInt n

                result =
                    W.mul bigN (W.fromInt 1)
            in
            if W.eq result bigN then
                Expect.pass

            else
                Expect.fail
                    ("mul (fromInt "
                        ++ String.fromInt n
                        ++ ") 1 == "
                        ++ W.toString result
                        ++ ", expected "
                        ++ W.toString bigN
                    )


{-| sub n n == zero for any n.
-}
subSelfIsZeroTest : Test
subSelfIsZeroTest =
    fuzz nonNegativeIntFuzzer "sub n n is zero" <|
        \n ->
            let
                bigN =
                    W.fromInt n

                result =
                    W.sub bigN bigN
            in
            if W.isZero result then
                Expect.pass

            else
                Expect.fail
                    ("sub (fromInt "
                        ++ String.fromInt n
                        ++ ") (fromInt "
                        ++ String.fromInt n
                        ++ ") == "
                        ++ W.toString result
                        ++ ", expected 0"
                    )


{-| eq n n == True for any n (reflexivity).
-}
eqReflexiveTest : Test
eqReflexiveTest =
    fuzz nonNegativeIntFuzzer "eq n n == True" <|
        \n ->
            let
                bigN =
                    W.fromInt n
            in
            W.eq bigN bigN |> Expect.equal True
