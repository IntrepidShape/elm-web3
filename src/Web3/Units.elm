module Web3.Units exposing
    ( formatEther
    , parseEther
    , formatUnits
    , parseUnits
    )

{-| ETH / ERC-20 unit conversion -- pure Elm, no JS required.

    parseEther "1.5" == Just <1500000000000000000>

Build wei values with `BigInt.fromString`, never `BigInt.fromInt`. An Elm `Int`
is a JS double, so a literal above 2^53 is already corrupt before it reaches
this module: `BigInt.fromInt 1500000000000000000` yields 999996861446400000000.
Every realistic 18-decimal amount is past that bound.

Negative values format with a single leading sign, and `parseUnits` rejects a
malformed fraction rather than returning a plausible wrong number.

@docs formatEther, parseEther
@docs formatUnits, parseUnits

-}

import Web3.BigInt as BigInt exposing (BigInt)


{-| Convert Wei to a human-readable ETH string with up to 18 significant
decimal places. Trailing zeros are trimmed.

    formatEther zero         == "0"
    formatEther (10^18 wei)  == "1"
    formatEther (1.5x10^18)  == "1.5"
    formatEther (10^15 wei)  == "0.001"

-}
formatEther : BigInt -> String
formatEther =
    formatUnits 18


{-| Parse a human-readable ETH string to Wei. Returns Nothing for invalid
input, non-numeric strings, or negative values.

    parseEther "1"                       == Just <10^18>
    parseEther "1.5"                     == Just <1.5x10^18>
    parseEther "0.000000000000000001"    == Just (BigInt.fromInt 1)
    parseEther "not-a-number"            == Nothing
    parseEther "-1"                      == Nothing

-}
parseEther : String -> Maybe BigInt
parseEther =
    parseUnits 18


{-| Convert a token amount (in its smallest unit) to a human-readable string
for a token with the given number of decimal places. Trailing zeros are trimmed.

    formatUnits 6 (BigInt.fromInt 1500000)  == "1.5"   -- USDC
    formatUnits 8 (BigInt.fromInt 100000000) == "1"    -- WBTC

-}
formatUnits : Int -> BigInt -> String
formatUnits decimals wei =
    if decimals <= 0 then
        BigInt.toString wei

    else
        let
            negative =
                BigInt.lt wei BigInt.zero

            magnitude =
                if negative then
                    BigInt.sub BigInt.zero wei

                else
                    wei

            divisor =
                bigPow decimals

            whole =
                BigInt.div magnitude divisor |> Maybe.withDefault BigInt.zero

            rem =
                BigInt.mod magnitude divisor |> Maybe.withDefault BigInt.zero

            remStr =
                BigInt.toString rem
                    |> padLeft decimals '0'

            frac =
                trimTrailingZeros remStr

            body =
                if String.isEmpty frac then
                    BigInt.toString whole

                else
                    BigInt.toString whole ++ "." ++ frac
        in
        -- The sign is applied once, to the finished string. Formatting the
        -- signed value directly put the minus inside the fraction: a -1.5e15
        -- wei balance rendered as "0.0-15".
        if negative then
            "-" ++ body

        else
            body


{-| Parse a human-readable token amount to its smallest unit, given the
token's decimal count. Returns Nothing for invalid or negative input.

    parseUnits 6 "1.5"  == Just (BigInt.fromInt 1500000)   -- USDC
    parseUnits 6 "0"    == Just BigInt.zero
    parseUnits 6 "-1"   == Nothing

-}
parseUnits : Int -> String -> Maybe BigInt
parseUnits decimals s =
    if String.isEmpty s then
        Nothing

    else if String.startsWith "-" s then
        Nothing

    else
        case String.split "." s of
            [ wholeStr ] ->
                case BigInt.fromString (ifEmpty "0" wholeStr) of
                    Just whole ->
                        if BigInt.lt whole BigInt.zero then
                            Nothing

                        else
                            Just (BigInt.mul whole (bigPow decimals))

                    Nothing ->
                        Nothing

            [ wholeStr, fracStr ] ->
                if not (isDigits fracStr) then
                    -- A sign or exponent inside the fraction used to reach
                    -- BigInt.fromString, which accepts a leading '-'/'+':
                    -- "1.-5" parsed as 0.95 with no error reported.
                    Nothing

                else
                let
                    -- Truncate to at most `decimals` digits, pad right to exactly `decimals`
                    padded =
                        String.left decimals fracStr
                            |> padRight decimals '0'
                in
                case
                    ( BigInt.fromString (ifEmpty "0" wholeStr)
                    , BigInt.fromString padded
                    )
                of
                    ( Just whole, Just frac ) ->
                        if BigInt.lt whole BigInt.zero then
                            Nothing

                        else
                            Just
                                (BigInt.add
                                    (BigInt.mul whole (bigPow decimals))
                                    frac
                                )

                    _ ->
                        Nothing

            _ ->
                -- Multiple dots — invalid
                Nothing



-- INTERNAL HELPERS


{-| True when every character is an ASCII digit. An empty string is digits-only
by convention ("1." is a well-formed whole number).
-}
isDigits : String -> Bool
isDigits str =
    String.all Char.isDigit str


{-| 10^n as a BigInt. Internal only -- not public API.
-}
bigPow : Int -> BigInt
bigPow n =
    if n <= 0 then
        BigInt.fromInt 1

    else
        BigInt.mul (BigInt.fromInt 10) (bigPow (n - 1))


padLeft : Int -> Char -> String -> String
padLeft n ch s =
    let
        len =
            String.length s
    in
    if len >= n then
        s

    else
        String.repeat (n - len) (String.fromChar ch) ++ s


padRight : Int -> Char -> String -> String
padRight n ch s =
    let
        len =
            String.length s
    in
    if len >= n then
        s

    else
        s ++ String.repeat (n - len) (String.fromChar ch)


trimTrailingZeros : String -> String
trimTrailingZeros s =
    case List.reverse (String.toList s) of
        [] ->
            ""

        chars ->
            chars
                |> dropWhile ((==) '0')
                |> List.reverse
                |> String.fromList


dropWhile : (a -> Bool) -> List a -> List a
dropWhile pred list =
    case list of
        [] ->
            []

        x :: xs ->
            if pred x then
                dropWhile pred xs

            else
                x :: xs


ifEmpty : String -> String -> String
ifEmpty default s =
    if String.isEmpty s then
        default

    else
        s
