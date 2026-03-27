module Web3.Transaction exposing
    ( Status(..)
    , Msg(..)
    , TxCmd(..)
    , Receipt
    , EventLog
    , update
    , isTerminal
    , isPending
    , transactionConfirmations
    , decoder
    , encodeCmd
    , parseReceiptEvents
    )

{-| Transaction lifecycle state machine.

Every transaction goes through explicit states. Pattern matching forces you to
handle every case — no "transaction failed silently" bugs. The state machine
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

        Failed err ->
            viewError err

        Rejected ->
            viewRejected

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
`Web3.Contract.Call` to simulate writes before broadcasting.

@docs Status, Msg, TxCmd, Receipt, EventLog
@docs update, isTerminal, isPending, transactionConfirmations
@docs encodeCmd, decoder, parseReceiptEvents

-}

import Json.Decode as D
import Json.Encode as E
import Web3.Abi.Decode as AbiDecode
import Web3.Types as T


{-| Transaction lifecycle status. Cannot be in an invalid state.
-}
type Status
    = Idle
    | AwaitingSignature
    | Submitted T.TxHash
    | Confirming T.TxHash Int
    | Confirmed Receipt
    | Failed String
    | Rejected


{-| A single log entry emitted during a transaction.
-}
type alias EventLog =
    { address : T.Address
    , topics : List String
    , data : String
    , blockNumber : Int
    , logIndex : Int
    }


{-| A confirmed transaction receipt, including emitted logs.
-}
type alias Receipt =
    { txHash : T.TxHash
    , blockNumber : Int
    , gasUsed : String
    , status : Bool
    , logs : List EventLog
    }


{-| Commands to send to the JS transaction port.
-}
type TxCmd
    = RequestReceipt T.TxHash String


{-| Messages from the JS transaction port.
-}
type Msg
    = TxSubmitted String
    | TxConfirmation String Int
    | TxConfirmed ReceiptJson
    | TxFailed String
    | TxRejected
    | TxReset
    | TxReceiptNotFound String


type alias ReceiptJson =
    { txHash : String
    , blockNumber : Int
    , gasUsed : String
    , status : Bool
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
- Terminal states (Confirmed, Failed, Rejected) never transition out, except via TxReset.
- TxSubmitted is only accepted from AwaitingSignature.
- TxConfirmation is only accepted from Submitted or Confirming.
- TxFailed is accepted from any non-terminal state.
- TxRejected from AwaitingSignature → Rejected; from Submitted/Confirming → Failed.
- TxReset from any terminal state → Idle; from non-terminal states → no-op.
- TxReceiptNotFound is a no-op; the app can schedule another RequestReceipt.
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
            TxSubmitted hash ->
                case status of
                    AwaitingSignature ->
                        case T.txHash hash of
                            Just h ->
                                Submitted h

                            Nothing ->
                                Failed ("Invalid tx hash: " ++ hash)

                    _ ->
                        status

            TxConfirmation hash count ->
                case status of
                    Submitted _ ->
                        case T.txHash hash of
                            Just h ->
                                Confirming h count

                            Nothing ->
                                status

                    Confirming _ _ ->
                        case T.txHash hash of
                            Just h ->
                                Confirming h count

                            Nothing ->
                                status

                    _ ->
                        status

            TxConfirmed receipt ->
                case status of
                    Submitted _ ->
                        confirmReceipt receipt

                    Confirming _ _ ->
                        confirmReceipt receipt

                    _ ->
                        status

            TxFailed err ->
                Failed err

            TxRejected ->
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


confirmReceipt : ReceiptJson -> Status
confirmReceipt receipt =
    case T.txHash receipt.txHash of
        Just h ->
            Confirmed
                { txHash = h
                , blockNumber = receipt.blockNumber
                , gasUsed = receipt.gasUsed
                , status = receipt.status
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

        Nothing ->
            Failed "Invalid receipt hash"


{-| Is this status terminal (no more updates expected)?
-}
isTerminal : Status -> Bool
isTerminal status =
    case status of
        Confirmed _ ->
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


{-| Decode transaction messages from JS port.
-}
decoder : D.Decoder Msg
decoder =
    D.field "tag" D.string
        |> D.andThen
            (\tag ->
                case tag of
                    "submitted" ->
                        D.map TxSubmitted (D.field "hash" D.string)

                    "confirmation" ->
                        D.map2 TxConfirmation
                            (D.field "hash" D.string)
                            (D.field "count" D.int)

                    "confirmed" ->
                        D.map TxConfirmed
                            (D.map5 ReceiptJson
                                (D.field "hash" D.string)
                                (D.field "blockNumber" D.int)
                                (D.field "gasUsed" D.string)
                                (D.field "status" D.bool)
                                (D.field "logs" (D.list eventLogJsonDecoder))
                            )

                    "failed" ->
                        D.map2
                            (\err maybeRevertData ->
                                let
                                    reason =
                                        maybeRevertData
                                            |> Maybe.andThen AbiDecode.decodeRevertReason
                                in
                                TxFailed
                                    (case reason of
                                        Just r ->
                                            err ++ " | revert: " ++ r

                                        Nothing ->
                                            err
                                    )
                            )
                            (D.field "error" D.string)
                            (D.maybe (D.field "revertData" D.string))

                    "rejected" ->
                        D.succeed TxRejected

                    "receiptResult" ->
                        D.map TxConfirmed
                            (D.map5 ReceiptJson
                                (D.field "hash" D.string)
                                (D.field "blockNumber" D.int)
                                (D.field "gasUsed" D.string)
                                (D.field "status" D.bool)
                                (D.field "logs" (D.list eventLogJsonDecoder))
                            )

                    "receiptNotFound" ->
                        D.map TxReceiptNotFound (D.field "id" D.string)

                    _ ->
                        D.fail ("Unknown tx message: " ++ tag)
            )


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
