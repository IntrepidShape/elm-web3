module ContractEventTest exposing (suite)

{-| Wire-contract tests for the log boundary: the `watchEvent` cmd, the
`eventLog` push, the `getLogs` cmd, and the `logs` reply.

Every fixture below is copied verbatim from the shim's own source
(js/elm-web3-ports.ts) rather than from what the Elm side hoped to receive.
That distinction is the whole point: `Web3.Contract.Event` carried a
`watchEvent` encoder that omitted the subscription id and put the address
under a `contract` key the handler never reads, plus a log decoder that read
a `contract` field the `eventLog` reply has never had. Both survived because
nothing ever compared either side to the shim.

`Web3.Subscription` is now the only owner of the `watchEvent` cmd tag; port
parity (CMD-3) enforces that there is exactly one, and the tests here pin
the payload that one emitter produces.

-}

import Expect
import Json.Decode as D
import Json.Encode as E
import Test exposing (..)
import Web3.Contract.Event as Event
import Web3.Subscription as Sub
import Web3.Types as T


addrString : String
addrString =
    "0x1111111111111111111111111111111111111111"


txHashString : String
txHashString =
    "0x" ++ String.repeat 64 "a"


transferTopic : String
transferTopic =
    "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"


withAddr : (T.Address -> Expect.Expectation) -> Expect.Expectation
withAddr f =
    case T.address addrString of
        Just a ->
            f a

        Nothing ->
            Expect.fail "fixture address failed validation"


{-| Sorted key set of an encoded cmd. Field NAMES are the whole defect
class here, so the assertions compare names, not just presence.
-}
keysOf : E.Value -> Result D.Error (List String)
keysOf =
    D.decodeValue (D.keyValuePairs D.value |> D.map (List.map Tuple.first >> List.sort))


{-| The live push, verbatim from the shim's WS handler and its polling
fallback -- both build this identical object.
-}
eventLogReply : Bool -> E.Value
eventLogReply removed =
    E.object
        [ ( "tag", E.string "eventLog" )
        , ( "id", E.string "token:Transfer" )
        , ( "address", E.string addrString )
        , ( "topics", E.list E.string [ transferTopic ] )
        , ( "data", E.string "0x2a" )
        , ( "blockNumber", E.int 1234 )
        , ( "logIndex", E.int 7 )
        , ( "transactionHash", E.string txHashString )
        , ( "removed", E.bool removed )
        ]


{-| The historical batch, verbatim from the shim's `getLogs` handler. Note
the different field names for the same two values: `contract` where the
push says `address`, `txHash` where the push says `transactionHash`.
-}
logsReply : E.Value
logsReply =
    E.object
        [ ( "tag", E.string "logs" )
        , ( "logs"
          , E.list identity
                [ E.object
                    [ ( "contract", E.string addrString )
                    , ( "data", E.string "0x2a" )
                    , ( "topics", E.list E.string [ transferTopic ] )
                    , ( "blockNumber", E.int 1234 )
                    , ( "txHash", E.string txHashString )
                    , ( "logIndex", E.int 7 )
                    ]
                ]
          )
        ]


suite : Test
suite =
    describe "log boundary <-> shim wire contract"
        [ describe "watchEvent cmd (Web3.Subscription is the sole emitter)"
            [ test "carries a subscription id the shim can key its map on" <|
                \_ ->
                    withAddr
                        (\a ->
                            Sub.logs
                                |> Sub.atAddress a
                                |> Sub.open (Sub.subscriptionId "token:Transfer")
                                |> D.decodeValue (D.field "id" D.string)
                                |> Expect.equal (Ok "token:Transfer")
                        )
            , test "puts the contract under address -- the key the handler reads" <|
                \_ ->
                    withAddr
                        (\a ->
                            Sub.logs
                                |> Sub.atAddress a
                                |> Sub.open (Sub.subscriptionId "token:Transfer")
                                |> D.decodeValue (D.field "address" D.string)
                                |> Expect.equal (Ok addrString)
                        )
            , test "emits exactly the key set the handler reads, and no more" <|
                \_ ->
                    withAddr
                        (\a ->
                            Sub.logs
                                |> Sub.atAddress a
                                |> Sub.withTopic 0 transferTopic
                                |> Sub.open (Sub.subscriptionId "token:Transfer")
                                |> keysOf
                                |> Expect.equal (Ok [ "address", "id", "tag", "topics" ])
                        )
            , test "an unaddressed filter still sends the address key, as null" <|
                \_ ->
                    Sub.logs
                        |> Sub.open (Sub.subscriptionId "everything")
                        |> keysOf
                        |> Expect.equal (Ok [ "address", "id", "tag", "topics" ])
            , test "tag is watchEvent" <|
                \_ ->
                    Sub.logs
                        |> Sub.open (Sub.subscriptionId "s")
                        |> D.decodeValue (D.field "tag" D.string)
                        |> Expect.equal (Ok "watchEvent")
            ]
        , describe "eventLog push"
            [ test "decodes the shim's actual reply, routed by subscription id" <|
                \_ ->
                    eventLogReply False
                        |> D.decodeValue Sub.eventDecoder
                        |> Result.map
                            (\( sid, log ) ->
                                ( Sub.subscriptionIdToString sid
                                , ( T.addressToString log.address, log.blockNumber )
                                )
                            )
                        |> Expect.equal (Ok ( "token:Transfer", ( addrString, 1234 ) ))
            , test "surfaces the reorg flag instead of dropping it" <|
                \_ ->
                    eventLogReply True
                        |> D.decodeValue Sub.eventDecoder
                        |> Result.map (Tuple.second >> .removed)
                        |> Expect.equal (Ok True)
            , test "reads transactionHash, the name the push actually uses" <|
                \_ ->
                    eventLogReply False
                        |> D.decodeValue Sub.eventDecoder
                        |> Result.map (Tuple.second >> .transactionHash)
                        |> Expect.equal (Ok txHashString)
            ]
        , describe "getLogs cmd"
            [ test "emits exactly the key set the handler reads" <|
                \_ ->
                    withAddr
                        (\a ->
                            Event.getLogs
                                { contract = a
                                , fromBlock = T.BlockNum 1
                                , toBlock = T.Latest
                                , topics = []
                                }
                                |> keysOf
                                |> Expect.equal (Ok [ "contract", "fromBlock", "tag", "toBlock", "topics" ])
                        )
            , test "block numbers go out in the shape blockNumberToHex accepts" <|
                \_ ->
                    withAddr
                        (\a ->
                            Event.getLogs
                                { contract = a
                                , fromBlock = T.BlockNum 1000
                                , toBlock = T.Latest
                                , topics = []
                                }
                                |> D.decodeValue
                                    (D.map2 Tuple.pair
                                        (D.field "fromBlock" D.int)
                                        (D.field "toBlock" D.string)
                                    )
                                |> Expect.equal (Ok ( 1000, "latest" ))
                        )
            , test "an unconstrained topic position goes out as null, not as a gap" <|
                \_ ->
                    withAddr
                        (\a ->
                            Event.getLogs
                                { contract = a
                                , fromBlock = T.Earliest
                                , toBlock = T.Latest
                                , topics = [ Just transferTopic, Nothing ]
                                }
                                |> D.decodeValue (D.field "topics" (D.list (D.nullable D.string)))
                                |> Expect.equal (Ok [ Just transferTopic, Nothing ])
                        )
            ]
        , describe "logs reply"
            [ test "logsDecoder decodes the shim's actual batch" <|
                \_ ->
                    logsReply
                        |> D.decodeValue (Event.logsDecoder D.string)
                        |> Result.map
                            (List.map
                                (\log ->
                                    ( T.addressToString log.contract
                                    , ( T.txHashToString log.txHash, log.blockNumber, log.data )
                                    )
                                )
                            )
                        |> Expect.equal (Ok [ ( addrString, ( txHashString, 1234, "0x2a" ) ) ])
            , test "an invalid address in the batch fails loudly rather than decoding" <|
                \_ ->
                    E.object
                        [ ( "tag", E.string "logs" )
                        , ( "logs"
                          , E.list identity
                                [ E.object
                                    [ ( "contract", E.string "0xnope" )
                                    , ( "data", E.string "0x2a" )
                                    , ( "topics", E.list E.string [] )
                                    , ( "blockNumber", E.int 1 )
                                    , ( "txHash", E.string txHashString )
                                    , ( "logIndex", E.int 0 )
                                    ]
                                ]
                          )
                        ]
                        |> D.decodeValue (Event.logsDecoder D.string)
                        |> Result.toMaybe
                        |> Expect.equal Nothing
            , test "TRIPWIRE the batch reply is NOT the push shape -- if the shim ever canonicalises its logs reply onto address/transactionHash, this fails and logsDecoder must move with it" <|
                \_ ->
                    eventLogReply False
                        |> D.decodeValue (Event.logsDecoder D.string)
                        |> Result.toMaybe
                        |> Expect.equal Nothing
            ]
        ]
