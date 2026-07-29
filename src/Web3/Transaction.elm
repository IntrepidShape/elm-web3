module Web3.Transaction exposing
    ( Status(..)
    , Msg(..)
    , TxCmd(..)
    , TxId
    , Receipt
    , EventLog
    , update
    , isTerminal
    , isPending
    , transactionConfirmations
    , msgId
    , decoder
    , encodeCmd
    , parseReceiptEvents
    )

{-| Transaction lifecycle state machine.

Every transaction goes through explicit states. Pattern matching forces you to
handle every case -- no "transaction failed silently" bugs. The state machine
follows the TLA+ spec in `proofs/tla/TransactionSpec.tla`:
terminal states never transition out (except via `TxReset`),
and confirmation counts only increase.

    case tx.status of
        Idle ->
            viewBuyButton

        AwaitingSignature ->
            viewSigningSpinner

        Submitted hash ->
            viewPendingWithHash hash

        Confirming hash n ->
            viewConfirming n

        Confirmed receipt ->
            viewSuccess receipt

        RevertedOnChain receipt ->
            viewRevertedOnChain receipt

        Failed err ->
            viewError err

        Rejected ->
            viewRejected

**`Confirmed` means mined AND successful.** A transaction that was mined with
`receipt.status == false` reverted on chain: it consumed the user's gas, it is
permanently on chain, and it did not do what they asked. That is
[`RevertedOnChain`](#Status), not `Confirmed`. Before 3.0.0 both landed in
`Confirmed` and the example above rendered a revert as a success, which is
exactly the class of silent wrongness this library exists to make impossible.
`RevertedOnChain` is terminal, same as `Confirmed`.

**Correlating replies.** Tag a write with
[`Web3.Contract.Send.withId`](Web3-Contract-Send#withId) and every reply about
it -- `submitted`, `confirmation`, `confirmed`, `failed` -- carries that id
back. [`msgId`](#msgId) reads it out, so two transactions in flight at once
are told apart by the compiler rather than by guesswork:

    Web3Msg incoming ->
        case Tx.msgId incoming of
            Just id ->
                ( { model | txs = Dict.update id (Maybe.map (Tx.update incoming)) model.txs }
                , Cmd.none
                )

            Nothing ->
                ( model, Cmd.none )

To poll for a receipt after submission, encode a `RequestReceipt` command:

    case tx.status of
        Submitted hash ->
            ( model
            , web3Cmd (Tx.encodeCmd (Tx.RequestReceipt hash "my-tx"))
            )
        _ ->
            ( model, Cmd.none )

To reset a terminal transaction back to `Idle`:

    Tx.update Tx.TxReset tx.status

Related modules: `Web3.Contract.Send` to build and encode write calls;
`Web3.Contract.Call` to simulate writes before broadcasting;
`Web3.Error` for the typed failure taxonomy behind a `failed` reply.

@docs Status, Msg, TxCmd, TxId, Receipt, EventLog
@docs update, isTerminal, isPending, transactionConfirmations, msgId
@docs encodeCmd, decoder, parseReceiptEvents

-}

import Json.Decode as D
import Json.Encode as E
import Web3.Abi.Decode as AbiDecode
import Web3.Types as T


{-| Transaction lifecycle status. Cannot be in an invalid state.

`Confirmed` and `RevertedOnChain` are both mined and both terminal; they
differ on `receipt.status`, i.e. on whether the transaction did anything.

-}
type Status
    = Idle
    | AwaitingSignature
    | Submitted T.TxHash
    | Confirming T.TxHash Int
    | Confirmed Receipt
    | RevertedOnChain Receipt
    | Failed String
    | Rejected


{-| A correlation id for one write. You mint it, you attach it with
`Web3.Contract.Send.withId`, and the port echoes it on every reply about that
transaction. Any string will do as long as it is unique among the writes you
have in flight.
-}
type alias TxId =
    String


{-| A single log entry emitted during a transaction.
-}
type alias EventLog =
    { address : T.Address
    , topics : List String
    , data : String
    , blockNumber : Int
    , logIndex : Int
    }


{-| A mined transaction receipt, including emitted logs.

`status` is the EVM's own success flag: `True` for a transaction that ran to
completion, `False` for one that reverted after being mined. `contractAddress`
is `Just` only for a deployment -- it is the address the new contract landed
at, which is otherwise unrecoverable from the Elm side.

-}
type alias Receipt =
    { txHash : T.TxHash
    , blockNumber : Int
    , gasUsed : String
    , status : Bool
    , contractAddress : Maybe T.Address
    , logs : List EventLog
    }


{-| Commands to send to the JS transaction port.
-}
type TxCmd
    = RequestReceipt T.TxHash String


{-| Messages from the JS transaction port.

Every reply on the write path carries the correlation id of the write that
caused it, or `Nothing` when the write was sent without one (see
[`msgId`](#msgId)). `TxReceiptNotFound` always has an id: it answers an
explicit `RequestReceipt`, which cannot be issued without one.

-}
type Msg
    = TxSubmitted (Maybe TxId) String
    | TxConfirmation (Maybe TxId) String Int
    | TxConfirmed (Maybe TxId) ReceiptJson
    | TxFailed (Maybe TxId) String
    | TxRejected (Maybe TxId)
    | TxReset
    | TxReceiptNotFound TxId


type alias ReceiptJson =
    { txHash : String
    , blockNumber : Int
    , gasUsed : String
    , status : Bool
    , contractAddress : Maybe String
    , logs : List EventLogJson
    }


type alias EventLogJson =
    { address : String
    , topics : List String
    , data : String
    , blockNumber : Int
    , logIndex : Int
    }


{-| Update transaction status from a port message.

Transitions are guarded to match the TLA+ GuardedNext specification:
- Terminal states (Confirmed, RevertedOnChain, Failed, Rejected) never
  transition out, except via TxReset.
- TxSubmitted is only accepted from AwaitingSignature.
- TxConfirmation is only accepted from Submitted or Confirming.
- TxConfirmed lands in Confirmed when the receipt reports success and in
  RevertedOnChain when it does not.
- TxFailed is accepted from any non-terminal state.
- TxRejected from AwaitingSignature -> Rejected; from Submitted/Confirming -> Failed.
- TxReset from any terminal state -> Idle; from non-terminal states -> no-op.
- TxReceiptNotFound is a no-op; the app can schedule another RequestReceipt.

The correlation id on an incoming message is NOT consulted here: routing a
message to the right transaction is the caller's job (see [`msgId`](#msgId)),
and `update` only ever sees the status it was handed.

-}
update : Msg -> Status -> Status
update msg status =
    case msg of
        TxReset ->
            if isTerminal status then
                Idle

            else
                status

        TxReceiptNotFound _ ->
            status

        _ ->
            if isTerminal status then
                status

            else
                updateNonTerminal msg status


updateNonTerminal : Msg -> Status -> Status
updateNonTerminal msg status =
    case msg of
            TxSubmitted _ hash ->
                case status of
                    AwaitingSignature ->
                        case T.txHash hash of
                            Just h ->
                                Submitted h

                            Nothing ->
                                Failed ("Invalid tx hash: " ++ hash)

                    _ ->
                        status

            TxConfirmation _ hash count ->
                case status of
                    Submitted _ ->
                        case T.txHash hash of
                            Just h ->
                                if count >= 1 then
                                    Confirming h count

                                else
                                    status

                            Nothing ->
                                status

                    Confirming _ current ->
                        -- Confirmation counts only increase (the documented
                        -- invariant, matching MonotonicConfirmations in
                        -- proofs/tla/TransactionSpec.tla). Stale or reordered
                        -- port messages with a lower/equal count are dropped.
                        -- The hash is taken from the message: a wallet
                        -- speed-up (EIP-1559 replacement) legitimately swaps
                        -- in a new hash for the same logical transaction.
                        case T.txHash hash of
                            Just h ->
                                if count > current then
                                    Confirming h count

                                else
                                    status

                            Nothing ->
                                status

                    _ ->
                        status

            TxConfirmed _ receipt ->
                case status of
                    Submitted _ ->
                        confirmReceipt receipt

                    Confirming _ _ ->
                        confirmReceipt receipt

                    _ ->
                        status

            TxFailed _ err ->
                Failed err

            TxRejected _ ->
                case status of
                    AwaitingSignature ->
                        Rejected

                    Submitted _ ->
                        Failed "transaction rejected by wallet"

                    Confirming _ _ ->
                        Failed "transaction rejected by wallet"

                    _ ->
                        status

            TxReset ->
                status

            TxReceiptNotFound _ ->
                status


{-| Turn a receipt into the terminal state it actually describes.

`receipt.status` is the EVM's success flag. A `False` there means the
transaction was mined and then reverted -- gas spent, nothing done. It gets
its own state rather than being folded into `Confirmed`, because a UI that
cannot tell the two apart will tell the user their transaction worked.
-}
confirmReceipt : ReceiptJson -> Status
confirmReceipt receipt =
    case T.txHash receipt.txHash of
        Just h ->
            let
                decoded =
                    { txHash = h
                    , blockNumber = receipt.blockNumber
                    , gasUsed = receipt.gasUsed
                    , status = receipt.status
                    , contractAddress = Maybe.andThen T.address receipt.contractAddress
                    , logs =
                        List.filterMap
                            (\logJson ->
                                case T.address logJson.address of
                                    Just addr ->
                                        Just
                                            { address = addr
                                            , topics = logJson.topics
                                            , data = logJson.data
                                            , blockNumber = logJson.blockNumber
                                            , logIndex = logJson.logIndex
                                            }

                                    Nothing ->
                                        Nothing
                            )
                            receipt.logs
                    }
            in
            if receipt.status then
                Confirmed decoded

            else
                RevertedOnChain decoded

        Nothing ->
            Failed "Invalid receipt hash"


{-| Is this status terminal (no more updates expected)?

`RevertedOnChain` is terminal for the same reason `Confirmed` is: the
transaction is mined and the chain has spoken. Nothing further will arrive
about it.

-}
isTerminal : Status -> Bool
isTerminal status =
    case status of
        Confirmed _ ->
            True

        RevertedOnChain _ ->
            True

        Failed _ ->
            True

        Rejected ->
            True

        _ ->
            False


{-| Is this status still pending?
-}
isPending : Status -> Bool
isPending status =
    case status of
        AwaitingSignature ->
            True

        Submitted _ ->
            True

        Confirming _ _ ->
            True

        _ ->
            False


{-| Number of confirmations for a confirmed transaction given the current block number.
-}
transactionConfirmations : Int -> Receipt -> Int
transactionConfirmations currentBlock receipt =
    max 0 (currentBlock - receipt.blockNumber)


{-| Encode a TxCmd for the JS port.
-}
encodeCmd : TxCmd -> E.Value
encodeCmd (RequestReceipt hash id) =
    E.object
        [ ( "tag", E.string "getTransactionReceipt" )
        , ( "hash", E.string (T.txHashToString hash) )
        , ( "id", E.string id )
        ]


{-| The correlation id a port message was tagged with, if any.

This is what makes two transactions in flight at the same time separable: the
id you attached with `Web3.Contract.Send.withId` comes back on every reply
about that write, and nothing else in this module needs to know it exists.
`TxReset` is app-generated and never has one.

-}
msgId : Msg -> Maybe TxId
msgId msg =
    case msg of
        TxSubmitted id _ ->
            id

        TxConfirmation id _ _ ->
            id

        TxConfirmed id _ ->
            id

        TxFailed id _ ->
            id

        TxRejected id ->
            id

        TxReset ->
            Nothing

        TxReceiptNotFound id ->
            Just id


{-| Decode transaction messages from JS port.
-}
decoder : D.Decoder Msg
decoder =
    D.field "tag" D.string
        |> D.andThen
            (\tag ->
                case tag of
                    "submitted" ->
                        D.map2 TxSubmitted idField (D.field "hash" D.string)

                    "confirmation" ->
                        D.map3 TxConfirmation
                            idField
                            (D.field "hash" D.string)
                            (D.field "count" D.int)

                    "confirmed" ->
                        D.map2 TxConfirmed idField receiptJsonDecoder

                    "failed" ->
                        D.map3
                            (\id err maybeRevertData ->
                                let
                                    reason =
                                        maybeRevertData
                                            |> Maybe.andThen AbiDecode.decodeRevertReason
                                in
                                TxFailed id
                                    (case reason of
                                        Just r ->
                                            err ++ " | revert: " ++ r

                                        Nothing ->
                                            err
                                    )
                            )
                            idField
                            (D.field "error" D.string)
                            (D.maybe (D.field "revertData" D.string))

                    "rejected" ->
                        D.map TxRejected idField

                    "receiptResult" ->
                        D.map2 TxConfirmed idField receiptJsonDecoder

                    "receiptNotFound" ->
                        D.map TxReceiptNotFound (D.field "id" D.string)

                    _ ->
                        D.fail ("Unknown tx message: " ++ tag)
            )


{-| The correlation id field, absent on a write that was sent without one.
-}
idField : D.Decoder (Maybe TxId)
idField =
    D.maybe (D.field "id" D.string)


receiptJsonDecoder : D.Decoder ReceiptJson
receiptJsonDecoder =
    D.map6 ReceiptJson
        (D.field "hash" D.string)
        (D.field "blockNumber" D.int)
        (D.field "gasUsed" D.string)
        (D.field "status" D.bool)
        (D.maybe (D.field "contractAddress" D.string))
        (D.field "logs" (D.list eventLogJsonDecoder))


eventLogJsonDecoder : D.Decoder EventLogJson
eventLogJsonDecoder =
    D.map5 EventLogJson
        (D.field "address" D.string)
        (D.field "topics" (D.list D.string))
        (D.field "data" D.string)
        (D.field "blockNumber" D.int)
        (D.field "logIndex" D.int)


{-| Apply a list of event decoders to the logs in a receipt, collecting
all successfully decoded events.

    type MyEvent
        = Transfer { from : Address, to : Address, amount : BigInt }
        | Approval { owner : Address, spender : Address, amount : BigInt }

    decodeTransfer : EventLog -> Maybe MyEvent
    decodeTransfer log =
        -- match topic[0] to Transfer signature, then decode
        ...

    events : List MyEvent
    events =
        parseReceiptEvents [ decodeTransfer, decodeApproval ] receipt

-}
parseReceiptEvents : List (EventLog -> Maybe a) -> Receipt -> List a
parseReceiptEvents decoders receipt =
    List.concatMap
        (\log -> List.filterMap (\decode -> decode log) decoders)
        receipt.logs
