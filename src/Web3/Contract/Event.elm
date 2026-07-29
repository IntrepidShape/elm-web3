module Web3.Contract.Event exposing
    ( GetLogsQuery
    , getLogs
    , EventLog
    , logsDecoder
    )

{-| Historical contract event queries via `eth_getLogs`.

This module answers "what happened?" -- it fetches a bounded block range in
one request and hands back the logs that matched. For "what is happening
now?", use [`Web3.Subscription`](Web3-Subscription), which opens a
long-lived `eth_subscribe` push over a WebSocket.

    -- every Transfer this token emitted between block 1000 and head
    Event.getLogs
        { contract = tokenAddress
        , fromBlock = T.BlockNum 1000
        , toBlock = T.Latest
        , topics = [ Just transferTopic ]
        }
        |> web3Cmd

    -- ...and the reply, { tag: "logs", logs: [...] }
    D.decodeValue (Event.logsDecoder D.string) portValue


# Queries

@docs GetLogsQuery, getLogs


# Reading logs back

@docs EventLog, logsDecoder


# Live subscriptions live elsewhere

This module used to also expose a `watchEvent` command. It emitted the
`watchEvent` cmd tag with a payload the shim does not read -- the contract
address under a `contract` key the handler never looks at, and no
subscription id -- so the shim subscribed with `address: undefined`, which
is a subscription to every log on the chain, keyed under `undefined`. Its
log decoder read a `contract` field the `eventLog` reply has never had, so
it could not have decoded an event even if a correct one had arrived.

[`Web3.Subscription`](Web3-Subscription) already spoke that wire format
correctly and offers nothing less: `Subscription.logs |> atAddress |>
withTopic |> open sid`. It is now the single owner of the `watchEvent` cmd
tag, which is what `scripts/check-port-parity.ts` enforces. Migrate with:

    -- before (never worked)
    Event.watchEvent
        { contract = tokenAddress, event = "Transfer", topics = [ Just transferTopic ] }

    -- after
    Subscription.logs
        |> Subscription.atAddress tokenAddress
        |> Subscription.withTopic 0 transferTopic
        |> Subscription.open (Subscription.subscriptionId "token:Transfer")

Note that `event = "Transfer"` had no counterpart: nothing on either side of
the boundary hashed an event name into topic 0. Topic 0 is the keccak256 of
the event signature and you must supply it -- see
[`Web3.Crypto.keccak256`](Web3-Crypto#keccak256).

-}

import Json.Decode as D
import Json.Encode as E
import Web3.Types as T


{-| A bounded `eth_getLogs` query. `topics` is positional: index 0 is the
event signature hash, indices 1-3 are the indexed parameters in declaration
order, and `Nothing` at a position means "match anything".

Public RPC providers cap the block span they will serve (commonly 10k
blocks, sometimes far less) and reject the whole request rather than
truncating it. Page a wide range yourself.

-}
type alias GetLogsQuery =
    { contract : T.Address
    , fromBlock : T.BlockNumber
    , toBlock : T.BlockNumber
    , topics : List (Maybe String)
    }


{-| Encode a `getLogs` query for the JS port. The reply arrives as
`{ tag: "logs", logs: [...] }` -- read it with
[`logsDecoder`](#logsDecoder).

The field names below are the ones the shim's `getLogs` handler reads
(`cmd.contract`, `cmd.fromBlock`, `cmd.toBlock`, `cmd.topics`); the
regression suite pins the exact key set.

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


{-| One decoded log from a `getLogs` reply.

`data` is whatever your decoder makes of the log's non-indexed payload; the
port sends it as a hex string, so `D.string` is the usual choice and the ABI
decoding happens after.

There is deliberately no `removed` field here. The shim's `logs` reply drops
the reorg flag, so any value this module reported would be a constant rather
than a fact. The live path does carry it -- see
[`Web3.Subscription.LogEvent`](Web3-Subscription#LogEvent).

-}
type alias EventLog a =
    { data : a
    , contract : T.Address
    , topics : List String
    , blockNumber : Int
    , txHash : T.TxHash
    , logIndex : Int
    }


{-| Decode the `{ tag: "logs", logs: [...] }` reply to
[`getLogs`](#getLogs) with a decoder for each log's `data`.

Each entry uses the field names the shim's `getLogs` handler builds
(`contract`, `txHash`), which are NOT the names on the live `eventLog` push
(`address`, `transactionHash`). That asymmetry is the shim's, not this
module's; decoding the live push is
[`Web3.Subscription.eventDecoder`](Web3-Subscription#eventDecoder)'s job.

-}
logsDecoder : D.Decoder a -> D.Decoder (List (EventLog a))
logsDecoder dataDecoder =
    D.field "logs" (D.list (logDecoder dataDecoder))



-- INTERNAL


logDecoder : D.Decoder a -> D.Decoder (EventLog a)
logDecoder dataDecoder =
    D.map6 EventLog
        (D.field "data" dataDecoder)
        (D.field "contract" addressDecoder)
        (D.field "topics" (D.list D.string))
        (D.field "blockNumber" D.int)
        (D.field "txHash" txHashDecoder)
        (D.field "logIndex" D.int)


addressDecoder : D.Decoder T.Address
addressDecoder =
    D.string
        |> D.andThen
            (\s ->
                case T.address s of
                    Just a ->
                        D.succeed a

                    Nothing ->
                        D.fail ("Invalid contract address: " ++ s)
            )


txHashDecoder : D.Decoder T.TxHash
txHashDecoder =
    D.string
        |> D.andThen
            (\s ->
                case T.txHash s of
                    Just h ->
                        D.succeed h

                    Nothing ->
                        D.fail ("Invalid txHash: " ++ s)
            )
