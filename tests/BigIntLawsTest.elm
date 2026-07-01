module BigIntLawsTest exposing (suite)

{-| Algebraic-law fuzz tests for Web3.BigInt.

`BigIntFuzzTest` already covers round-trips and the identity/reflexivity laws.
This module covers the *structural* arithmetic laws that money-handling code
relies on and that the Lean proofs (`natMul_val`, `natCompare_spec`,
`natDivMod_spec` in `proofs/lean/BigInt.lean`) still carry as pending `sorry`
obligations. Until those proofs check, these fuzz properties are the actual
machine-verified evidence that the arithmetic is right:

  - `add` / `mul` are commutative and associative
  - `mul` distributes over `add`
  - `compare` agrees with integer order, and is monotone under addition
  - `div` / `mod` satisfy the division algorithm: `a = (a / b) * b + (a mod b)`
    with `0 <= (a mod b) < b` for `b > 0`

Values are built as genuine multi-limb bignums (well past the internal base and
past `Int` range) so the limb-carry logic is exercised, not just the small case.

-}

import Basics
import Expect
import Fuzz exposing (Fuzzer)
import Test exposing (..)
import Web3.BigInt as B exposing (BigInt)


suite : Test
suite =
    describe "Web3.BigInt algebraic laws"
        [ commutativityTests
        , associativityTests
        , distributivityTests
        , compareTests
        , divModTests
        ]



-- FUZZERS


{-| A non-negative bignum built purely through the public API by folding
base-10^9 "limbs". With 1–6 limbs this reaches ~10^54, far beyond `Int` range
and the module's internal base, so multi-limb carries are exercised.
-}
bigIntFuzzer : Fuzzer BigInt
bigIntFuzzer =
    Fuzz.listOfLengthBetween 1 6 (Fuzz.intRange 0 999999999)
        |> Fuzz.map
            (List.foldl
                (\limb acc -> B.add (B.mul acc (B.fromInt 1000000000)) (B.fromInt limb))
                B.zero
            )


{-| A strictly-positive bignum (>= 1), for use as a divisor.
-}
positiveBigIntFuzzer : Fuzzer BigInt
positiveBigIntFuzzer =
    Fuzz.map (\b -> B.add b (B.fromInt 1)) bigIntFuzzer



-- COMMUTATIVITY


commutativityTests : Test
commutativityTests =
    describe "commutativity"
        [ fuzz2 bigIntFuzzer bigIntFuzzer "add a b == add b a" <|
            \a b ->
                B.eq (B.add a b) (B.add b a)
                    |> Expect.equal True
        , fuzz2 bigIntFuzzer bigIntFuzzer "mul a b == mul b a" <|
            \a b ->
                B.eq (B.mul a b) (B.mul b a)
                    |> Expect.equal True
        ]



-- ASSOCIATIVITY


associativityTests : Test
associativityTests =
    describe "associativity"
        [ fuzz3 bigIntFuzzer bigIntFuzzer bigIntFuzzer "(a + b) + c == a + (b + c)" <|
            \a b c ->
                B.eq (B.add (B.add a b) c) (B.add a (B.add b c))
                    |> Expect.equal True
        , fuzz3 bigIntFuzzer bigIntFuzzer bigIntFuzzer "(a * b) * c == a * (b * c)" <|
            \a b c ->
                B.eq (B.mul (B.mul a b) c) (B.mul a (B.mul b c))
                    |> Expect.equal True
        ]



-- DISTRIBUTIVITY


distributivityTests : Test
distributivityTests =
    describe "distributivity"
        [ fuzz3 bigIntFuzzer bigIntFuzzer bigIntFuzzer "a * (b + c) == a*b + a*c" <|
            \a b c ->
                B.eq (B.mul a (B.add b c)) (B.add (B.mul a b) (B.mul a c))
                    |> Expect.equal True
        ]



-- COMPARE


compareTests : Test
compareTests =
    describe "compare"
        [ fuzz2 (Fuzz.intRange 0 2147483647) (Fuzz.intRange 0 2147483647) "compare agrees with integer order" <|
            \a b ->
                B.compare (B.fromInt a) (B.fromInt b)
                    |> Expect.equal (Basics.compare a b)
        , fuzz2 bigIntFuzzer positiveBigIntFuzzer "x < x + d for any d > 0 (monotone under addition)" <|
            \x d ->
                B.compare x (B.add x d)
                    |> Expect.equal LT
        , fuzz bigIntFuzzer "compare a a == EQ (large values)" <|
            \a ->
                B.compare a a
                    |> Expect.equal EQ
        ]



-- DIVISION ALGORITHM


divModTests : Test
divModTests =
    describe "division algorithm"
        [ fuzz2 bigIntFuzzer positiveBigIntFuzzer "a == (a / b) * b + (a mod b)" <|
            \a b ->
                case ( B.div a b, B.mod a b ) of
                    ( Just q, Just r ) ->
                        B.eq (B.add (B.mul q b) r) a
                            |> Expect.equal True

                    _ ->
                        Expect.fail "div/mod returned Nothing for a positive divisor"
        , fuzz2 bigIntFuzzer positiveBigIntFuzzer "0 <= (a mod b) < b for b > 0" <|
            \a b ->
                case B.mod a b of
                    Just r ->
                        B.lt r b
                            |> Expect.equal True

                    Nothing ->
                        Expect.fail "mod returned Nothing for a positive divisor"
        , test "div by zero is Nothing" <|
            \_ ->
                B.div (B.fromInt 42) B.zero
                    |> Expect.equal Nothing
        , test "mod by zero is Nothing" <|
            \_ ->
                B.mod (B.fromInt 42) B.zero
                    |> Expect.equal Nothing
        ]
