module DeployTest exposing (suite)

import Expect
import Json.Decode as D
import Test exposing (..)
import Web3.Contract.Send as Send


suite : Test
suite =
    describe "Web3.Contract.Send (deploy / raw)"
        [ deployCallTests
        , encodeRawSendTests
        ]


deployCallTests : Test
deployCallTests =
    describe "deployCall"
        [ test "deployCall has tag deploy" <|
            \_ ->
                Send.deployCall { bytecode = "0x6080", args = [], gasLimit = Nothing }
                    |> D.decodeValue (D.field "tag" D.string)
                    |> Expect.equal (Ok "deploy")
        , test "deployCall has bytecode field" <|
            \_ ->
                Send.deployCall { bytecode = "0x6080", args = [], gasLimit = Nothing }
                    |> D.decodeValue (D.field "bytecode" D.string)
                    |> Expect.equal (Ok "0x6080")
        , test "deployCall does not have a to field" <|
            \_ ->
                Send.deployCall { bytecode = "0x6080", args = [], gasLimit = Nothing }
                    |> D.decodeValue (D.maybe (D.field "to" D.string))
                    |> Expect.equal (Ok Nothing)
        , test "deployCall with gasLimit includes gasLimit field" <|
            \_ ->
                Send.deployCall { bytecode = "0x6080", args = [], gasLimit = Just 300000 }
                    |> D.decodeValue (D.field "gasLimit" D.int)
                    |> Expect.equal (Ok 300000)
        , test "deployCall without gasLimit omits gasLimit field" <|
            \_ ->
                Send.deployCall { bytecode = "0x6080", args = [], gasLimit = Nothing }
                    |> D.decodeValue (D.maybe (D.field "gasLimit" D.int))
                    |> Expect.equal (Ok Nothing)
        ]


encodeRawSendTests : Test
encodeRawSendTests =
    describe "encodeRawSend"
        [ test "encodeRawSend has tag sendRawTransaction" <|
            \_ ->
                Send.encodeRawSend "0xdeadbeef"
                    |> D.decodeValue (D.field "tag" D.string)
                    |> Expect.equal (Ok "sendRawTransaction")
        , test "encodeRawSend has rawTx field" <|
            \_ ->
                Send.encodeRawSend "0xdeadbeef"
                    |> D.decodeValue (D.field "rawTx" D.string)
                    |> Expect.equal (Ok "0xdeadbeef")
        ]
