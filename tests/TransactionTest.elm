module TransactionTest exposing (suite)

import Expect
import Json.Decode as D
import Test exposing (..)
import Web3.Transaction as Tx
import Web3.Types as T


validHash : String
validHash =
    "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd"


validAddress : String
validAddress =
    "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"


emptyReceipt =
    { txHash = validHash
    , blockNumber = 100
    , gasUsed = "21000"
    , status = True
    , contractAddress = Nothing
    , logs = []
    }


{-| Helper: drive a transaction through the proper state chain.
AwaitingSignature → Submitted (via TxSubmitted).
-}
inSubmittedState : Tx.Status
inSubmittedState =
    Tx.update (Tx.TxSubmitted Nothing validHash) Tx.AwaitingSignature


{-| Helper: drive to Confirming state.
AwaitingSignature → Submitted → Confirming (via TxConfirmation).
-}
inConfirmingState : Tx.Status
inConfirmingState =
    Tx.update (Tx.TxConfirmation Nothing validHash 1) inSubmittedState


txStatusLabel : Tx.Status -> String
txStatusLabel status =
    case status of
        Tx.Idle -> "Idle"
        Tx.AwaitingSignature -> "AwaitingSignature"
        Tx.Submitted _ -> "Submitted"
        Tx.Confirming _ _ -> "Confirming"
        Tx.Confirmed _ -> "Confirmed"
        Tx.RevertedOnChain _ -> "RevertedOnChain"
        Tx.Failed msg -> "Failed: " ++ msg
        Tx.Rejected -> "Rejected"


suite : Test
suite =
    describe "Web3.Transaction"
        [ stateTransitionTests
        , terminalPendingTests
        , decoderTests
        , confirmationsTests
        , parseReceiptEventsTests
        ]


stateTransitionTests : Test
stateTransitionTests =
    describe "update state transitions"
        [ test "AwaitingSignature + TxSubmitted valid hash -> Submitted" <|
            \_ ->
                case Tx.update (Tx.TxSubmitted Nothing validHash) Tx.AwaitingSignature of
                    Tx.Submitted _ ->
                        Expect.pass

                    s ->
                        Expect.fail ("Expected Submitted, got: " ++ txStatusLabel s)
        , test "AwaitingSignature + TxSubmitted invalid hash -> Failed" <|
            \_ ->
                case Tx.update (Tx.TxSubmitted Nothing "not-a-hash") Tx.AwaitingSignature of
                    Tx.Failed _ ->
                        Expect.pass

                    s ->
                        Expect.fail ("Expected Failed, got: " ++ txStatusLabel s)
        , test "Submitted + TxConfirmation -> Confirming with count" <|
            \_ ->
                case Tx.update (Tx.TxConfirmation Nothing validHash 1) inSubmittedState of
                    Tx.Confirming _ count ->
                        count |> Expect.equal 1

                    s ->
                        Expect.fail ("Expected Confirming, got: " ++ txStatusLabel s)
        , test "Submitted + TxConfirmation with count 0 is a no-op (counts start at 1)" <|
            \_ ->
                case Tx.update (Tx.TxConfirmation Nothing validHash 0) inSubmittedState of
                    Tx.Submitted _ ->
                        Expect.pass

                    s ->
                        Expect.fail ("Expected Submitted to remain, got: " ++ txStatusLabel s)
        , test "Confirming + TxConfirmation with higher count -> count increases" <|
            \_ ->
                case Tx.update (Tx.TxConfirmation Nothing validHash 3) inConfirmingState of
                    Tx.Confirming _ count ->
                        count |> Expect.equal 3

                    s ->
                        Expect.fail ("Expected Confirming, got: " ++ txStatusLabel s)
        , test "Confirming + TxConfirmation with LOWER count is dropped (monotonic invariant)" <|
            \_ ->
                let
                    atThree =
                        Tx.update (Tx.TxConfirmation Nothing validHash 3) inConfirmingState
                in
                case Tx.update (Tx.TxConfirmation Nothing validHash 2) atThree of
                    Tx.Confirming _ count ->
                        count |> Expect.equal 3

                    s ->
                        Expect.fail ("Expected Confirming 3 to remain, got: " ++ txStatusLabel s)
        , test "Confirming + TxConfirmation with EQUAL count is dropped (strictly increasing)" <|
            \_ ->
                case Tx.update (Tx.TxConfirmation Nothing validHash 1) inConfirmingState of
                    Tx.Confirming _ count ->
                        count |> Expect.equal 1

                    s ->
                        Expect.fail ("Expected Confirming 1 to remain, got: " ++ txStatusLabel s)
        , test "Confirming + TxConfirmed -> Confirmed with receipt data" <|
            \_ ->
                case Tx.update (Tx.TxConfirmed Nothing emptyReceipt) inConfirmingState of
                    Tx.Confirmed receipt ->
                        receipt.blockNumber |> Expect.equal 100

                    s ->
                        Expect.fail ("Expected Confirmed, got: " ++ txStatusLabel s)
        , test "TxConfirmed with invalid hash -> Failed" <|
            \_ ->
                let
                    badReceipt =
                        { emptyReceipt | txHash = "bad-hash" }
                in
                case Tx.update (Tx.TxConfirmed Nothing badReceipt) inConfirmingState of
                    Tx.Failed _ ->
                        Expect.pass

                    s ->
                        Expect.fail ("Expected Failed, got: " ++ txStatusLabel s)
        , test "any non-terminal state + TxFailed -> Failed with message" <|
            \_ ->
                Tx.update (Tx.TxFailed Nothing "out of gas") Tx.AwaitingSignature
                    |> (\s ->
                            case s of
                                Tx.Failed err ->
                                    err |> Expect.equal "out of gas"

                                _ ->
                                    Expect.fail "Expected Failed"
                       )
        , test "AwaitingSignature + TxRejected -> Rejected" <|
            \_ ->
                Tx.update (Tx.TxRejected Nothing) Tx.AwaitingSignature
                    |> Expect.equal Tx.Rejected
        , test "TxConfirmed filters out logs with invalid addresses" <|
            \_ ->
                let
                    receiptWithLogs =
                        { emptyReceipt
                            | logs =
                                [ { address = validAddress
                                  , topics = [ "0x1234" ]
                                  , data = "0x"
                                  , blockNumber = 100
                                  , logIndex = 0
                                  }
                                , { address = "bad-address"
                                  , topics = []
                                  , data = "0x"
                                  , blockNumber = 100
                                  , logIndex = 1
                                  }
                                ]
                        }
                in
                case Tx.update (Tx.TxConfirmed Nothing receiptWithLogs) inConfirmingState of
                    Tx.Confirmed receipt ->
                        List.length receipt.logs |> Expect.equal 1

                    s ->
                        Expect.fail ("Expected Confirmed, got: " ++ txStatusLabel s)
        , test "TxConfirmation with invalid hash is a no-op" <|
            \_ ->
                let
                    newState =
                        Tx.update (Tx.TxConfirmation Nothing "bad-hash" 1) inSubmittedState
                in
                case ( inSubmittedState, newState ) of
                    ( Tx.Submitted _, Tx.Submitted _ ) ->
                        Expect.pass

                    _ ->
                        Expect.fail "Expected state to remain Submitted"
        , test "TxConfirmed from Submitted (fast chain, no Confirming step)" <|
            \_ ->
                case Tx.update (Tx.TxConfirmed Nothing emptyReceipt) inSubmittedState of
                    Tx.Confirmed receipt ->
                        receipt.blockNumber |> Expect.equal 100

                    s ->
                        Expect.fail ("Expected Confirmed, got: " ++ txStatusLabel s)
        , test "TxRejected from Submitted -> Failed" <|
            \_ ->
                case Tx.update (Tx.TxRejected Nothing) inSubmittedState of
                    Tx.Failed _ ->
                        Expect.pass

                    s ->
                        Expect.fail ("Expected Failed, got: " ++ txStatusLabel s)
        , test "TxRejected from Confirming -> Failed" <|
            \_ ->
                case Tx.update (Tx.TxRejected Nothing) inConfirmingState of
                    Tx.Failed _ ->
                        Expect.pass

                    s ->
                        Expect.fail ("Expected Failed, got: " ++ txStatusLabel s)
        , test "TxReset from Confirmed -> Idle" <|
            \_ ->
                let
                    confirmed =
                        Tx.update (Tx.TxConfirmed Nothing emptyReceipt) inConfirmingState
                in
                Tx.update Tx.TxReset confirmed
                    |> Expect.equal Tx.Idle
        , test "TxReset from Failed -> Idle" <|
            \_ ->
                Tx.update Tx.TxReset (Tx.Failed "error")
                    |> Expect.equal Tx.Idle
        , test "TxReset from Rejected -> Idle" <|
            \_ ->
                Tx.update Tx.TxReset Tx.Rejected
                    |> Expect.equal Tx.Idle
        , test "TxReset from Submitted is a no-op (mid-flight)" <|
            \_ ->
                case Tx.update Tx.TxReset inSubmittedState of
                    Tx.Submitted _ ->
                        Expect.pass

                    s ->
                        Expect.fail ("Expected Submitted unchanged, got: " ++ txStatusLabel s)
        , test "TxReset from AwaitingSignature is a no-op (mid-flight)" <|
            \_ ->
                Tx.update Tx.TxReset Tx.AwaitingSignature
                    |> Expect.equal Tx.AwaitingSignature
        , test "TxReset from Idle is a no-op" <|
            \_ ->
                Tx.update Tx.TxReset Tx.Idle
                    |> Expect.equal Tx.Idle
        , test "TxReceiptNotFound is always a no-op" <|
            \_ ->
                Tx.update (Tx.TxReceiptNotFound "my-id") inSubmittedState
                    |> Expect.equal inSubmittedState
        ]


terminalPendingTests : Test
terminalPendingTests =
    describe "isTerminal / isPending"
        [ test "Idle is not terminal" <|
            \_ ->
                Tx.isTerminal Tx.Idle |> Expect.equal False
        , test "AwaitingSignature is not terminal" <|
            \_ ->
                Tx.isTerminal Tx.AwaitingSignature |> Expect.equal False
        , test "Submitted is not terminal" <|
            \_ ->
                case T.txHash validHash of
                    Just h ->
                        Tx.isTerminal (Tx.Submitted h) |> Expect.equal False

                    Nothing ->
                        Expect.fail "Invalid hash"
        , test "Confirmed is terminal" <|
            \_ ->
                Tx.update (Tx.TxConfirmed Nothing emptyReceipt) inConfirmingState
                    |> Tx.isTerminal
                    |> Expect.equal True
        , test "Failed is terminal" <|
            \_ ->
                Tx.isTerminal (Tx.Failed "err") |> Expect.equal True
        , test "Rejected is terminal" <|
            \_ ->
                Tx.isTerminal Tx.Rejected |> Expect.equal True
        , test "AwaitingSignature is pending" <|
            \_ ->
                Tx.isPending Tx.AwaitingSignature |> Expect.equal True
        , test "Submitted is pending" <|
            \_ ->
                case T.txHash validHash of
                    Just h ->
                        Tx.isPending (Tx.Submitted h) |> Expect.equal True

                    Nothing ->
                        Expect.fail "Invalid hash"
        , test "Confirming is pending" <|
            \_ ->
                inConfirmingState
                    |> Tx.isPending
                    |> Expect.equal True
        , test "Idle is not pending" <|
            \_ ->
                Tx.isPending Tx.Idle |> Expect.equal False
        , test "Confirmed is not pending" <|
            \_ ->
                Tx.update (Tx.TxConfirmed Nothing emptyReceipt) inConfirmingState
                    |> Tx.isPending
                    |> Expect.equal False
        ]


decoderTests : Test
decoderTests =
    describe "decoder"
        [ test "decodes submitted message" <|
            \_ ->
                ("{\"tag\":\"submitted\",\"hash\":\"" ++ validHash ++ "\"}")
                    |> D.decodeString Tx.decoder
                    |> (\r ->
                            case r of
                                Ok (Tx.TxSubmitted Nothing h) ->
                                    h |> Expect.equal validHash

                                _ ->
                                    Expect.fail "Expected TxSubmitted"
                       )
        , test "decodes confirmation message" <|
            \_ ->
                ("{\"tag\":\"confirmation\",\"hash\":\"" ++ validHash ++ "\",\"count\":2}")
                    |> D.decodeString Tx.decoder
                    |> (\r ->
                            case r of
                                Ok (Tx.TxConfirmation Nothing h count) ->
                                    Expect.all
                                        [ \_ -> h |> Expect.equal validHash
                                        , \_ -> count |> Expect.equal 2
                                        ]
                                        ()

                                _ ->
                                    Expect.fail "Expected TxConfirmation"
                       )
        , test "decodes confirmed message with empty logs" <|
            \_ ->
                ("{\"tag\":\"confirmed\",\"hash\":\"" ++ validHash ++ "\",\"blockNumber\":100,\"gasUsed\":\"21000\",\"status\":true,\"logs\":[]}")
                    |> D.decodeString Tx.decoder
                    |> (\r ->
                            case r of
                                Ok (Tx.TxConfirmed _ receipt) ->
                                    Expect.all
                                        [ \_ -> receipt.blockNumber |> Expect.equal 100
                                        , \_ -> receipt.gasUsed |> Expect.equal "21000"
                                        , \_ -> receipt.status |> Expect.equal True
                                        , \_ -> List.length receipt.logs |> Expect.equal 0
                                        ]
                                        ()

                                _ ->
                                    Expect.fail "Expected TxConfirmed"
                       )
        , test "decodes failed message" <|
            \_ ->
                """{"tag":"failed","error":"user rejected"}"""
                    |> D.decodeString Tx.decoder
                    |> Expect.equal (Ok (Tx.TxFailed Nothing "user rejected"))
        , test "decodes rejected message" <|
            \_ ->
                """{"tag":"rejected"}"""
                    |> D.decodeString Tx.decoder
                    |> Expect.equal (Ok (Tx.TxRejected Nothing))
        , test "fails on unknown tag" <|
            \_ ->
                """{"tag":"mystery"}"""
                    |> D.decodeString Tx.decoder
                    |> (\r ->
                            case r of
                                Err _ ->
                                    Expect.pass

                                Ok _ ->
                                    Expect.fail "Expected failure"
                       )
        , test "fails on missing required field" <|
            \_ ->
                """{"tag":"submitted"}"""
                    |> D.decodeString Tx.decoder
                    |> (\r ->
                            case r of
                                Err _ ->
                                    Expect.pass

                                Ok _ ->
                                    Expect.fail "Expected failure"
                       )
        , test "decodes receiptNotFound as TxReceiptNotFound with id" <|
            \_ ->
                """{"tag":"receiptNotFound","id":"poll-1"}"""
                    |> D.decodeString Tx.decoder
                    |> Expect.equal (Ok (Tx.TxReceiptNotFound "poll-1"))
        ]


parseReceiptEventsTests : Test
parseReceiptEventsTests =
    describe "parseReceiptEvents"
        [ test "returns empty list for empty logs" <|
            \_ ->
                case Tx.update (Tx.TxConfirmed Nothing emptyReceipt) inConfirmingState of
                    Tx.Confirmed r ->
                        Tx.parseReceiptEvents [] r |> Expect.equal []

                    _ ->
                        Expect.fail "Expected Confirmed"
        , test "applies decoder to logs and collects results" <|
            \_ ->
                let
                    receiptWithLog =
                        { emptyReceipt
                            | logs =
                                [ { address = validAddress
                                  , topics = [ "0xabcd" ]
                                  , data = "0x1234"
                                  , blockNumber = 100
                                  , logIndex = 0
                                  }
                                ]
                        }

                    alwaysData log =
                        Just log.data
                in
                case Tx.update (Tx.TxConfirmed Nothing receiptWithLog) inConfirmingState of
                    Tx.Confirmed r ->
                        Tx.parseReceiptEvents [ alwaysData ] r
                            |> Expect.equal [ "0x1234" ]

                    _ ->
                        Expect.fail "Expected Confirmed"
        , test "returns empty for non-matching decoder" <|
            \_ ->
                let
                    receiptWithLog =
                        { emptyReceipt
                            | logs =
                                [ { address = validAddress
                                  , topics = []
                                  , data = "0x"
                                  , blockNumber = 100
                                  , logIndex = 0
                                  }
                                ]
                        }

                    neverDecoder _ =
                        Nothing
                in
                case Tx.update (Tx.TxConfirmed Nothing receiptWithLog) inConfirmingState of
                    Tx.Confirmed r ->
                        Tx.parseReceiptEvents [ neverDecoder ] r
                            |> Expect.equal []

                    _ ->
                        Expect.fail "Expected Confirmed"
        , test "applies multiple decoders per log" <|
            \_ ->
                let
                    receiptWithLog =
                        { emptyReceipt
                            | logs =
                                [ { address = validAddress
                                  , topics = []
                                  , data = "0xbeef"
                                  , blockNumber = 100
                                  , logIndex = 0
                                  }
                                ]
                        }

                    decodeData log =
                        Just log.data

                    decodeIndex log =
                        Just (String.fromInt log.logIndex)
                in
                case Tx.update (Tx.TxConfirmed Nothing receiptWithLog) inConfirmingState of
                    Tx.Confirmed r ->
                        Tx.parseReceiptEvents [ decodeData, decodeIndex ] r
                            |> List.length
                            |> Expect.equal 2

                    _ ->
                        Expect.fail "Expected Confirmed"
        ]


confirmationsTests : Test
confirmationsTests =
    describe "transactionConfirmations"
        [ test "currentBlock > receipt.blockNumber returns positive count" <|
            \_ ->
                case Tx.update (Tx.TxConfirmed Nothing emptyReceipt) inConfirmingState of
                    Tx.Confirmed receipt ->
                        Tx.transactionConfirmations 110 receipt
                            |> Expect.equal 10

                    _ ->
                        Expect.fail "Expected Confirmed"
        , test "currentBlock == receipt.blockNumber returns 0" <|
            \_ ->
                case Tx.update (Tx.TxConfirmed Nothing emptyReceipt) inConfirmingState of
                    Tx.Confirmed receipt ->
                        Tx.transactionConfirmations 100 receipt
                            |> Expect.equal 0

                    _ ->
                        Expect.fail "Expected Confirmed"
        , test "currentBlock < receipt.blockNumber clamps to 0" <|
            \_ ->
                case Tx.update (Tx.TxConfirmed Nothing emptyReceipt) inConfirmingState of
                    Tx.Confirmed receipt ->
                        Tx.transactionConfirmations 90 receipt
                            |> Expect.equal 0

                    _ ->
                        Expect.fail "Expected Confirmed"
        ]
