module Web3.Contract.Event exposing
    ( EventFilter
    , watchEvent
    , encode
    , decoder
    , EventLog
    , GetLogsQuery
    , getLogs
    , logsDecoder
    )

{-| Contract event watching via port subscriptions.

    -- Subscribe to Transfer events
    subscriptions model =
        Event.watchEvent
            { contract = tokenAddress
            , event = "Transfer"
            , filter = []
            }
            |> Event.decoder transferDecoder
            |> onContractEvent TransferReceived

@docs EventFilter, EventLog, GetLogsQuery
@docs watchEvent, encode, decoder
@docs getLogs, logsDecoder

-}

import Json.Decode as D
import Json.Encode as E
import Web3.Types as T


{-| An event subscription filter.
-}
type alias EventFilter =
    { contract : T.Address
    , event : String
    , topics : List (Maybe String)
    }


{-| A decoded event log.
-}
type alias EventLog a =
    { data : a
    , contract : T.Address
    , topics : List String
    , blockNumber : Int
    , txHash : T.TxHash
    , logIndex : Int
    }


{-| Create an event watch command.
-}
watchEvent : EventFilter -> E.Value
watchEvent filter =
    E.object
        [ ( "tag", E.string "watchEvent" )
        , ( "contract", E.string (T.addressToString filter.contract) )
        , ( "event", E.string filter.event )
        , ( "topics", E.list (Maybe.map E.string >> Maybe.withDefault E.null) filter.topics )
        ]


{-| Encode an event filter for the JS port.
-}
encode : EventFilter -> E.Value
encode =
    watchEvent


{-| Decode a `watchEvent` log from the JS port.

Requires the message to have `tag: "eventLog"` — use `logsDecoder` for
the batch `getLogs` response which wraps logs in an array.

-}
decoder : D.Decoder a -> D.Decoder (EventLog a)
decoder dataDecoder =
    D.field "tag" D.string
        |> D.andThen
            (\tag ->
                case tag of
                    "eventLog" ->
                        logDecoder dataDecoder

                    _ ->
                        D.fail ("Expected 'eventLog' tag, got: " ++ tag)
            )


logDecoder : D.Decoder a -> D.Decoder (EventLog a)
logDecoder dataDecoder =
    D.map6 EventLog
        (D.field "data" dataDecoder)
        (D.field "contract" D.string
            |> D.andThen
                (\s ->
                    case T.address s of
                        Just addr ->
                            D.succeed addr

                        Nothing ->
                            D.fail ("Invalid contract address: " ++ s)
                )
        )
        (D.field "topics" (D.list D.string))
        (D.field "blockNumber" D.int)
        (D.field "txHash" D.string
            |> D.andThen
                (\s ->
                    case T.txHash s of
                        Just h ->
                            D.succeed h

                        Nothing ->
                            D.fail ("Invalid txHash: " ++ s)
                )
        )
        (D.field "logIndex" D.int)


{-| A query for getLogs with fromBlock/toBlock range.
-}
type alias GetLogsQuery =
    { contract : T.Address
    , fromBlock : T.BlockNumber
    , toBlock : T.BlockNumber
    , topics : List (Maybe String)
    }


{-| Encode a getLogs query for the JS port.
-}
getLogs : GetLogsQuery -> E.Value
getLogs query =
    E.object
        [ ( "tag", E.string "getLogs" )
        , ( "contract", E.string (T.addressToString query.contract) )
        , ( "fromBlock", T.encodeBlockNumber query.fromBlock )
        , ( "toBlock", T.encodeBlockNumber query.toBlock )
        , ( "topics", E.list (Maybe.map E.string >> Maybe.withDefault E.null) query.topics )
        ]


{-| Decode a list of event logs with a custom data decoder.

Decodes the `{ tag: "logs", logs: [...] }` response from `getLogs`.

-}
logsDecoder : D.Decoder a -> D.Decoder (List (EventLog a))
logsDecoder dataDecoder =
    D.field "logs" (D.list (logDecoder dataDecoder))
