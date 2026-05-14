module Web3.BigInt exposing
    ( BigInt
    , fromInt
    , fromString
    , fromIntString
    , fromHexString
    , toString
    , toHexString
    , add
    , sub
    , mul
    , div
    , mod
    , compare
    , gt
    , gte
    , lt
    , lte
    , eq
    , zero
    , isZero
    , decoder
    )

{-| Arbitrary-precision integers for EVM applications.

Supports the full uint256 range (0 to 2^256-1) and int256 range.
Implemented as a base-10^7 digit list with no external dependencies.

All values crossing the port boundary are decimal strings — this module
handles the conversion safely.

@docs BigInt
@docs fromInt, fromString, fromIntString, fromHexString, toString, toHexString
@docs add, sub, mul, div, mod
@docs compare, eq, lt, lte, gt, gte
@docs zero, isZero
@docs decoder

-}

import Basics
import Char
import Json.Decode as D
import List
import String


type Sign
    = Pos
    | Neg


{-| An arbitrary-precision integer.
-}
type BigInt
    = BigInt Sign (List Int)


{-| Base: 10^7 = 10,000,000.

Each "digit" stores values 0..9,999,999.
Digits are stored little-endian (index 0 = least significant).

Safety: digit × digit + carry ≤ (10^7-1)² + (10^7-1) ≈ 10^14 < 2^53.
No overflow in Elm's Int (backed by a 64-bit float with 53-bit mantissa).

-}
base : Int
base =
    10000000


baseWidth : Int
baseWidth =
    7



-- ─── CONSTRUCTION ────────────────────────────────────────────────────────────


{-| Zero.
-}
zero : BigInt
zero =
    BigInt Pos []


{-| Create a BigInt from an Elm Int.
-}
fromInt : Int -> BigInt
fromInt n =
    if n == 0 then
        zero

    else if n > 0 then
        BigInt Pos (natFromInt n)

    else
        BigInt Neg (natFromInt (Basics.negate n))


natFromInt : Int -> List Int
natFromInt n =
    if n == 0 then
        []

    else
        (n |> modBy base) :: natFromInt (n // base)


{-| Parse a decimal integer string. Returns Nothing for invalid input.

Accepts optional leading '-' or '+' sign. Rejects empty strings,
non-digit characters, and floating-point notation.

    fromString "0"                    == Just zero
    fromString "-42"                  == Just (fromInt -42)
    fromString "115792...9935"        -- uint256 max: Just <big>
    fromString "abc"                  == Nothing
    fromString ""                     == Nothing

-}
fromString : String -> Maybe BigInt
fromString s =
    case String.uncons s of
        Nothing ->
            Nothing

        Just ( '-', rest ) ->
            parseUnsigned rest
                |> Maybe.map
                    (\(BigInt _ digits) ->
                        if digits == [] then
                            zero

                        else
                            BigInt Neg digits
                    )

        Just ( '+', rest ) ->
            parseUnsigned rest

        _ ->
            parseUnsigned s


{-| Alias for fromString (decimal). Kept for API symmetry with fromHexString.
-}
fromIntString : String -> Maybe BigInt
fromIntString =
    fromString


{-| Parse a 0x-prefixed hexadecimal string as a non-negative BigInt.
Returns Nothing for invalid input or empty hex body.

    fromHexString "0x64"  == Just (fromInt 100)
    fromHexString "0xFF"  == Just (fromInt 255)
    fromHexString "0x"    == Nothing
    fromHexString "0xgg"  == Nothing

-}
fromHexString : String -> Maybe BigInt
fromHexString s =
    let
        raw =
            if String.startsWith "0x" s || String.startsWith "0X" s then
                String.dropLeft 2 s

            else
                s
    in
    if String.isEmpty raw then
        Nothing

    else
        String.foldl
            (\c acc ->
                case acc of
                    Nothing ->
                        Nothing

                    Just n ->
                        let
                            d =
                                hexDigitValue c
                        in
                        if d < 0 then
                            Nothing

                        else
                            Just (add (mul n (fromInt 16)) (fromInt d))
            )
            (Just zero)
            (String.toLower raw)


hexDigitValue : Char -> Int
hexDigitValue c =
    if c >= '0' && c <= '9' then
        Char.toCode c - Char.toCode '0'

    else if c >= 'a' && c <= 'f' then
        Char.toCode c - Char.toCode 'a' + 10

    else
        -1


parseUnsigned : String -> Maybe BigInt
parseUnsigned s =
    if String.isEmpty s then
        Nothing

    else
        let
            chars =
                String.toList s
        in
        if List.all Char.isDigit chars then
            Just
                (List.foldl
                    (\c digits ->
                        natAddSmall (natMulSmall digits 10) (Char.toCode c - 48)
                    )
                    []
                    chars
                    |> BigInt Pos
                )

        else
            Nothing



-- ─── CONVERSION ──────────────────────────────────────────────────────────────


{-| Convert to decimal string.
-}
toString : BigInt -> String
toString (BigInt sign digits) =
    case digits of
        [] ->
            "0"

        _ ->
            let
                bigEndian =
                    List.reverse digits

                chunksStr =
                    case bigEndian of
                        [] ->
                            "0"

                        first :: rest ->
                            String.fromInt first
                                ++ String.concat
                                    (List.map
                                        (\d -> padLeft baseWidth (String.fromInt d))
                                        rest
                                    )

                prefix =
                    case sign of
                        Neg ->
                            "-"

                        Pos ->
                            ""
            in
            prefix ++ chunksStr


padLeft : Int -> String -> String
padLeft n s =
    let
        len =
            String.length s
    in
    if len >= n then
        s

    else
        String.repeat (n - len) "0" ++ s


{-| Convert a non-negative `BigInt` to a lower-case hexadecimal string
**without** a `"0x"` prefix or leading zeros.

Returns `"0"` for zero. For negative integers, the sign is dropped and the
absolute value is rendered — callers needing two's-complement should do the
twiddling themselves (or use `Web3.Abi.Calldata.int256`).

    toHexString (fromInt 0)     == "0"
    toHexString (fromInt 255)   == "ff"
    toHexString (fromInt 65535) == "ffff"

-}
toHexString : BigInt -> String
toHexString b =
    let
        sixteen =
            fromInt 16

        loop : BigInt -> String -> String
        loop rem acc =
            if isZero rem then
                if String.isEmpty acc then
                    "0"

                else
                    acc

            else
                let
                    digit =
                        case mod rem sixteen of
                            Just r ->
                                r
                                    |> toString
                                    |> String.toInt
                                    |> Maybe.withDefault 0

                            Nothing ->
                                0

                    rest =
                        case div rem sixteen of
                            Just q ->
                                q

                            Nothing ->
                                zero
                in
                loop rest (hexDigit digit ++ acc)
    in
    loop (abs_ b) ""


abs_ : BigInt -> BigInt
abs_ (BigInt _ digits) =
    BigInt Pos digits


hexDigit : Int -> String
hexDigit n =
    case n of
        0 ->
            "0"

        1 ->
            "1"

        2 ->
            "2"

        3 ->
            "3"

        4 ->
            "4"

        5 ->
            "5"

        6 ->
            "6"

        7 ->
            "7"

        8 ->
            "8"

        9 ->
            "9"

        10 ->
            "a"

        11 ->
            "b"

        12 ->
            "c"

        13 ->
            "d"

        14 ->
            "e"

        15 ->
            "f"

        _ ->
            "0"



-- ─── ARITHMETIC ──────────────────────────────────────────────────────────────


{-| Add two BigInts.
-}
add : BigInt -> BigInt -> BigInt
add (BigInt sa a) (BigInt sb b) =
    case ( sa, sb ) of
        ( Pos, Pos ) ->
            makeBigInt Pos (natAdd a b)

        ( Neg, Neg ) ->
            makeBigInt Neg (natAdd a b)

        ( Pos, Neg ) ->
            case natCompare a b of
                GT ->
                    makeBigInt Pos (natSub a b)

                LT ->
                    makeBigInt Neg (natSub b a)

                EQ ->
                    zero

        ( Neg, Pos ) ->
            case natCompare a b of
                GT ->
                    makeBigInt Neg (natSub a b)

                LT ->
                    makeBigInt Pos (natSub b a)

                EQ ->
                    zero


makeBigInt : Sign -> List Int -> BigInt
makeBigInt sign digits =
    case digits of
        [] ->
            zero

        _ ->
            BigInt sign digits


{-| Subtract.
-}
sub : BigInt -> BigInt -> BigInt
sub a (BigInt sb b) =
    add a (BigInt (flipSign sb) b)


flipSign : Sign -> Sign
flipSign s =
    case s of
        Pos ->
            Neg

        Neg ->
            Pos


{-| Multiply.
-}
mul : BigInt -> BigInt -> BigInt
mul (BigInt sa a) (BigInt sb b) =
    case natMul a b of
        [] ->
            zero

        result ->
            BigInt (combineSigns sa sb) result


combineSigns : Sign -> Sign -> Sign
combineSigns sa sb =
    case ( sa, sb ) of
        ( Pos, Pos ) ->
            Pos

        ( Neg, Neg ) ->
            Pos

        _ ->
            Neg


{-| Divide. Returns Nothing if divisor is zero.
-}
div : BigInt -> BigInt -> Maybe BigInt
div (BigInt sa a) (BigInt sb b) =
    if b == [] then
        Nothing

    else
        case Tuple.first (natDivMod a b) of
            [] ->
                Just zero

            q ->
                Just (BigInt (combineSigns sa sb) q)



{-| Remainder: a `mod` b. Returns Nothing if b is zero.

    mod (fromInt 10) (fromInt 3) == Just (fromInt 1)
    mod (fromInt 10) zero        == Nothing

-}
mod : BigInt -> BigInt -> Maybe BigInt
mod a b =
    case div a b of
        Nothing ->
            Nothing

        Just q ->
            Just (sub a (mul q b))



-- ─── COMPARISON ──────────────────────────────────────────────────────────────


{-| Compare two BigInts.
-}
compare : BigInt -> BigInt -> Order
compare (BigInt sa a) (BigInt sb b) =
    case ( a, b ) of
        ( [], [] ) ->
            EQ

        ( [], _ ) ->
            -- 0 vs nonzero
            case sb of
                Pos ->
                    LT

                Neg ->
                    GT

        ( _, [] ) ->
            -- nonzero vs 0
            case sa of
                Pos ->
                    GT

                Neg ->
                    LT

        _ ->
            case ( sa, sb ) of
                ( Pos, Neg ) ->
                    GT

                ( Neg, Pos ) ->
                    LT

                ( Pos, Pos ) ->
                    natCompare a b

                ( Neg, Neg ) ->
                    -- More negative = smaller
                    natCompare b a


{-| Greater than.
-}
gt : BigInt -> BigInt -> Bool
gt a b =
    compare a b == GT


{-| Greater than or equal.
-}
gte : BigInt -> BigInt -> Bool
gte a b =
    compare a b /= LT


{-| Less than.
-}
lt : BigInt -> BigInt -> Bool
lt a b =
    compare a b == LT


{-| Less than or equal.
-}
lte : BigInt -> BigInt -> Bool
lte a b =
    compare a b /= GT


{-| Equality.
-}
eq : BigInt -> BigInt -> Bool
eq a b =
    compare a b == EQ


{-| Is this BigInt zero?
-}
isZero : BigInt -> Bool
isZero (BigInt _ digits) =
    digits == []



-- ─── UNSIGNED ARITHMETIC ─────────────────────────────────────────────────────


natAdd : List Int -> List Int -> List Int
natAdd a b =
    natAddCarry a b 0 |> natNormalize


natAddCarry : List Int -> List Int -> Int -> List Int
natAddCarry a b carry =
    case ( a, b ) of
        ( [], [] ) ->
            if carry == 0 then
                []

            else
                [ carry ]

        ( [], y :: ys ) ->
            let
                sum =
                    y + carry
            in
            (modBy base sum) :: natAddCarry [] ys (sum // base)

        ( x :: xs, [] ) ->
            let
                sum =
                    x + carry
            in
            (modBy base sum) :: natAddCarry xs [] (sum // base)

        ( x :: xs, y :: ys ) ->
            let
                sum =
                    x + y + carry
            in
            (modBy base sum) :: natAddCarry xs ys (sum // base)


{-| Precondition: natCompare a b /= LT (i.e. a >= b).
-}
natSub : List Int -> List Int -> List Int
natSub a b =
    natSubBorrow a b 0 |> natNormalize


natSubBorrow : List Int -> List Int -> Int -> List Int
natSubBorrow a b borrow =
    case ( a, b ) of
        ( [], [] ) ->
            []

        ( x :: xs, [] ) ->
            let
                diff =
                    x - borrow
            in
            if diff >= 0 then
                diff :: xs

            else
                (diff + base) :: natSubBorrow xs [] 1

        ( x :: xs, y :: ys ) ->
            let
                diff =
                    x - y - borrow
            in
            if diff >= 0 then
                diff :: natSubBorrow xs ys 0

            else
                (diff + base) :: natSubBorrow xs ys 1

        ( [], _ ) ->
            []


{-| Multiply all digits by a small integer k.
Precondition: 0 <= k < base.
-}
natMulSmall : List Int -> Int -> List Int
natMulSmall digits k =
    if k == 0 then
        []

    else
        natMulSmallCarry digits k 0 |> natNormalize


natMulSmallCarry : List Int -> Int -> Int -> List Int
natMulSmallCarry digits k carry =
    case digits of
        [] ->
            if carry == 0 then
                []

            else
                [ carry ]

        d :: ds ->
            let
                prod =
                    d * k + carry
            in
            (modBy base prod) :: natMulSmallCarry ds k (prod // base)


{-| Add a small non-negative integer to digit list.
-}
natAddSmall : List Int -> Int -> List Int
natAddSmall digits v =
    natAddCarry digits [] v |> natNormalize


natMul : List Int -> List Int -> List Int
natMul a b =
    case ( a, b ) of
        ( [], _ ) ->
            []

        ( _, [] ) ->
            []

        _ ->
            List.indexedMap
                (\i ai ->
                    if ai == 0 then
                        []

                    else
                        shiftLeft i (natMulSmall b ai)
                )
                a
                |> List.foldl natAdd []


shiftLeft : Int -> List Int -> List Int
shiftLeft n digits =
    List.repeat n 0 ++ digits


natCompare : List Int -> List Int -> Order
natCompare a b =
    let
        la =
            List.length a

        lb =
            List.length b
    in
    if la /= lb then
        if la > lb then
            GT

        else
            LT

    else
        natCompareEqualLen (List.reverse a) (List.reverse b)


natCompareEqualLen : List Int -> List Int -> Order
natCompareEqualLen a b =
    case ( a, b ) of
        ( [], [] ) ->
            EQ

        ( x :: xs, y :: ys ) ->
            if x /= y then
                if x > y then
                    GT

                else
                    LT

            else
                natCompareEqualLen xs ys

        _ ->
            EQ


{-| Remove most-significant zero digits (little-endian: trailing zeros).
-}
natNormalize : List Int -> List Int
natNormalize digits =
    case List.reverse digits of
        [] ->
            []

        0 :: rest ->
            natNormalize (List.reverse rest)

        _ ->
            digits



-- ─── DIVISION ────────────────────────────────────────────────────────────────


{-| Unsigned division with remainder. Returns (quotient, remainder).
Precondition: b /= [].
-}
natDivMod : List Int -> List Int -> ( List Int, List Int )
natDivMod a b =
    case natCompare a b of
        LT ->
            ( [], a )

        EQ ->
            ( [ 1 ], [] )

        GT ->
            let
                shift =
                    List.length a - List.length b
            in
            natDivModStep a b shift []


natDivModStep : List Int -> List Int -> Int -> List Int -> ( List Int, List Int )
natDivModStep remainder b shift qAcc =
    if shift < 0 then
        ( natNormalize qAcc, natNormalize remainder )

    else
        let
            bShifted =
                shiftLeft shift b

            qd =
                findQd remainder bShifted 0 base

            newRemainder =
                natSub remainder (natMulSmall bShifted qd)
        in
        natDivModStep newRemainder b (shift - 1) (qd :: qAcc)


{-| Binary search: largest qd in [lo, hi) such that qd * bShifted <= remainder.
-}
findQd : List Int -> List Int -> Int -> Int -> Int
findQd remainder bShifted lo hi =
    if hi - lo <= 1 then
        lo

    else
        let
            mid =
                lo + (hi - lo) // 2
        in
        case natCompare (natMulSmall bShifted mid) remainder of
            GT ->
                findQd remainder bShifted lo mid

            _ ->
                findQd remainder bShifted mid hi


{-| Decode a BigInt from a JSON decimal string.

    D.decodeString BigInt.decoder "\"12345\"" == Ok (BigInt.fromInt 12345)

-}
decoder : D.Decoder BigInt
decoder =
    D.string
        |> D.andThen
            (\s ->
                case fromString s of
                    Just n ->
                        D.succeed n

                    Nothing ->
                        D.fail ("Invalid BigInt: " ++ s)
            )
