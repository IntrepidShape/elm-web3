module Web3.Abi.Decode exposing
    ( address
    , uint256
    , int256
    , bool
    , string
    , bytes32
    , decodeRevertReason
    )

{-| Helpers to decode contract return values from JSON
received through ports from the JS Web3 layer.
-}

import Web3.BigInt as BigInt exposing (BigInt)
import Bitwise
import Json.Decode as D
import Web3.Types as T


{-| Decode an Address return value.
-}
address : D.Decoder T.Address
address =
    D.string
        |> D.andThen
            (\s ->
                case T.address s of
                    Just a ->
                        D.succeed a

                    Nothing ->
                        D.fail ("Invalid address: " ++ s)
            )


{-| Decode a uint256 return value as a BigInt.
-}
uint256 : D.Decoder BigInt
uint256 =
    D.string
        |> D.andThen
            (\s ->
                case BigInt.fromString s of
                    Just n ->
                        D.succeed n

                    Nothing ->
                        D.fail ("Invalid uint256: " ++ s)
            )


{-| Decode an int256 return value as a BigInt.
-}
int256 : D.Decoder BigInt
int256 =
    uint256


{-| Decode a bool return value.
-}
bool : D.Decoder Bool
bool =
    D.bool


{-| Decode a string return value.
-}
string : D.Decoder String
string =
    D.string


{-| Decode a bytes32 hex string (e.g. an event topic). Expects a 0x-prefixed
66-character hex string and returns it as-is.
-}
bytes32 : D.Decoder String
bytes32 =
    D.string
        |> D.andThen
            (\s ->
                if String.startsWith "0x" s && String.length s == 66 then
                    D.succeed s

                else
                    D.fail ("Invalid bytes32: " ++ s)
            )


{-| Attempt to decode an EVM revert reason from raw revert data.

Checks for the Error(string) selector `0x08c379a2` and decodes the
ABI-encoded string that follows. Returns Nothing if the data is not
a standard Error(string) revert.

    decodeRevertReason "0x08c379a200000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000011496e73756666696369656e742066756e647300000000000000000000000000"
    --> Just "Insufficient funds"

-}
decodeRevertReason : String -> Maybe String
decodeRevertReason hex =
    let
        -- Strip 0x prefix
        raw =
            if String.startsWith "0x" hex || String.startsWith "0X" hex then
                String.dropLeft 2 hex

            else
                hex

        -- Error(string) selector is 08c379a2 — 8 hex chars
        selector =
            String.left 8 (String.toLower raw)

        -- After selector (8 chars): 32-byte offset word (64 chars) then 32-byte length word (64 chars)
        -- Offset word should be 0x20 (= 32), pointing to the length word right after it.
        -- We read the length as a decimal from the hex word.
        afterSelector =
            String.dropLeft 8 raw

        -- Skip the 32-byte offset slot (64 hex chars)
        afterOffset =
            String.dropLeft 64 afterSelector

        -- Read the 32-byte (64 hex chars) string length field
        lengthHex =
            String.left 64 afterOffset

        stringLength =
            hexToInt lengthHex

        -- String bytes follow the length word
        stringHex =
            String.left (stringLength * 2) (String.dropLeft 64 afterOffset)
    in
    if selector == "08c379a2" && String.length raw >= 8 + 64 + 64 then
        hexUtf8ToString stringHex

    else
        Nothing


{-| Parse a hex string (no 0x prefix) as an Int. Returns 0 on any error.
Only handles values that fit in JS/Elm Int — fine for string lengths.
-}
hexToInt : String -> Int
hexToInt h =
    String.foldl
        (\c acc ->
            acc
                * 16
                + (if c >= '0' && c <= '9' then
                    Char.toCode c - Char.toCode '0'

                   else if c >= 'a' && c <= 'f' then
                    Char.toCode c - Char.toCode 'a' + 10

                   else if c >= 'A' && c <= 'F' then
                    Char.toCode c - Char.toCode 'A' + 10

                   else
                    0
                  )
        )
        0
        h


{-| Decode a hex string (no 0x prefix, pairs of chars) as UTF-8 text.
Returns Nothing if the hex is malformed or contains invalid UTF-8.
This handles ASCII and multi-byte UTF-8 sequences.
-}
hexUtf8ToString : String -> Maybe String
hexUtf8ToString h =
    if String.length h == 0 then
        Just ""

    else
        let
            bytes =
                hexToBytes h
        in
        utf8BytesToString bytes


hexToBytes : String -> List Int
hexToBytes h =
    if String.length h < 2 then
        []

    else
        let
            byteHex =
                String.left 2 h

            rest =
                String.dropLeft 2 h

            byte =
                hexToInt byteHex
        in
        byte :: hexToBytes rest


utf8BytesToString : List Int -> Maybe String
utf8BytesToString bytes =
    utf8Help bytes []
        |> Maybe.map String.fromList


utf8Help : List Int -> List Char -> Maybe (List Char)
utf8Help bytes acc =
    case bytes of
        [] ->
            Just (List.reverse acc)

        b :: rest ->
            if b < 0x80 then
                -- Single-byte ASCII
                utf8Help rest (Char.fromCode b :: acc)

            else if b >= 0xC0 && b < 0xE0 then
                -- Two-byte sequence
                case rest of
                    b2 :: rest2 ->
                        let
                            codePoint =
                                Bitwise.and (Bitwise.shiftLeftBy 6 (Bitwise.and b 0x1F)) 0xFFFF
                                    + Bitwise.and b2 0x3F
                        in
                        utf8Help rest2 (Char.fromCode codePoint :: acc)

                    _ ->
                        Nothing

            else if b >= 0xE0 && b < 0xF0 then
                -- Three-byte sequence
                case rest of
                    b2 :: b3 :: rest3 ->
                        let
                            codePoint =
                                Bitwise.shiftLeftBy 12 (Bitwise.and b 0x0F)
                                    + Bitwise.shiftLeftBy 6 (Bitwise.and b2 0x3F)
                                    + Bitwise.and b3 0x3F
                        in
                        utf8Help rest3 (Char.fromCode codePoint :: acc)

                    _ ->
                        Nothing

            else if b >= 0xF0 then
                -- Four-byte sequence
                case rest of
                    b2 :: b3 :: b4 :: rest4 ->
                        let
                            codePoint =
                                Bitwise.shiftLeftBy 18 (Bitwise.and b 0x07)
                                    + Bitwise.shiftLeftBy 12 (Bitwise.and b2 0x3F)
                                    + Bitwise.shiftLeftBy 6 (Bitwise.and b3 0x3F)
                                    + Bitwise.and b4 0x3F
                        in
                        utf8Help rest4 (Char.fromCode codePoint :: acc)

                    _ ->
                        Nothing

            else
                -- Continuation byte without a leading byte — malformed
                Nothing
