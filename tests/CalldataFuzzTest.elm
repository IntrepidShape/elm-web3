module CalldataFuzzTest exposing (suite)

{-| Structural / round-trip fuzz tests for Web3.Abi.Calldata.

`CalldataTest` pins down concrete `cast`-derived vectors. This module fuzzes the
*invariants that must hold for every input* — the properties that catch a
head/tail offset bug the fixed vectors would miss (backlog #3: "head/tail offset
correctness for dynamic types; static vs dynamic boundary").

Properties:

1.  **Universal shape.** For any slot list, `calldata sel slots` is
    `"0x" ++ sel ++ body` where `body` is lowercase hex whose length is a
    multiple of 64 (one 32-byte ABI word). Nothing is ever emitted mis-aligned.

2.  **Static round-trip.** A list of `uint256` slots is pure head, no tail:
    decoding each 32-byte word back to a `BigInt` recovers the input exactly —
    `decode ∘ encode = id` for the static case, on multi-limb values.

3.  **Dynamic head/tail offset correctness.** For a list of `string` slots, the
    head is N offset words; each offset must be a multiple of 32, start at the
    head size `32*N`, strictly increase, stay in bounds, and the length word at
    each offset must equal the string's byte length with the content bytes
    intact. A mis-computed offset or length breaks this.

Selector is fixed to `"deadbeef"` (8 hex chars) so the body starts at index 10.

-}

import Expect
import Fuzz exposing (Fuzzer)
import Test exposing (..)
import Web3.Abi.Calldata as C
import Web3.BigInt as B exposing (BigInt)


sel : String
sel =
    "deadbeef"


suite : Test
suite =
    describe "Web3.Abi.Calldata fuzz"
        [ universalShapeTests
        , staticRoundTripTests
        , dynamicOffsetTests
        ]



-- HELPERS


{-| The parameter body: everything after "0x" + the 8-char selector.
-}
bodyOf : String -> String
bodyOf out =
    String.dropLeft 10 out


{-| The i-th 32-byte word (64 hex chars) of a body.
-}
wordAt : Int -> String -> String
wordAt i body =
    String.slice (i * 64) (i * 64 + 64) body


hexDigit : Char -> Int
hexDigit c =
    let
        code =
            Char.toCode c
    in
    if code >= 0x30 && code <= 0x39 then
        code - 0x30

    else if code >= 0x61 && code <= 0x66 then
        (code - 0x61) + 10

    else if code >= 0x41 && code <= 0x46 then
        (code - 0x41) + 10

    else
        0


{-| Parse a (small) hex word to an Int. Used for offsets and length prefixes,
which are always well within Int range for fuzzed inputs.
-}
hexToInt : String -> Int
hexToInt s =
    String.foldl (\c acc -> acc * 16 + hexDigit c) 0 s


isLowerHex : String -> Bool
isLowerHex s =
    String.all
        (\c ->
            let
                code =
                    Char.toCode c
            in
            (code >= 0x30 && code <= 0x39) || (code >= 0x61 && code <= 0x66)
        )
        s


{-| Printable-ASCII string (so 1 char = 1 UTF-8 byte, keeping the expected
byte-length/content arithmetic exact without re-deriving UTF-8 here).
-}
asciiStringFuzzer : Fuzzer String
asciiStringFuzzer =
    Fuzz.list (Fuzz.intRange 32 126 |> Fuzz.map Char.fromCode)
        |> Fuzz.map String.fromList


asciiHex : String -> String
asciiHex s =
    s
        |> String.toList
        |> List.map
            (\c ->
                let
                    b =
                        Char.toCode c

                    nib n =
                        String.slice n (n + 1) "0123456789abcdef"
                in
                nib (b // 16) ++ nib (modBy 16 b)
            )
        |> String.concat


{-| A non-negative multi-limb BigInt below 2^256, built via the public API.
-}
bigIntFuzzer : Fuzzer BigInt
bigIntFuzzer =
    Fuzz.listOfLengthBetween 1 8 (Fuzz.intRange 0 999999999)
        |> Fuzz.map
            (List.foldl
                (\limb acc -> B.add (B.mul acc (B.fromInt 1000000000)) (B.fromInt limb))
                B.zero
            )



-- 1. UNIVERSAL SHAPE


universalShapeTests : Test
universalShapeTests =
    describe "universal shape"
        [ fuzz (Fuzz.list slotFuzzer) "starts with 0x + selector; body is lowercase hex, 32-byte aligned" <|
            \slots ->
                let
                    out =
                        C.calldata sel slots

                    body =
                        bodyOf out
                in
                Expect.all
                    [ \_ -> String.startsWith ("0x" ++ sel) out |> Expect.equal True
                    , \_ -> isLowerHex body |> Expect.equal True
                    , \_ -> modBy 64 (String.length body) |> Expect.equal 0
                    ]
                    ()
        ]


{-| A grab-bag of static and dynamic slots to stress the mixed head/tail layout.
-}
slotFuzzer : Fuzzer C.Slot
slotFuzzer =
    Fuzz.oneOf
        [ Fuzz.map C.uint256 bigIntFuzzer
        , Fuzz.map C.bool Fuzz.bool
        , Fuzz.map C.string asciiStringFuzzer
        , Fuzz.map (C.list C.uint256) (Fuzz.list bigIntFuzzer)
        ]



-- 2. STATIC ROUND-TRIP


staticRoundTripTests : Test
staticRoundTripTests =
    describe "static uint256 round-trip"
        [ fuzz (Fuzz.list bigIntFuzzer) "each uint256 word decodes back to its input" <|
            \values ->
                let
                    body =
                        C.calldata sel (List.map C.uint256 values)
                            |> bodyOf

                    recovered =
                        List.indexedMap
                            (\i _ ->
                                B.fromHexString ("0x" ++ wordAt i body)
                            )
                            values

                    expected =
                        List.map Just values
                in
                -- compare via decimal strings so equality is structural
                List.map (Maybe.map B.toString) recovered
                    |> Expect.equal (List.map (Maybe.map B.toString) expected)
        , fuzz (Fuzz.list bigIntFuzzer) "all-static body length is exactly 64 hex per value (no tail)" <|
            \values ->
                C.calldata sel (List.map C.uint256 values)
                    |> bodyOf
                    |> String.length
                    |> Expect.equal (64 * List.length values)
        ]



-- 3. DYNAMIC HEAD/TAIL OFFSET CORRECTNESS


dynamicOffsetTests : Test
dynamicOffsetTests =
    describe "dynamic string head/tail offsets"
        [ fuzz (Fuzz.list asciiStringFuzzer) "offsets are aligned, start at head size, strictly increase, in bounds; length+content correct" <|
            \strings ->
                let
                    n =
                        List.length strings

                    body =
                        C.calldata sel (List.map C.string strings)
                            |> bodyOf

                    totalBytes =
                        String.length body // 2

                    -- byte-offset held in head word i
                    offsets =
                        List.indexedMap (\i _ -> hexToInt (wordAt i body)) strings

                    checkOne : Int -> String -> Expect.Expectation
                    checkOne offset s =
                        let
                            -- hex index of this tail entry (2 hex chars per byte)
                            hexStart =
                                offset * 2

                            lenWord =
                                String.slice hexStart (hexStart + 64) body

                            declaredLen =
                                hexToInt lenWord

                            contentHex =
                                String.slice (hexStart + 64) (hexStart + 64 + String.length s * 2) body
                        in
                        Expect.all
                            [ \_ -> modBy 32 offset |> Expect.equal 0
                            , \_ -> (offset <= totalBytes) |> Expect.equal True
                            , \_ -> declaredLen |> Expect.equal (String.length s)
                            , \_ -> contentHex |> Expect.equal (asciiHex s)
                            ]
                            ()

                    firstOffsetOk =
                        case offsets of
                            [] ->
                                Expect.pass

                            first :: _ ->
                                first |> Expect.equal (n * 32)

                    strictlyIncreasing =
                        List.map2 Tuple.pair offsets (List.drop 1 offsets)
                            |> List.all (\( a, b ) -> b > a)
                in
                Expect.all
                    [ \_ -> firstOffsetOk
                    , \_ -> strictlyIncreasing |> Expect.equal True
                    , \_ -> batchExpect (List.map2 checkOne offsets strings)
                    ]
                    ()
        ]


{-| Fold a list of expectations into one: passes only if all pass.
-}
batchExpect : List Expect.Expectation -> Expect.Expectation
batchExpect exps =
    case exps of
        [] ->
            Expect.pass

        _ ->
            Expect.all (List.map (\e -> \() -> e) exps) ()
