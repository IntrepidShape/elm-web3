module SimulateTest exposing (suite)

import Expect
import Json.Decode as D
import Test exposing (..)
import Web3.Abi.Encode as Encode
import Web3.Contract.Call as Call
import Web3.Types as T


suite : Test
suite =
    describe "Web3.Contract.Call — withFrom (simulate)"
        [ withFromTests
        , existingCallTests
        ]


addr : String -> T.Address
addr s =
    case T.address s of
        Just a ->
            a

        Nothing ->
            Debug.todo ("Invalid test address: " ++ s)


callerAddress : T.Address
callerAddress =
    addr "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"


contractAddress : T.Address
contractAddress =
    addr "0x1111111111111111111111111111111111111111"


makeCall : Call.ReadCall String
makeCall =
    Call.readCall
        { contract = contractAddress
        , method = "balanceOf(address)"
        , args = [ Encode.address callerAddress ]
        , decoder = D.string
        , id = "test-call"
        }


withFromTests : Test
withFromTests =
    describe "withFrom"
        [ test "withFrom sets from field in encoded output" <|
            \_ ->
                makeCall
                    |> Call.withFrom callerAddress
                    |> Call.encode
                    |> D.decodeValue (D.field "from" D.string)
                    |> Expect.equal (Ok "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd")
        , test "encoded from matches the address string" <|
            \_ ->
                let
                    fromAddr =
                        addr "0x1234567890123456789012345678901234567890"
                in
                makeCall
                    |> Call.withFrom fromAddr
                    |> Call.encode
                    |> D.decodeValue (D.field "from" D.string)
                    |> Expect.equal (Ok "0x1234567890123456789012345678901234567890")
        , test "withFrom and withBlock are composable" <|
            \_ ->
                makeCall
                    |> Call.withFrom callerAddress
                    |> Call.withBlock T.Latest
                    |> Call.encode
                    |> D.decodeValue (D.field "from" D.string)
                    |> Expect.equal (Ok "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd")
        ]


existingCallTests : Test
existingCallTests =
    describe "readCall without withFrom"
        [ test "no from field when withFrom not called" <|
            \_ ->
                makeCall
                    |> Call.encode
                    |> D.decodeValue (D.maybe (D.field "from" D.string))
                    |> Expect.equal (Ok Nothing)
        , test "tag is still 'call'" <|
            \_ ->
                makeCall
                    |> Call.encode
                    |> D.decodeValue (D.field "tag" D.string)
                    |> Expect.equal (Ok "call")
        , test "withFrom does not change tag" <|
            \_ ->
                makeCall
                    |> Call.withFrom callerAddress
                    |> Call.encode
                    |> D.decodeValue (D.field "tag" D.string)
                    |> Expect.equal (Ok "call")
        , test "withFrom does not change contract" <|
            \_ ->
                makeCall
                    |> Call.withFrom callerAddress
                    |> Call.encode
                    |> D.decodeValue (D.field "contract" D.string)
                    |> Expect.equal (Ok "0x1111111111111111111111111111111111111111")
        ]
