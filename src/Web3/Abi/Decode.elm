module Web3.Abi.Decode exposing
    ( address
    , uint256
    , int256
    , bool
    , string
    , bytes32
    , uint8
    , uint16
    , uint32
    , uint64
    , uint128
    , hexSlot
    , uint256Slot
    , addressSlot
    , boolSlot
    , stringSlot
    , listSlot
    , tuple2Hex
    , tuple3Hex
    , decodeRevertReason
    , decodeCustomError
    )

{-| Helpers to decode contract return values from JSON
received through ports from the JS Web3 layer.

@docs address, uint256, int256, bool, string, bytes32
@docs uint8, uint16, uint32, uint64, uint128
@docs hexSlot, uint256Slot, addressSlot, boolSlot, stringSlot, listSlot
@docs tuple2Hex, tuple3Hex
@docs decodeRevertReason, decodeCustomError

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
Accepts both decimal strings ("100") and 0x-prefixed hex strings ("0x64").
-}
uint256 : D.Decoder BigInt
uint256 =
    D.string
        |> D.andThen
            (\s ->
                let
                    parse =
                        if String.startsWith "0x" s || String.startsWith "0X" s then
                            BigInt.fromHexString s

                        else
                            BigInt.fromString s
                in
                case parse of
                    Just n ->
                        D.succeed n

                    Nothing ->
                        D.fail ("Invalid uint256: " ++ s)
            )


{-| Decode a uint8 return value as an Elm Int (validated 0-255).
-}
uint8 : D.Decoder Int
uint8 =
    uint256
        |> D.andThen
            (\n ->
                if BigInt.lte n (BigInt.fromInt 255) && not (BigInt.lt n BigInt.zero) then
                    case String.toInt (BigInt.toString n) of
                        Just i ->
                            D.succeed i

                        Nothing ->
                            D.fail "uint8: internal conversion error"

                else
                    D.fail ("uint8 out of range: " ++ BigInt.toString n)
            )


{-| Decode a uint16 return value as an Elm Int (validated 0-65535).
-}
uint16 : D.Decoder Int
uint16 =
    uint256
        |> D.andThen
            (\n ->
                if BigInt.lte n (BigInt.fromInt 65535) && not (BigInt.lt n BigInt.zero) then
                    case String.toInt (BigInt.toString n) of
                        Just i ->
                            D.succeed i

                        Nothing ->
                            D.fail "uint16: internal conversion error"

                else
                    D.fail ("uint16 out of range: " ++ BigInt.toString n)
            )


{-| Decode a uint32 return value as an Elm Int (validated 0-4294967295).
-}
uint32 : D.Decoder Int
uint32 =
    uint256
        |> D.andThen
            (\n ->
                if BigInt.lte n (BigInt.fromInt 4294967295) && not (BigInt.lt n BigInt.zero) then
                    case String.toInt (BigInt.toString n) of
                        Just i ->
                            D.succeed i

                        Nothing ->
                            D.fail "uint32: internal conversion error"

                else
                    D.fail ("uint32 out of range: " ++ BigInt.toString n)
            )


{-| Decode a uint64 return value as a BigInt (exceeds JS/Elm safe Int range).
-}
uint64 : D.Decoder BigInt
uint64 =
    uint256
        |> D.andThen
            (\n ->
                if not (BigInt.lt n BigInt.zero) then
                    D.succeed n

                else
                    D.fail ("uint64 out of range: " ++ BigInt.toString n)
            )


{-| Decode a uint128 return value as a BigInt.
-}
uint128 : D.Decoder BigInt
uint128 =
    uint256
        |> D.andThen
            (\n ->
                if not (BigInt.lt n BigInt.zero) then
                    D.succeed n

                else
                    D.fail ("uint128 out of range: " ++ BigInt.toString n)
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


{-| Extract the 64-character hex of the 32-byte word at slot index `n`
(0-indexed) from a 0x-prefixed ABI-encoded hex string.

    hexSlot 0 "0x0000...0064" == "0000...0064"

-}
hexSlot : Int -> String -> String
hexSlot n hex =
    String.dropLeft 2 hex
        |> String.dropLeft (n * 64)
        |> String.left 64


{-| Decode a uint256 from slot `n` of a raw 0x-hex ABI response.
-}
uint256Slot : Int -> String -> Maybe BigInt
uint256Slot n hex =
    BigInt.fromHexString ("0x" ++ hexSlot n hex)


{-| Decode an Address from slot `n` of a raw 0x-hex ABI response.
Addresses are right-aligned in the 32-byte slot.
-}
addressSlot : Int -> String -> Maybe T.Address
addressSlot n hex =
    let
        slot =
            hexSlot n hex

        addr =
            "0x" ++ String.right 40 slot
    in
    T.address addr


{-| Decode a bool from slot `n` of a raw 0x-hex ABI response.
-}
boolSlot : Int -> String -> Maybe Bool
boolSlot n hex =
    case String.right 1 (hexSlot n hex) of
        "0" ->
            Just False

        "1" ->
            Just True

        _ ->
            Nothing


{-| Decode a dynamic UTF-8 string from slot `n` of a raw 0x-hex ABI response.
Slot `n` contains an offset pointer; the string length and data follow at
that offset.
-}
stringSlot : Int -> String -> Maybe String
stringSlot n hex =
    let
        raw =
            String.dropLeft 2 hex

        offsetHex =
            String.dropLeft (n * 64) raw |> String.left 64

        offsetBytes =
            hexToInt offsetHex

        lenHex =
            String.dropLeft (offsetBytes * 2) raw |> String.left 64

        len =
            hexToInt lenHex

        dataHex =
            String.dropLeft (offsetBytes * 2 + 64) raw |> String.left (len * 2)
    in
    hexUtf8ToString dataHex


{-| Decode a dynamic array from slot `n`. Each element is decoded by calling
`elemDecoder slotIndex fullHex`. Works for static-element arrays (uint256[],
address[], etc.) where elements are stored consecutively.
-}
listSlot : Int -> (Int -> String -> Maybe a) -> String -> Maybe (List a)
listSlot n elemDecoder hex =
    let
        raw =
            String.dropLeft 2 hex

        offsetHex =
            String.dropLeft (n * 64) raw |> String.left 64

        offsetBytes =
            hexToInt offsetHex

        lenHex =
            String.dropLeft (offsetBytes * 2) raw |> String.left 64

        count =
            hexToInt lenHex

        firstElemSlot =
            (offsetBytes // 32) + 1
    in
    List.range 0 (count - 1)
        |> List.map (\i -> elemDecoder (firstElemSlot + i) hex)
        |> List.foldr (Maybe.map2 (::)) (Just [])


{-| Decode a static 2-tuple from the head of a 0x-hex ABI response.
Each decoder is called with its slot index (0, 1).
-}
tuple2Hex :
    (Int -> String -> Maybe a)
    -> (Int -> String -> Maybe b)
    -> String
    -> Maybe ( a, b )
tuple2Hex da db hex =
    case ( da 0 hex, db 1 hex ) of
        ( Just a, Just b ) ->
            Just ( a, b )

        _ ->
            Nothing


{-| Decode a static 3-tuple from the head of a 0x-hex ABI response.
-}
tuple3Hex :
    (Int -> String -> Maybe a)
    -> (Int -> String -> Maybe b)
    -> (Int -> String -> Maybe c)
    -> String
    -> Maybe ( a, b, c )
tuple3Hex da db dc hex =
    case ( da 0 hex, db 1 hex, dc 2 hex ) of
        ( Just a, Just b, Just c ) ->
            Just ( a, b, c )

        _ ->
            Nothing


{-| Attempt to decode an EVM revert reason from raw revert data.

Checks for the Error(string) selector `0x08c379a0` and decodes the
ABI-encoded string that follows. Returns Nothing if the data is not
a standard Error(string) revert.

    decodeRevertReason "0x08c379a000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000011496e73756666696369656e742066756e647300000000000000000000000000"
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

        -- Error(string) selector is 08c379a0 — 8 hex chars
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
    if selector == "08c379a0" && String.length raw >= 8 + 64 + 64 then
        hexUtf8ToString stringHex

    else
        Nothing


{-| Parse a hex string (no 0x prefix) as an Int. Returns 0 on any error.
Only handles values that fit in JS/Elm Int -- fine for string lengths.
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


{-| Decode a typed Solidity custom error (`error InsufficientBalance(uint256
have, uint256 want)`) from raw revert data, given selector fragments the app
bakes at codegen time -- the same no-runtime-keccak philosophy as
`Web3.Abi.Calldata` selectors.

    fragments =
        [ { selector = "cf479181"      -- keccak("InsufficientBalance(uint256,uint256)")[:4]
          , name = "InsufficientBalance"
          , decodeArgs = \tail -> Maybe.map2 (\a b -> [ a, b ])
                (word 0 tail) (word 1 tail)
          }
        ]

    decodeCustomError fragments revertData
    --> Just { name = "InsufficientBalance", args = [ "5", "10" ] }

`decodeArgs` receives the ABI-encoded argument tail as bare hex (no `0x`,
selector already stripped) and renders each argument to a display string --
build it from this module's slot readers.

Precedence, decided: this function REFUSES the standard selectors
`08c379a0` (`Error(string)`) and `4e487b71` (`Panic(uint256)`) so it
composes with [`decodeRevertReason`](#decodeRevertReason) unambiguously in
either order -- each decoder has a disjoint domain.

Returns `Nothing` for: standard selectors, unknown selectors, payloads
shorter than a selector, or a fragment whose `decodeArgs` fails.

-}
decodeCustomError :
    List { selector : String, name : String, decodeArgs : String -> Maybe (List String) }
    -> String
    -> Maybe { name : String, args : List String }
decodeCustomError fragments hex =
    let
        raw =
            if String.startsWith "0x" hex || String.startsWith "0X" hex then
                String.dropLeft 2 hex

            else
                hex

        selector =
            String.toLower (String.left 8 raw)

        tail =
            String.dropLeft 8 raw
    in
    if String.length raw < 8 then
        Nothing

    else if selector == "08c379a0" || selector == "4e487b71" then
        Nothing

    else
        fragments
            |> List.filter (\f -> String.toLower f.selector == selector)
            |> List.head
            |> Maybe.andThen
                (\f ->
                    f.decodeArgs tail
                        |> Maybe.map (\args -> { name = f.name, args = args })
                )
