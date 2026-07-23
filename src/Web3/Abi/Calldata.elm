module Web3.Abi.Calldata exposing
    ( Slot
    , address
    , uint256
    , uintN
    , int256
    , bool
    , bytes32
    , bytesN
    , string
    , bytes
    , list
    , tuple
    , calldata
    )

{-| Pure-Elm ABI calldata encoding for contract calls.

Produces the exact hex bytes that go on the wire -- selector + ABI-encoded
parameters -- without any JavaScript surface. The result of
[`calldata`](#calldata) is a `"0x..."` string suitable for the `data` field
of `eth_call` / `eth_sendTransaction`.

The encoder follows the Solidity ABI specification's "head/tail" layout:

  - **Static types** (`address`, `uintN`, `intN`, `bool`, `bytesN` for `N <= 32`)
    occupy 32 bytes inline in the head section.
  - **Dynamic types** (`string`, `bytes`, `T[]`, tuples containing any dynamic
    field) occupy 32 bytes in the head holding the **offset** of their data
    within the calldata, with the actual content appended to the tail
    (length-prefixed for variable-length types).

Codegen tools should *bake the 4-byte selector at codegen time* (computed via
keccak256 of the function signature) and pass it to [`calldata`](#calldata).
That keeps the runtime entirely in Elm -- no JS hash function needed.

    -- balanceOf(address) -- selector is keccak256("balanceOf(address)")[:4] = 70a08231
    calldata "70a08231" [ address holder ]
        == "0x70a08231000000000000000000000000abcd..."

    -- approve(address,uint256)
    calldata "095ea7b3"
        [ address spender
        , uint256 amount
        ]

    -- transferBatch(address[], uint256[]) -- dynamic
    calldata "deadbeef"
        [ list address recipients
        , list uint256 amounts
        ]

@docs Slot
@docs address, uint256, uintN, int256, bool, bytes32, bytesN
@docs string, bytes
@docs list, tuple
@docs calldata

-}

import Web3.BigInt as BigInt exposing (BigInt)
import Web3.Types as T



-- TYPES ---------------------------------------------------------------------


{-| A piece of an ABI parameter list -- either a static 32-byte chunk or a
dynamic blob that lives in the tail.

The internals are deliberately opaque: callers construct `Slot`s via the
typed helpers below and never inspect the hex themselves.
-}
type Slot
    = Static String
    | Dynamic { tail : String }


sLEN : Int
sLEN =
    64



-- STATIC ENCODERS -----------------------------------------------------------


{-| 20-byte address, left-padded to 32 bytes. -}
address : T.Address -> Slot
address addr =
    let
        hex =
            T.addressToString addr
                |> String.dropLeft 2
                |> String.toLower
    in
    Static (padLeftHex sLEN hex)


{-| Unsigned 256-bit integer, left-padded to 32 bytes.

Negative values are encoded as their absolute value; for signed integers use
[`int256`](#int256) instead.
-}
uint256 : BigInt -> Slot
uint256 b =
    Static (padLeftHex sLEN (BigInt.toHexString b))


{-| Unsigned integer of `n` bits (8/16/24/.../256), encoded identically to
[`uint256`](#uint256). Width is a hint to callers; on the wire all unsigned
integers up to 256 bits occupy one 32-byte slot.

Bounds-checking is the caller's responsibility -- a value exceeding `2^n - 1`
is encoded as `uint256` and will revert on-chain in `solc 0.8+`.
-}
uintN : Int -> BigInt -> Slot
uintN _ b =
    uint256 b


{-| Signed 256-bit integer, encoded as two's-complement, left-padded to 32
bytes.

    int256 (BigInt.fromInt -1)
    --> 0xffffffff...ffff  (32 bytes of 0xff)

-}
int256 : BigInt -> Slot
int256 b =
    if BigInt.isZero b then
        Static (String.repeat sLEN "0")

    else if BigInt.gt b BigInt.zero then
        Static (padLeftHex sLEN (BigInt.toHexString b))

    else
        -- two's complement at 256 bits: 2^256 + b  (b is negative)
        case BigInt.fromHexString twoTo256Hex of
            Just twoTo256 ->
                Static (padLeftHex sLEN (BigInt.toHexString (BigInt.add twoTo256 b)))

            Nothing ->
                Static (String.repeat sLEN "0")


twoTo256Hex : String
twoTo256Hex =
    "0x10000000000000000000000000000000000000000000000000000000000000000"


{-| `bool`, encoded as a 32-byte slot of zeros (false) or zeros + `01` (true).
-}
bool : Bool -> Slot
bool b =
    Static
        (if b then
            padLeftHex sLEN "1"

         else
            String.repeat sLEN "0"
        )


{-| `bytes32` -- 32 bytes of arbitrary data, accepting either `"0x..."` or bare
hex. Right-padded with zeros if shorter than 32 bytes.
-}
bytes32 : String -> Slot
bytes32 hex =
    let
        clean =
            stripHex hex
                |> String.toLower

        truncated =
            String.left sLEN clean
    in
    Static (padRightHex sLEN truncated)


{-| `bytesN` for `N in {1..32}`. Right-padded to 32 bytes.

    bytesN 4 "0xdeadbeef"
    --> 0xdeadbeef00000000...00 (32 bytes total)

-}
bytesN : Int -> String -> Slot
bytesN n hex =
    let
        clean =
            stripHex hex
                |> String.toLower

        nibbles =
            n * 2

        truncated =
            String.left nibbles clean
    in
    Static (padRightHex sLEN (padRightHex nibbles truncated))



-- DYNAMIC ENCODERS ----------------------------------------------------------


{-| UTF-8 string, encoded as a length-prefixed dynamic blob.
-}
string : String -> Slot
string s =
    let
        utf8 =
            stringToUtf8Hex s
    in
    Dynamic { tail = encodeDynamicBytes utf8 }


{-| Raw bytes (`bytes`), accepted as `"0x..."` or bare hex. Encoded as a
length-prefixed dynamic blob.
-}
bytes : String -> Slot
bytes hex =
    let
        clean =
            stripHex hex
                |> String.toLower
    in
    Dynamic { tail = encodeDynamicBytes clean }


{-| Dynamic array `T[]`, encoded as `length || encode(elements)`. -}
list : (a -> Slot) -> List a -> Slot
list encoder xs =
    let
        slots =
            List.map encoder xs

        innerHex =
            layoutSlots slots

        lengthHex =
            padLeftHex sLEN (intToHex (List.length xs))
    in
    Dynamic { tail = lengthHex ++ innerHex }


{-| Tuple (struct), encoded inline if every component is static, or as a
dynamic blob otherwise.

The wire layout matches Solidity's: a tuple of all-static fields occupies the
sum of its components' slots inline; a tuple containing any dynamic field is
itself dynamic and lives in the tail with the inner layout recursed.
-}
tuple : List Slot -> Slot
tuple slots =
    if List.all isStatic slots then
        Static
            (String.concat
                (List.map
                    (\s ->
                        case s of
                            Static h ->
                                h

                            Dynamic _ ->
                                String.repeat sLEN "0"
                    )
                    slots
                )
            )

    else
        Dynamic { tail = layoutSlots slots }


isStatic : Slot -> Bool
isStatic s =
    case s of
        Static _ ->
            True

        Dynamic _ ->
            False



-- CALLDATA ASSEMBLY ---------------------------------------------------------


{-| Combine a 4-byte selector and a list of [`Slot`](#Slot)s into the full
calldata hex string.

The selector is **bare hex** (no `"0x"` prefix), exactly 8 characters
(4 bytes). Codegen tools should compute this at codegen time via
`keccak256(signature).slice(0, 8)` and bake it as a constant -- this module
intentionally does not include a keccak implementation, so it stays pure
data layout.

    calldata "70a08231" [ address holder ]
    --> "0x70a08231000000...<holder padded to 32 bytes>"

-}
calldata : String -> List Slot -> String
calldata selector slots =
    "0x" ++ String.toLower selector ++ layoutSlots slots



-- INTERNAL : LAYOUT ---------------------------------------------------------


{-| Build the parameter-list portion (head + tail) of an ABI-encoded
calldata blob, given the slots that make it up. -}
layoutSlots : List Slot -> String
layoutSlots slots =
    let
        headSize =
            List.length slots * (sLEN // 2)

        ( heads, tails, _ ) =
            List.foldl
                (\slot ( hsAcc, tsAcc, offset ) ->
                    case slot of
                        Static hex ->
                            ( hsAcc ++ [ hex ], tsAcc, offset )

                        Dynamic { tail } ->
                            ( hsAcc ++ [ padLeftHex sLEN (intToHex offset) ]
                            , tsAcc ++ [ tail ]
                            , offset + (String.length tail // 2)
                            )
                )
                ( [], [], headSize )
                slots
    in
    String.concat heads ++ String.concat tails


{-| Encode a hex-string of raw bytes as `length || data || padding-to-32`. -}
encodeDynamicBytes : String -> String
encodeDynamicBytes hex =
    let
        byteCount =
            String.length hex // 2

        lengthHex =
            padLeftHex sLEN (intToHex byteCount)

        contentPaddedLen =
            ceilingTo sLEN (String.length hex)

        content =
            padRightHex contentPaddedLen hex
    in
    lengthHex ++ content


ceilingTo : Int -> Int -> Int
ceilingTo m n =
    if remainderBy m n == 0 then
        n

    else
        n + (m - remainderBy m n)



-- INTERNAL : HEX HELPERS ----------------------------------------------------


padLeftHex : Int -> String -> String
padLeftHex n s =
    let
        len =
            String.length s
    in
    if len >= n then
        s

    else
        String.repeat (n - len) "0" ++ s


padRightHex : Int -> String -> String
padRightHex n s =
    let
        len =
            String.length s
    in
    if len >= n then
        s

    else
        s ++ String.repeat (n - len) "0"


stripHex : String -> String
stripHex s =
    if String.startsWith "0x" s then
        String.dropLeft 2 s

    else if String.startsWith "0X" s then
        String.dropLeft 2 s

    else
        s


intToHex : Int -> String
intToHex n =
    if n == 0 then
        "0"

    else
        intToHexHelper n ""


intToHexHelper : Int -> String -> String
intToHexHelper n acc =
    if n == 0 then
        acc

    else
        let
            digit =
                modBy 16 n

            char =
                case digit of
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
        in
        intToHexHelper (n // 16) (char ++ acc)


stringToUtf8Hex : String -> String
stringToUtf8Hex s =
    s
        |> String.toList
        |> List.concatMap charToUtf8Bytes
        |> List.map byteToHex
        |> String.concat


byteToHex : Int -> String
byteToHex b =
    let
        hi =
            b // 16

        lo =
            modBy 16 b
    in
    hexNibble hi ++ hexNibble lo


hexNibble : Int -> String
hexNibble n =
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


{-| Encode an Elm `Char` as one or more UTF-8 bytes. Elm's `Char` is a Unicode
code point (full 21-bit range), so we handle the full UTF-8 length table:

  - `< 0x80`     -> 1 byte
  - `< 0x800`    -> 2 bytes
  - `< 0x10000`  -> 3 bytes
  - `<= 0x10FFFF` -> 4 bytes

-}
charToUtf8Bytes : Char -> List Int
charToUtf8Bytes c =
    let
        cp =
            Char.toCode c
    in
    if cp < 0x80 then
        [ cp ]

    else if cp < 0x0800 then
        [ 0xC0 + (cp // 64)
        , 0x80 + modBy 64 cp
        ]

    else if cp < 0x00010000 then
        [ 0xE0 + (cp // 4096)
        , 0x80 + modBy 64 (cp // 64)
        , 0x80 + modBy 64 cp
        ]

    else
        [ 0xF0 + (cp // 0x00040000)
        , 0x80 + modBy 64 (cp // 4096)
        , 0x80 + modBy 64 (cp // 64)
        , 0x80 + modBy 64 cp
        ]
