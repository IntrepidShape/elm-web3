module UnitsFuzzTest exposing (suite)

{-| General round-trip / exactness fuzz tests for Web3.Units.

`UnitsTest` fuzzes only `parseEther ∘ formatEther` at 18 decimals over values
below 10^9 (sub-gwei). That misses the two things that actually matter for token
accounting (backlog #4 — "wei/gwei/ether conversions are exact and round-trip"):

  - **Arbitrary decimals.** Real tokens are not all 18 decimals (USDC = 6,
    WBTC = 8, some tokens 0). The general `formatUnits` / `parseUnits` path is
    never fuzzed.
  - **uint256-scale values.** Real balances are ~10^18 and up, far past `Int`
    range, exercising multi-limb BigInt division/formatting.

Properties:

1.  `parseUnits d (formatUnits d n) == Just n` for any decimals `d ∈ [0,30]`
    and any non-negative multi-limb `n` — exact, no precision loss.
2.  `formatEther` / `parseEther` are exactly the `decimals = 18` case of the
    general functions (the two code paths agree).
3.  `parseEther (formatEther n) == Just n` at ether scale (multi-limb), not just
    sub-gwei.
4.  Fractional digits beyond `d` are truncated, not rounded or errored: given a
    string whose fraction already has exactly `d` digits, appending more digits
    leaves the parsed value unchanged.

-}

import Expect
import Fuzz exposing (Fuzzer)
import Test exposing (..)
import Web3.BigInt as B exposing (BigInt)
import Web3.Units as Units


suite : Test
suite =
    describe "Web3.Units fuzz"
        [ generalRoundTripTest
        , etherConsistencyTest
        , etherScaleRoundTripTest
        , truncationTest
        ]



-- FUZZERS


{-| Non-negative multi-limb BigInt (1–8 base-10^9 limbs → up to ~10^72), built
through the public API so values reach well past `Int` range and uint256 scale.
-}
bigIntFuzzer : Fuzzer BigInt
bigIntFuzzer =
    Fuzz.listOfLengthBetween 1 8 (Fuzz.intRange 0 999999999)
        |> Fuzz.map
            (List.foldl
                (\limb acc -> B.add (B.mul acc (B.fromInt 1000000000)) (B.fromInt limb))
                B.zero
            )


{-| Token decimal counts from 0 (integer tokens) through 30.
-}
decimalsFuzzer : Fuzzer Int
decimalsFuzzer =
    Fuzz.intRange 0 30


{-| A string of decimal digits, length 0–40.
-}
digitsFuzzer : Fuzzer String
digitsFuzzer =
    Fuzz.list (Fuzz.intRange 0 9 |> Fuzz.map String.fromInt)
        |> Fuzz.map String.concat



-- TESTS


generalRoundTripTest : Test
generalRoundTripTest =
    fuzz2 decimalsFuzzer bigIntFuzzer "parseUnits d (formatUnits d n) == Just n" <|
        \d n ->
            Units.parseUnits d (Units.formatUnits d n)
                |> Expect.equal (Just n)


etherConsistencyTest : Test
etherConsistencyTest =
    describe "ether functions == decimals=18 general functions"
        [ fuzz bigIntFuzzer "formatEther n == formatUnits 18 n" <|
            \n ->
                Units.formatEther n
                    |> Expect.equal (Units.formatUnits 18 n)
        , fuzz bigIntFuzzer "parseEther (formatEther n) == parseUnits 18 (formatEther n)" <|
            \n ->
                let
                    s =
                        Units.formatEther n
                in
                Units.parseEther s
                    |> Expect.equal (Units.parseUnits 18 s)
        ]


etherScaleRoundTripTest : Test
etherScaleRoundTripTest =
    fuzz bigIntFuzzer "parseEther (formatEther n) == Just n at ether scale (multi-limb)" <|
        \n ->
            Units.parseEther (Units.formatEther n)
                |> Expect.equal (Just n)


truncationTest : Test
truncationTest =
    fuzz3 (Fuzz.intRange 1 30) digitsFuzzer digitsFuzzer "digits past d are ignored (exactly-d fraction + extra == fraction)" <|
        \d rawFrac extra ->
            let
                -- A fractional part of exactly d digits.
                fracD =
                    String.left d (rawFrac ++ String.repeat d "0")

                base =
                    "0." ++ fracD
            in
            Units.parseUnits d (base ++ extra)
                |> Expect.equal (Units.parseUnits d base)
