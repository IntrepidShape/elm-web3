module CryptoTest exposing (suite)

import Expect
import Json.Decode as D
import Test exposing (..)
import Web3.Crypto as Crypto


suite : Test
suite =
    describe "Web3.Crypto"
        [ encodeTests
        , decodeTests
        ]


encodeTests : Test
encodeTests =
    describe "encode"
        [ test "keccak256 encode has correct tag" <|
            \_ ->
                Crypto.encode (Crypto.keccak256 "hello" "req-1")
                    |> D.decodeValue (D.field "tag" D.string)
                    |> Expect.equal (Ok "keccak256")
        , test "keccak256 encode has message field" <|
            \_ ->
                Crypto.encode (Crypto.keccak256 "hello" "req-1")
                    |> D.decodeValue (D.field "message" D.string)
                    |> Expect.equal (Ok "hello")
        , test "keccak256 encode has id field" <|
            \_ ->
                Crypto.encode (Crypto.keccak256 "hello" "req-1")
                    |> D.decodeValue (D.field "id" D.string)
                    |> Expect.equal (Ok "req-1")
        ]


decodeTests : Test
decodeTests =
    describe "decoder"
        [ test "keccak256Result decodes to GotKeccak256" <|
            \_ ->
                """{"tag":"keccak256Result","id":"req-1","hash":"0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8"}"""
                    |> D.decodeString Crypto.decoder
                    |> (\result ->
                            case result of
                                Ok (Crypto.GotKeccak256 id hash) ->
                                    Expect.all
                                        [ \_ -> id |> Expect.equal "req-1"
                                        , \_ -> hash |> Expect.equal "0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8"
                                        ]
                                        ()

                                _ ->
                                    Expect.fail "Expected GotKeccak256"
                       )
        ]
