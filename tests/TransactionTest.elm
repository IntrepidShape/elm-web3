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
    , logs = []
    }


txStatusLabel : Tx.Status -> String
txStatusLabel status =
    case status of
        Tx.Idle -> "Idle"
        Tx.AwaitingSignature -> "AwaitingSignature"
        Tx.Submitted _ -> "Submitted"
        Tx.Confirming _ _ -> "Confirming"
        Tx.Confirmed _ -> "Confirmed"
        Tx.Failed msg -> "Failed: " ++ msg
        Tx.Rejected -> "Rejected"


suite : Test
suite =
    describe "Web3.Transaction"
        [ stateTransitionTests
        , terminalPendingTests
        , decoderTests
        , parseReceiptEventsTests
        ]


stateTransitionTests : Test
stateTransitionTests =
    describe "update state transitions"
        [ test "Idle + TxSubmitted valid hash -> Submitted" <|
            \_ ->
                case Tx.update (Tx.TxSubmitted validHash) Tx.Idle of
                    Tx.Submitted _ ->
                        Expect.pass

                    s ->
                        Expect.fail ("Expected Submitted, got: " ++ txStatusLabel s)
        , test "Idle + TxSubmitted invalid hash -> Failed" <|
            \_ ->
                case Tx.update (Tx.TxSubmitted "not-a-hash") Tx.Idle of
                    Tx.Failed _ ->
                        Expect.pass

                    s ->
                        Expect.fail ("Expected Failed, got: " ++ txStatusLabel s)
        , test "Submitted + TxConfirmation -> Confirming with count" <|
            \_ ->
                let
                    submitted =
                        Tx.update (Tx.TxSubmitted validHash) Tx.Idle

                    newState =
                        Tx.update (Tx.TxConfirmation validHash 1) submitted
                in
                case newState of
                    Tx.Confirming _ count ->
                        count |> Expect.equal 1

                    s ->
                        Expect.fail ("Expected Confirming, got: " ++ txStatusLabel s)
        , test "Confirming + TxConfirmed -> Confirmed with receipt data" <|
            \_ ->
                let
                    confirming =
                        Tx.update (Tx.TxConfirmation validHash 1) Tx.Idle

                    newState =
                        Tx.update (Tx.TxConfirmed emptyReceipt) confirming
                in
                case newState of
                    Tx.Confirmed receipt ->
                        receipt.blockNumber |> Expect.equal 100

                    s ->
                        Expect.fail ("Expected Confirmed, got: " ++ txStatusLabel s)
        , test "TxConfirmed with invalid hash -> Failed" <|
            \_ ->
                let
                    badReceipt =
                        { emptyReceipt | txHash = "bad-hash" }

                    newState =
                        Tx.update (Tx.TxConfirmed badReceipt) Tx.Idle
                in
                case newState of
                    Tx.Failed _ ->
                        Expect.pass

                    s ->
                        Expect.fail ("Expected Failed, got: " ++ txStatusLabel s)
        , test "any state + TxFailed -> Failed with message" <|
            \_ ->
                Tx.update (Tx.TxFailed "out of gas") Tx.Idle
                    |> (\s ->
                            case s of
                                Tx.Failed err ->
                                    err |> Expect.equal "out of gas"

                                _ ->
                                    Expect.fail "Expected Failed"
                       )
        , test "any state + TxRejected -> Rejected" <|
            \_ ->
                Tx.update Tx.TxRejected Tx.Idle
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

                    newState =
                        Tx.update (Tx.TxConfirmed receiptWithLogs) Tx.Idle
                in
                case newState of
                    Tx.Confirmed receipt ->
                        List.length receipt.logs |> Expect.equal 1

                    s ->
                        Expect.fail ("Expected Confirmed, got: " ++ txStatusLabel s)
        , test "TxConfirmation with invalid hash is a no-op" <|
            \_ ->
                let
                    submitted =
                        Tx.update (Tx.TxSubmitted validHash) Tx.Idle

                    newState =
                        Tx.update (Tx.TxConfirmation "bad-hash" 1) submitted
                in
                case ( submitted, newState ) of
                    ( Tx.Submitted _, Tx.Submitted _ ) ->
                        Expect.pass

                    _ ->
                        Expect.fail "Expected state to remain Submitted"
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
                Tx.update (Tx.TxConfirmed emptyReceipt) Tx.Idle
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
                Tx.update (Tx.TxConfirmation validHash 1) Tx.Idle
                    |> Tx.isPending
                    |> Expect.equal True
        , test "Idle is not pending" <|
            \_ ->
                Tx.isPending Tx.Idle |> Expect.equal False
        , test "Confirmed is not pending" <|
            \_ ->
                Tx.update (Tx.TxConfirmed emptyReceipt) Tx.Idle
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
                                Ok (Tx.TxSubmitted h) ->
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
                                Ok (Tx.TxConfirmation h count) ->
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
                                Ok (Tx.TxConfirmed receipt) ->
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
                    |> Expect.equal (Ok (Tx.TxFailed "user rejected"))
        , test "decodes rejected message" <|
            \_ ->
                """{"tag":"rejected"}"""
                    |> D.decodeString Tx.decoder
                    |> Expect.equal (Ok Tx.TxRejected)
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
        ]


parseReceiptEventsTests : Test
parseReceiptEventsTests =
    describe "parseReceiptEvents"
        [ test "returns empty list for empty logs" <|
            \_ ->
                case Tx.update (Tx.TxConfirmed emptyReceipt) Tx.Idle of
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
                case Tx.update (Tx.TxConfirmed receiptWithLog) Tx.Idle of
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
                case Tx.update (Tx.TxConfirmed receiptWithLog) Tx.Idle of
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
                case Tx.update (Tx.TxConfirmed receiptWithLog) Tx.Idle of
                    Tx.Confirmed r ->
                        Tx.parseReceiptEvents [ decodeData, decodeIndex ] r
                            |> List.length
                            |> Expect.equal 2

                    _ ->
                        Expect.fail "Expected Confirmed"
        ]
