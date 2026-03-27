module Web3.Units exposing
    ( formatEther
    , parseEther
    , formatUnits
    , parseUnits
    )

{-| ETH / ERC-20 unit conversion — pure Elm, no JS required.

    formatEther (BigInt.fromInt 1500000000000000000) == "1.5"
    parseEther "1.5" == Just <1500000000000000000>

@docs formatEther, parseEther
@docs formatUnits, parseUnits

-}

import Web3.BigInt as BigInt exposing (BigInt)


{-| Convert Wei to a human-readable ETH string with up to 18 significant
decimal places. Trailing zeros are trimmed.

    formatEther zero         == "0"
    formatEther (10^18 wei)  == "1"
    formatEther (1.5×10^18)  == "1.5"
    formatEther (10^15 wei)  == "0.001"

-}
formatEther : BigInt -> String
formatEther =
    formatUnits 18


{-| Parse a human-readable ETH string to Wei. Returns Nothing for invalid
input, non-numeric strings, or negative values.

    parseEther "1"                       == Just <10^18>
    parseEther "1.5"                     == Just <1.5×10^18>
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
            divisor =
                bigPow decimals

            whole =
                BigInt.div wei divisor |> Maybe.withDefault BigInt.zero

            rem =
                BigInt.mod wei divisor |> Maybe.withDefault BigInt.zero

            remStr =
                BigInt.toString rem
                    |> padLeft decimals '0'

            frac =
                trimTrailingZeros remStr
        in
        if String.isEmpty frac then
            BigInt.toString whole

        else
            BigInt.toString whole ++ "." ++ frac


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


{-| 10^n as a BigInt. Internal only — not public API.
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
