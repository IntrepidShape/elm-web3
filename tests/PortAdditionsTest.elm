module PortAdditionsTest exposing (suite)

{-| Wire-pair tests for the 1.3.0 additions: each new encoder's tag matches
the port case, and each new decoder round-trips the exact JSON the port
sends (shapes verified against js/elm-web3-ports.ts).
-}

import Expect
import Json.Decode as D
import Json.Encode as E
import Test exposing (..)
import Web3.BigInt as BigInt
import Web3.Block as Block
import Web3.Fee as Fee
import Web3.Sign as Sign


tagOf : E.Value -> Result D.Error String
tagOf =
    D.decodeValue (D.field "tag" D.string)


suite : Test
suite =
    describe "1.3.0 port additions"
        [ test "Fee.getMaxPriorityFee encodes tag getMaxPriorityFee + id" <|
            \_ ->
                Fee.getMaxPriorityFee "tip-1"
                    |> tagOf
                    |> Expect.equal (Ok "getMaxPriorityFee")
        , test "Fee.maxPriorityFeeDecoder round-trips the port's maxPriorityFee message" <|
            \_ ->
                E.object
                    [ ( "tag", E.string "maxPriorityFee" )
                    , ( "id", E.string "tip-1" )
                    , ( "wei", E.string "1500000000" )
                    ]
                    |> D.decodeValue Fee.maxPriorityFeeDecoder
                    |> Result.map (\( id, wei ) -> ( id, BigInt.toString wei ))
                    |> Expect.equal (Ok ( "tip-1", "1500000000" ))
        , test "Fee.maxPriorityFeeDecoder rejects other tags" <|
            \_ ->
                E.object
                    [ ( "tag", E.string "gasPrice" )
                    , ( "id", E.string "x" )
                    , ( "wei", E.string "1" )
                    ]
                    |> D.decodeValue Fee.maxPriorityFeeDecoder
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        , test "Sign.verify encodes tag ecRecover with id/message/signature" <|
            \_ ->
                let
                    v =
                        Sign.verify { id = "login-1", message = "hi", signature = "0xsig" }

                    field name =
                        D.decodeValue (D.field name D.string) v
                in
                ( tagOf v, field "message", field "signature" )
                    |> Expect.equal ( Ok "ecRecover", Ok "hi", Ok "0xsig" )
        , test "Sign.recoveredDecoder round-trips the port's recovered message" <|
            \_ ->
                E.object
                    [ ( "tag", E.string "recovered" )
                    , ( "id", E.string "login-1" )
                    , ( "address", E.string "0xbeefcafe1234deadbeefcafe1234deadbeefcafe" )
                    ]
                    |> D.decodeValue Sign.recoveredDecoder
                    |> Expect.equal
                        (Ok { id = "login-1", address = "0xbeefcafe1234deadbeefcafe1234deadbeefcafe" })
        , test "Block.unwatchBlockNumber encodes tag unwatchBlockNumber + id" <|
            \_ ->
                Block.unwatchBlockNumber "blocks-1"
                    |> tagOf
                    |> Expect.equal (Ok "unwatchBlockNumber")
        ]
