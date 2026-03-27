module UnitsTest exposing (suite)

import Expect
import Fuzz exposing (Fuzzer)
import Test exposing (..)
import Web3.BigInt as BigInt exposing (BigInt)
import Web3.Units as Units


suite : Test
suite =
    describe "Web3.Units"
        [ formatEtherTests
        , parseEtherTests
        , formatUnitsTests
        , parseUnitsTests
        , roundTripTests
        ]


formatEtherTests : Test
formatEtherTests =
    describe "formatEther"
        [ test "zero" <|
            \_ ->
                Units.formatEther BigInt.zero
                    |> Expect.equal "0"
        , test "1 ETH (10^18 wei)" <|
            \_ ->
                BigInt.fromString "1000000000000000000"
                    |> Maybe.map Units.formatEther
                    |> Expect.equal (Just "1")
        , test "1.5 ETH" <|
            \_ ->
                BigInt.fromString "1500000000000000000"
                    |> Maybe.map Units.formatEther
                    |> Expect.equal (Just "1.5")
        , test "0.001 ETH (10^15 wei)" <|
            \_ ->
                BigInt.fromString "1000000000000000"
                    |> Maybe.map Units.formatEther
                    |> Expect.equal (Just "0.001")
        , test "1 wei" <|
            \_ ->
                Units.formatEther (BigInt.fromInt 1)
                    |> Expect.equal "0.000000000000000001"
        , test "trims trailing zeros" <|
            \_ ->
                BigInt.fromString "100000000000000000"
                    |> Maybe.map Units.formatEther
                    |> Expect.equal (Just "0.1")
        , test "large round number" <|
            \_ ->
                BigInt.fromString "1000000000000000000000"
                    |> Maybe.map Units.formatEther
                    |> Expect.equal (Just "1000")
        ]


parseEtherTests : Test
parseEtherTests =
    describe "parseEther"
        [ test "parse '1'" <|
            \_ ->
                Units.parseEther "1"
                    |> Maybe.map BigInt.toString
                    |> Expect.equal (Just "1000000000000000000")
        , test "parse '1.5'" <|
            \_ ->
                Units.parseEther "1.5"
                    |> Maybe.map BigInt.toString
                    |> Expect.equal (Just "1500000000000000000")
        , test "parse '0.000000000000000001' (1 wei)" <|
            \_ ->
                Units.parseEther "0.000000000000000001"
                    |> Expect.equal (Just (BigInt.fromInt 1))
        , test "parse '0'" <|
            \_ ->
                Units.parseEther "0"
                    |> Expect.equal (Just BigInt.zero)
        , test "rejects non-numeric" <|
            \_ ->
                Units.parseEther "not-a-number"
                    |> Expect.equal Nothing
        , test "rejects negative" <|
            \_ ->
                Units.parseEther "-1"
                    |> Expect.equal Nothing
        , test "rejects empty string" <|
            \_ ->
                Units.parseEther ""
                    |> Expect.equal Nothing
        , test "rejects multiple dots" <|
            \_ ->
                Units.parseEther "1.2.3"
                    |> Expect.equal Nothing
        , test "truncates excess decimal places" <|
            \_ ->
                -- 19 decimal places: only first 18 are used
                Units.parseEther "0.1234567890123456789"
                    |> Expect.notEqual Nothing
        ]


formatUnitsTests : Test
formatUnitsTests =
    describe "formatUnits"
        [ test "USDC 6 decimals: 1.5" <|
            \_ ->
                Units.formatUnits 6 (BigInt.fromInt 1500000)
                    |> Expect.equal "1.5"
        , test "USDC 6 decimals: 1" <|
            \_ ->
                Units.formatUnits 6 (BigInt.fromInt 1000000)
                    |> Expect.equal "1"
        , test "USDC 6 decimals: 0" <|
            \_ ->
                Units.formatUnits 6 BigInt.zero
                    |> Expect.equal "0"
        , test "zero decimals returns integer" <|
            \_ ->
                Units.formatUnits 0 (BigInt.fromInt 42)
                    |> Expect.equal "42"
        ]


parseUnitsTests : Test
parseUnitsTests =
    describe "parseUnits"
        [ test "USDC 6 decimals: '1.5'" <|
            \_ ->
                Units.parseUnits 6 "1.5"
                    |> Expect.equal (Just (BigInt.fromInt 1500000))
        , test "USDC 6 decimals: '0'" <|
            \_ ->
                Units.parseUnits 6 "0"
                    |> Expect.equal (Just BigInt.zero)
        , test "rejects negative" <|
            \_ ->
                Units.parseUnits 6 "-1"
                    |> Expect.equal Nothing
        , test "rejects non-numeric" <|
            \_ ->
                Units.parseUnits 6 "abc"
                    |> Expect.equal Nothing
        ]


roundTripTests : Test
roundTripTests =
    describe "round trips"
        [ test "parseEther (formatEther n) == Just n for 1 ETH" <|
            \_ ->
                let
                    n =
                        BigInt.fromString "1000000000000000000" |> Maybe.withDefault BigInt.zero
                in
                Units.parseEther (Units.formatEther n)
                    |> Expect.equal (Just n)
        , test "parseEther (formatEther n) == Just n for 1.5 ETH" <|
            \_ ->
                let
                    n =
                        BigInt.fromString "1500000000000000000" |> Maybe.withDefault BigInt.zero
                in
                Units.parseEther (Units.formatEther n)
                    |> Expect.equal (Just n)
        , test "parseEther (formatEther n) == Just n for 1 wei" <|
            \_ ->
                let
                    n =
                        BigInt.fromInt 1
                in
                Units.parseEther (Units.formatEther n)
                    |> Expect.equal (Just n)
        , fuzz nonNegativeBigIntFuzzer "parseEther (formatEther n) == Just n" <|
            \n ->
                Units.parseEther (Units.formatEther n)
                    |> Expect.equal (Just n)
        ]


{-| Fuzz over small non-negative integers mapped to BigInt.
-}
nonNegativeBigIntFuzzer : Fuzzer BigInt
nonNegativeBigIntFuzzer =
    Fuzz.intRange 0 999999999
        |> Fuzz.map BigInt.fromInt
