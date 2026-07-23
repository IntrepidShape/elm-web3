module Web3.Subscription exposing
    ( SubscriptionId
    , subscriptionId
    , subscriptionIdToString
    , LogFilter
    , logs
    , atAddress
    , withTopic
    , withTopics
    , LogEvent
    , Status(..)
    , open
    , close
    , statusDecoder
    , eventDecoder
    )

{-| Push-based event subscriptions over `eth_subscribe`.

The dominant pattern for reactive dapps. Where [`Web3.Contract.Event`](Web3-Contract-Event)
fetches historical logs via `eth_getLogs`, this module opens a long-lived
WebSocket subscription so every NEW log is pushed to your update fn the
moment it lands on-chain -- no polling, no missed blocks.


# The subscription identifier

Subscriptions are tagged with an opaque [`SubscriptionId`](#SubscriptionId)
so multiple subscriptions can coexist. Pass the same id to
[`close`](#close) to stop a subscription, and match incoming
[`LogEvent`](#LogEvent)s against it to route updates.

@docs SubscriptionId, subscriptionId, subscriptionIdToString


# Building a logs filter

Subscriptions are built with a tiny pipeline: start with [`logs`](#logs),
narrow with [`atAddress`](#atAddress), [`withTopic`](#withTopic), or
[`withTopics`](#withTopics):

    factoryEvents : SubscriptionId -> Cmd msg
    factoryEvents sid =
        Subscription.logs
            |> Subscription.atAddress factoryAddress
            |> Subscription.withTopic 0 tokenCreatedTopicHash
            |> Subscription.open sid

@docs LogFilter, logs, atAddress, withTopic, withTopics


# Reading events back

@docs LogEvent, Status


# Wire format

The Cmd helpers below encode a port payload for [`elm-web3-ports.js`](https://github.com/intrepidshape/elm-web3/blob/main/js/elm-web3-ports.js)
to consume. Pair them with the decoders to interpret incoming subscription
events.

@docs open, close, statusDecoder, eventDecoder

-}

import Json.Decode as D
import Json.Encode as E
import Web3.Types as T



-- IDENTIFIERS


{-| Opaque tag identifying a subscription. Construct with
[`subscriptionId`](#subscriptionId).
-}
type SubscriptionId
    = SubscriptionId String


{-| Build a `SubscriptionId` from a label. Labels must be unique within a
session; reusing a label closes the previous subscription with the same
label.

    factorySid =
        Subscription.subscriptionId "factory:TokenCreated"

-}
subscriptionId : String -> SubscriptionId
subscriptionId =
    SubscriptionId


{-| Read the raw string back out of a `SubscriptionId`. Useful for routing
incoming events in your `update` fn.
-}
subscriptionIdToString : SubscriptionId -> String
subscriptionIdToString (SubscriptionId s) =
    s



-- LOG FILTERS


{-| Opaque, fluent builder for an `eth_subscribe("logs", ...)` filter.
-}
type LogFilter
    = LogFilter
        { address : Maybe T.Address
        , topics : List (Maybe String)
        }


{-| Start a logs filter that matches every log in every block. Refine with
[`atAddress`](#atAddress) and [`withTopic`](#withTopic) -- usually you want
both, otherwise you'll receive every event from every contract on the chain.
-}
logs : LogFilter
logs =
    LogFilter { address = Nothing, topics = [] }


{-| Narrow the filter to logs emitted by a specific contract.
-}
atAddress : T.Address -> LogFilter -> LogFilter
atAddress addr (LogFilter f) =
    LogFilter { f | address = Just addr }


{-| Match a specific topic at a given position. Topic 0 is always the event
signature hash; topics 1-3 are the event's indexed parameters in declaration
order.

    -- match ERC-20 Transfer(address indexed from, address indexed to, uint256)
    Subscription.logs
        |> Subscription.atAddress tokenAddress
        |> Subscription.withTopic 0 transferTopic
        |> Subscription.withTopic 2 myAddressTopic

-}
withTopic : Int -> String -> LogFilter -> LogFilter
withTopic position topicHash (LogFilter f) =
    LogFilter { f | topics = updateAt position (Just topicHash) f.topics }


{-| Replace the entire topics list with a pre-built list of optional topic
hashes. `Nothing` at a position means "match anything" -- use the variadic
[`withTopic`](#withTopic) for the common case.
-}
withTopics : List (Maybe String) -> LogFilter -> LogFilter
withTopics ts (LogFilter f) =
    LogFilter { f | topics = ts }



-- EVENTS


{-| A single log event pushed by the subscription.

`blockNumber` and `logIndex` are zero when unavailable (pending logs in
some node implementations). `removed` is `True` if a chain reorg made
this log no longer canonical -- your update fn should usually treat a
removed log as an "undo" of an earlier emission.

-}
type alias LogEvent =
    { address : T.Address
    , topics : List String
    , data : String
    , blockNumber : Int
    , logIndex : Int
    , transactionHash : String
    , removed : Bool
    }


{-| The high-level lifecycle of a subscription. Surfaced via
[`statusDecoder`](#statusDecoder) so you can show "connecting..." /
"reconnecting..." indicators.

  - `Opening` -- handshake in progress, no events yet.
  - `Open` -- chain push is live.
  - `Closed` -- socket closed; the runtime will retry automatically.
  - `Failed err` -- the WS endpoint refused or the chain rejected the filter;
    the runtime will NOT retry without an explicit `close + open` cycle.

-}
type Status
    = Opening
    | Open
    | Closed
    | Failed String



-- WIRE FORMAT


{-| Open the subscription. Encodes to the `watchEvent` Cmd that
[`elm-web3-ports.js`](https://github.com/intrepidshape/elm-web3/blob/main/js/elm-web3-ports.js)
consumes.
-}
open : SubscriptionId -> LogFilter -> E.Value
open (SubscriptionId sid) (LogFilter f) =
    E.object
        [ ( "tag", E.string "watchEvent" )
        , ( "id", E.string sid )
        , ( "address"
          , f.address
                |> Maybe.map (T.addressToString >> E.string)
                |> Maybe.withDefault E.null
          )
        , ( "topics"
          , E.list (Maybe.withDefault E.null << Maybe.map E.string) f.topics
          )
        ]


{-| Close an open subscription by id. The runtime stops pushing events
and (if the WS connection has no other active subscriptions) closes the
socket.
-}
close : SubscriptionId -> E.Value
close (SubscriptionId sid) =
    E.object
        [ ( "tag", E.string "unwatchEvent" )
        , ( "id", E.string sid )
        ]


{-| Decode a `{ tag: "subscribed", id, status }` port message into a
`( SubscriptionId, Status )` pair.
-}
statusDecoder : D.Decoder ( SubscriptionId, Status )
statusDecoder =
    D.map2 Tuple.pair
        (D.field "id" (D.map SubscriptionId D.string))
        (D.field "status" D.string |> D.map statusFromString)


{-| Decode a `{ tag: "eventLog", id, ... }` port message into a
`( SubscriptionId, LogEvent )` pair.
-}
eventDecoder : D.Decoder ( SubscriptionId, LogEvent )
eventDecoder =
    D.map2 Tuple.pair
        (D.field "id" (D.map SubscriptionId D.string))
        (D.map7 LogEvent
            (D.field "address" addressDecoder)
            (D.field "topics" (D.list D.string))
            (D.field "data" D.string)
            (D.field "blockNumber" D.int)
            (D.field "logIndex" D.int)
            (D.field "transactionHash" D.string)
            (D.oneOf [ D.field "removed" D.bool, D.succeed False ])
        )



-- INTERNAL


addressDecoder : D.Decoder T.Address
addressDecoder =
    D.string
        |> D.andThen
            (\s ->
                case T.address s of
                    Just a ->
                        D.succeed a

                    Nothing ->
                        D.fail ("Invalid address: " ++ s)
            )


statusFromString : String -> Status
statusFromString s =
    case s of
        "open" ->
            Open

        "closed" ->
            Closed

        "opening" ->
            Opening

        _ ->
            Failed s


{-| Set the n-th element of `xs` to `value`, padding the list with `Nothing`
to reach length `n` if necessary. Used so `withTopic 2 hash` always lands
the hash at index 2, even before topics 0 and 1 are set.
-}
updateAt : Int -> Maybe String -> List (Maybe String) -> List (Maybe String)
updateAt n value xs =
    let
        padded =
            if List.length xs > n then
                xs

            else
                xs ++ List.repeat (n + 1 - List.length xs) Nothing
    in
    padded
        |> List.indexedMap
            (\i v ->
                if i == n then
                    value

                else
                    v
            )
