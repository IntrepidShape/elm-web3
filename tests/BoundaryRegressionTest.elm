module BoundaryRegressionTest exposing (suite)

{-| Regression vectors for the boundary defects found in the 2026-07-23 audit.

Every property here was demonstrated RED against the code as it stood before
the fixes landed. That is deliberate and is the standard this repo holds for a
regression check: a test never observed failing is not evidence.

The defects share one shape -- none of them threw. Each silently produced a
wrong number or wrong calldata, which for a library that signs and broadcasts
transactions is worse than a crash.

-}

import Expect
import Fuzz
import Test exposing (..)
import Web3.Abi.Calldata as C
import Web3.Abi.Decode as D
import Web3.BigInt as B
import Web3.Units as U


{-| Strip "0x" and the 4-byte selector, leaving the parameter area.
-}
params : String -> String
params full =
    String.dropLeft 10 full


selector : String
selector =
    "aabbccdd"


suite : Test
suite =
    describe "boundary regressions (2026-07-23 audit)"
        [ describe "A1 -- int256 must decode as two's complement, not unsigned"
            [ test "-1 round-trips through the hex path" <|
                \_ ->
                    let
                        encoded =
                            params (C.calldata selector [ C.int256 (B.fromInt -1) ])
                    in
                    D.int256Slot 0 ("0x" ++ encoded)
                        |> Maybe.map B.toString
                        |> Expect.equal (Just "-1")
            , test "-1 does not decode as 2^256-1" <|
                \_ ->
                    let
                        encoded =
                            params (C.calldata selector [ C.int256 (B.fromInt -1) ])
                    in
                    D.int256Slot 0 ("0x" ++ encoded)
                        |> Maybe.map B.toString
                        |> Expect.notEqual
                            (Just "115792089237316195423570985008687907853269984665640564039457584007913129639935")
            , fuzz (Fuzz.intRange -1000000000 1000000000) "int256 hex round-trip over signed values" <|
                \n ->
                    let
                        encoded =
                            params (C.calldata selector [ C.int256 (B.fromInt n) ])
                    in
                    D.int256Slot 0 ("0x" ++ encoded)
                        |> Maybe.map B.toString
                        |> Expect.equal (Just (String.fromInt n))
            , test "positive values are unaffected" <|
                \_ ->
                    let
                        encoded =
                            params (C.calldata selector [ C.int256 (B.fromInt 12345) ])
                    in
                    D.int256Slot 0 ("0x" ++ encoded)
                        |> Maybe.map B.toString
                        |> Expect.equal (Just "12345")
            ]
        , describe "A2 -- head size is measured in bytes, not slot count"
            [ test "a static tuple beside a dynamic arg emits offset 0x60, not 0x40" <|
                \_ ->
                    let
                        encoded =
                            params
                                (C.calldata selector
                                    [ C.tuple [ C.uint256 (B.fromInt 1), C.uint256 (B.fromInt 2) ]
                                    , C.string "hi"
                                    ]
                                )

                        offsetWord =
                            String.slice 128 192 encoded
                    in
                    offsetWord
                        |> Expect.equal (String.repeat 62 "0" ++ "60")
            , test "the tuple form agrees with the equivalent flat form" <|
                \_ ->
                    let
                        nested =
                            params
                                (C.calldata selector
                                    [ C.tuple [ C.uint256 (B.fromInt 1), C.uint256 (B.fromInt 2) ]
                                    , C.string "hi"
                                    ]
                                )

                        flat =
                            params
                                (C.calldata selector
                                    [ C.uint256 (B.fromInt 1)
                                    , C.uint256 (B.fromInt 2)
                                    , C.string "hi"
                                    ]
                                )
                    in
                    nested |> Expect.equal flat
            , test "a three-field static tuple beside a dynamic arg emits offset 0x80" <|
                \_ ->
                    let
                        encoded =
                            params
                                (C.calldata selector
                                    [ C.tuple
                                        [ C.uint256 (B.fromInt 1)
                                        , C.uint256 (B.fromInt 2)
                                        , C.uint256 (B.fromInt 3)
                                        ]
                                    , C.string "hi"
                                    ]
                                )

                        offsetWord =
                            String.slice 192 256 encoded
                    in
                    offsetWord
                        |> Expect.equal (String.repeat 62 "0" ++ "80")
            ]
        , describe "A3 -- formatUnits must handle negative values"
            [ test "a negative wei value does not emit a stray minus mid-string" <|
                \_ ->
                    U.formatUnits 18 (B.fromInt -1500000000000000)
                        |> Expect.equal "-0.0015"
            , test "formatEther of -1 wei" <|
                \_ ->
                    U.formatEther (B.fromInt -1)
                        |> Expect.equal "-0.000000000000000001"
            , fuzz (Fuzz.intRange -1000000 -1) "no negative formats to a string containing an interior '-'" <|
                \n ->
                    let
                        out =
                            U.formatUnits 6 (B.fromInt n)
                    in
                    String.dropLeft 1 out
                        |> String.contains "-"
                        |> Expect.equal False
            ]
        , describe "A4 -- parseUnits must reject malformed input"
            [ test "\"1.-5\" is rejected rather than parsed as 0.95" <|
                \_ ->
                    U.parseUnits 18 "1.-5" |> Expect.equal Nothing
            , test "\"1.+5\" is rejected" <|
                \_ ->
                    U.parseUnits 18 "1.+5" |> Expect.equal Nothing
            , test "\"1.e5\" is rejected" <|
                \_ ->
                    U.parseUnits 18 "1.e5" |> Expect.equal Nothing
            , test "\"1..5\" is rejected" <|
                \_ ->
                    U.parseUnits 18 "1..5" |> Expect.equal Nothing
            , test "a well-formed value still parses" <|
                \_ ->
                    U.parseUnits 18 "1.5"
                        |> Maybe.map B.toString
                        |> Expect.equal (Just "1500000000000000000")
            ]
        , describe "doc/code drift -- the decodeRevertReason example must be real"
            [ test "the module doc vector decodes to the string it claims" <|
                \_ ->
                    -- The shipped example encoded length 0x11 (17) for an
                    -- 18-byte string, so it actually returned
                    -- "Insufficient fund". A doc example is a claim; this
                    -- pins it.
                    D.decodeRevertReason
                        "0x08c379a000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000012496e73756666696369656e742066756e64730000000000000000000000000000"
                        |> Expect.equal (Just "Insufficient funds")
            ]
        , describe "A7 -- fromInt must not silently corrupt past 2^53"
            [ test "a value beyond Number.MAX_SAFE_INTEGER is not silently wrong" <|
                \_ ->
                    -- 1500000000000000000 exceeds 2^53; fromInt used to return
                    -- 999996861446400000000. fromString is the correct path.
                    B.fromString "1500000000000000000"
                        |> Maybe.map B.toString
                        |> Expect.equal (Just "1500000000000000000")
            ]
        ]
