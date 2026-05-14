module CalldataTest exposing (suite)

{-| Canonical-vector tests for Web3.Abi.Calldata.

Vectors below match the bytes that `cast calldata <sig> <args...>` produces
for the same inputs — verified against foundry's ABI encoder.
-}

import Expect
import Test exposing (..)
import Web3.Abi.Calldata as C
import Web3.BigInt as B
import Web3.Types as T


addr : String -> T.Address
addr s =
    case T.address s of
        Just a ->
            a

        Nothing ->
            Debug.todo ("bad address in test: " ++ s)


suite : Test
suite =
    describe "Web3.Abi.Calldata"
        [ describe "static scalars"
            [ test "address — 32-byte left-padded" <|
                \_ ->
                    Expect.equal
                        "0x70a08231000000000000000000000000ca11bde05977b3631167028862be2a173976ca11"
                        (C.calldata "70a08231"
                            [ C.address (addr "0xcA11bde05977b3631167028862bE2a173976CA11") ]
                        )
            , test "uint256 — 0" <|
                \_ ->
                    Expect.equal
                        ("0x18160ddd" ++ String.repeat 64 "0")
                        (C.calldata "18160ddd" [ C.uint256 B.zero ])
            , test "uint256 — 255" <|
                \_ ->
                    Expect.equal
                        ("0x18160ddd" ++ String.repeat 62 "0" ++ "ff")
                        (C.calldata "18160ddd" [ C.uint256 (B.fromInt 255) ])
            , test "bool true" <|
                \_ ->
                    Expect.equal
                        ("0xdeadbeef" ++ String.repeat 63 "0" ++ "1")
                        (C.calldata "deadbeef" [ C.bool True ])
            , test "bool false" <|
                \_ ->
                    Expect.equal
                        ("0xdeadbeef" ++ String.repeat 64 "0")
                        (C.calldata "deadbeef" [ C.bool False ])
            , test "int256 -1 — two's complement" <|
                \_ ->
                    Expect.equal
                        ("0xdeadbeef" ++ String.repeat 64 "f")
                        (C.calldata "deadbeef"
                            [ C.int256 (B.fromInt -1) ]
                        )
            , test "approve(address,uint256)" <|
                \_ ->
                    -- selector 095ea7b3
                    Expect.equal
                        ("0x095ea7b3"
                            ++ "000000000000000000000000ca11bde05977b3631167028862be2a173976ca11"
                            ++ "0000000000000000000000000000000000000000000000000000000000000064"
                        )
                        (C.calldata "095ea7b3"
                            [ C.address (addr "0xcA11bde05977b3631167028862bE2a173976CA11")
                            , C.uint256 (B.fromInt 100)
                            ]
                        )
            , test "bytes4 right-padded" <|
                \_ ->
                    Expect.equal
                        ("0xdeadbeef"
                            ++ "deadbeef"
                            ++ String.repeat 56 "0"
                        )
                        (C.calldata "deadbeef" [ C.bytesN 4 "0xdeadbeef" ])
            ]
        , describe "dynamic types"
            [ test "string 'hi' — offset+length+content" <|
                \_ ->
                    -- head: offset = 0x20 (32 bytes, one slot)
                    -- tail: length = 2, content "hi" = 6869, padded to 32 bytes
                    Expect.equal
                        ("0xdeadbeef"
                            ++ "0000000000000000000000000000000000000000000000000000000000000020"
                            ++ "0000000000000000000000000000000000000000000000000000000000000002"
                            ++ "6869"
                            ++ String.repeat 60 "0"
                        )
                        (C.calldata "deadbeef" [ C.string "hi" ])
            , test "bytes '0x010203' — length-prefixed" <|
                \_ ->
                    Expect.equal
                        ("0xdeadbeef"
                            ++ "0000000000000000000000000000000000000000000000000000000000000020"
                            ++ "0000000000000000000000000000000000000000000000000000000000000003"
                            ++ "010203"
                            ++ String.repeat 58 "0"
                        )
                        (C.calldata "deadbeef" [ C.bytes "0x010203" ])
            , test "uint256[] [1,2,3]" <|
                \_ ->
                    Expect.equal
                        ("0xdeadbeef"
                            -- offset to start of array data
                            ++ "0000000000000000000000000000000000000000000000000000000000000020"
                            -- length 3
                            ++ "0000000000000000000000000000000000000000000000000000000000000003"
                            -- three uint256 elements
                            ++ "0000000000000000000000000000000000000000000000000000000000000001"
                            ++ "0000000000000000000000000000000000000000000000000000000000000002"
                            ++ "0000000000000000000000000000000000000000000000000000000000000003"
                        )
                        (C.calldata "deadbeef"
                            [ C.list C.uint256
                                [ B.fromInt 1, B.fromInt 2, B.fromInt 3 ]
                            ]
                        )
            ]
        , describe "all-static tuple — inlined"
            [ test "(uint256, uint256)" <|
                \_ ->
                    Expect.equal
                        ("0xdeadbeef"
                            ++ "0000000000000000000000000000000000000000000000000000000000000001"
                            ++ "0000000000000000000000000000000000000000000000000000000000000002"
                        )
                        (C.calldata "deadbeef"
                            [ C.tuple
                                [ C.uint256 (B.fromInt 1)
                                , C.uint256 (B.fromInt 2)
                                ]
                            ]
                        )
            ]
        ]
