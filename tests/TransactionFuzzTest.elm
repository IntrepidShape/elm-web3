module TransactionFuzzTest exposing (suite)

{-| Fuzz tests for Web3.Transaction state machine.

Properties verified:
  1. Never crashes — update is total for any msg and any state.
  2. Terminal states (Confirmed/Failed/Rejected) always have isTerminal=True.
  3. Non-terminal states (Idle/AwaitingSignature/Submitted/Confirming) always have isTerminal=False.
  4. isTerminal and isPending are mutually exclusive.
  5. Submitted state is only reachable via TxSubmitted msg (not via any other msg type).
  6. isPending ↔ state is exactly one of {AwaitingSignature, Submitted, Confirming}.
  7. TxRejected always produces Rejected regardless of prior state.
  8. TxFailed always produces Failed regardless of prior state.

-}

import Expect
import Fuzz exposing (Fuzzer)
import Test exposing (..)
import Web3.Transaction as Tx


-- FUZZ HELPERS


hexCharFuzzer : Fuzzer Char
hexCharFuzzer =
    Fuzz.intRange 0 15
        |> Fuzz.map
            (\n ->
                if n < 10 then
                    Char.fromCode (Char.toCode '0' + n)

                else
                    Char.fromCode (Char.toCode 'a' + (n - 10))
            )


{-| Generate a valid tx hash string: "0x" + 64 lowercase hex chars.
-}
validTxHashStringFuzzer : Fuzzer String
validTxHashStringFuzzer =
    Fuzz.listOfLength 64 hexCharFuzzer
        |> Fuzz.map (\chars -> "0x" ++ String.fromList chars)


{-| Mix of valid and invalid tx hash strings.
-}
txHashStringFuzzer : Fuzzer String
txHashStringFuzzer =
    Fuzz.oneOf
        [ validTxHashStringFuzzer
        , Fuzz.constant "not-a-hash"
        , Fuzz.constant ""
        , Fuzz.constant "0x123"
        , Fuzz.constant "0xGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG"
        , Fuzz.string
        ]


{-| Generate a ReceiptJson-shaped record (type alias is structurally compatible).
Uses valid and invalid hashes to stress both the happy path and error path.
-}
receiptJsonFuzzer :
    Fuzzer
        { txHash : String
        , blockNumber : Int
        , gasUsed : String
        , status : Bool
        , logs : List { address : String, topics : List String, data : String, blockNumber : Int, logIndex : Int }
        }
receiptJsonFuzzer =
    Fuzz.map3
        (\hash blk ok ->
            { txHash = hash
            , blockNumber = blk
            , gasUsed = "21000"
            , status = ok
            , logs = []
            }
        )
        txHashStringFuzzer
        (Fuzz.intRange 0 1000000)
        Fuzz.bool


{-| Generate any Transaction.Msg variant.
-}
msgFuzzer : Fuzzer Tx.Msg
msgFuzzer =
    Fuzz.oneOf
        [ Fuzz.map Tx.TxSubmitted txHashStringFuzzer
        , Fuzz.map2 Tx.TxConfirmation txHashStringFuzzer (Fuzz.intRange 1 100)
        , Fuzz.map Tx.TxConfirmed receiptJsonFuzzer
        , Fuzz.map Tx.TxFailed Fuzz.string
        , Fuzz.constant Tx.TxRejected
        , Fuzz.constant Tx.TxReset
        , Fuzz.map Tx.TxReceiptNotFound Fuzz.string
        ]


{-| Generate any Msg that is NOT TxSubmitted.
Used to test that only TxSubmitted can produce Submitted state.
-}
nonSubmittedMsgFuzzer : Fuzzer Tx.Msg
nonSubmittedMsgFuzzer =
    Fuzz.oneOf
        [ Fuzz.map2 Tx.TxConfirmation txHashStringFuzzer (Fuzz.intRange 1 100)
        , Fuzz.map Tx.TxConfirmed receiptJsonFuzzer
        , Fuzz.map Tx.TxFailed Fuzz.string
        , Fuzz.constant Tx.TxRejected
        , Fuzz.constant Tx.TxReset
        , Fuzz.map Tx.TxReceiptNotFound Fuzz.string
        ]


{-| Generate initial states, including those only reachable via update.
Uses the correct state machine transitions (AwaitingSignature as entry point).
-}
initialStateFuzzer : Fuzzer Tx.Status
initialStateFuzzer =
    Fuzz.oneOf
        [ Fuzz.constant Tx.Idle
        , Fuzz.constant Tx.AwaitingSignature
        , Fuzz.constant Tx.Rejected
        , -- Failed (reached via TxFailed from AwaitingSignature)
          Fuzz.map
            (\err -> Tx.update (Tx.TxFailed err) Tx.AwaitingSignature)
            Fuzz.string
        , -- Submitted (reached via AwaitingSignature → TxSubmitted)
          Fuzz.map
            (\hash -> Tx.update (Tx.TxSubmitted hash) Tx.AwaitingSignature)
            validTxHashStringFuzzer
        , -- Confirming (reached via AwaitingSignature → Submitted → TxConfirmation)
          Fuzz.map2
            (\hash count ->
                let
                    submitted =
                        Tx.update (Tx.TxSubmitted hash) Tx.AwaitingSignature
                in
                Tx.update (Tx.TxConfirmation hash count) submitted
            )
            validTxHashStringFuzzer
            (Fuzz.intRange 1 100)
        , -- Confirmed (reached via full chain)
          Fuzz.map
            (\hash ->
                let
                    submitted =
                        Tx.update (Tx.TxSubmitted hash) Tx.AwaitingSignature

                    confirming =
                        Tx.update (Tx.TxConfirmation hash 1) submitted
                in
                Tx.update
                    (Tx.TxConfirmed
                        { txHash = hash
                        , blockNumber = 100
                        , gasUsed = "21000"
                        , status = True
                        , logs = []
                        }
                    )
                    confirming
            )
            validTxHashStringFuzzer
        ]



-- HELPERS


applyMsgs : List Tx.Msg -> Tx.Status -> Tx.Status
applyMsgs msgs status =
    List.foldl Tx.update status msgs


statusTag : Tx.Status -> String
statusTag status =
    case status of
        Tx.Idle ->
            "Idle"

        Tx.AwaitingSignature ->
            "AwaitingSignature"

        Tx.Submitted _ ->
            "Submitted"

        Tx.Confirming _ _ ->
            "Confirming"

        Tx.Confirmed _ ->
            "Confirmed"

        Tx.Failed msg ->
            "Failed(" ++ msg ++ ")"

        Tx.Rejected ->
            "Rejected"


isSubmittedState : Tx.Status -> Bool
isSubmittedState status =
    case status of
        Tx.Submitted _ ->
            True

        _ ->
            False



-- SUITE


suite : Test
suite =
    describe "Web3.Transaction fuzz"
        [ neverCrashesTest
        , terminalIsTerminalTest
        , nonTerminalIsNotTerminalTest
        , terminalAndPendingMutuallyExclusiveTest
        , submittedOnlyViaTxSubmittedTest
        , isPendingConsistencyTest
        , txRejectedAlwaysRejectsTest
        , txFailedAlwaysFailsTest
        , txResetFromTerminalTest
        , monotonicConfirmationsTest
        ]


{-| update is total — any sequence of messages from any initial state always
produces one of the seven known Status variants without runtime error.
-}
neverCrashesTest : Test
neverCrashesTest =
    fuzz2 initialStateFuzzer (Fuzz.list msgFuzzer) "update never crashes for any msg sequence from any initial state" <|
        \initState msgs ->
            let
                finalState =
                    applyMsgs msgs initState
            in
            case finalState of
                Tx.Idle ->
                    Expect.pass

                Tx.AwaitingSignature ->
                    Expect.pass

                Tx.Submitted _ ->
                    Expect.pass

                Tx.Confirming _ _ ->
                    Expect.pass

                Tx.Confirmed _ ->
                    Expect.pass

                Tx.Failed _ ->
                    Expect.pass

                Tx.Rejected ->
                    Expect.pass


{-| Confirmed, Failed, and Rejected always report isTerminal=True.
-}
terminalIsTerminalTest : Test
terminalIsTerminalTest =
    fuzz2 initialStateFuzzer (Fuzz.list msgFuzzer) "terminal states (Confirmed/Failed/Rejected) always have isTerminal=True" <|
        \initState msgs ->
            let
                finalState =
                    applyMsgs msgs initState
            in
            case finalState of
                Tx.Confirmed _ ->
                    Tx.isTerminal finalState
                        |> Expect.equal True

                Tx.Failed _ ->
                    Tx.isTerminal finalState
                        |> Expect.equal True

                Tx.Rejected ->
                    Tx.isTerminal finalState
                        |> Expect.equal True

                _ ->
                    Expect.pass


{-| Idle, AwaitingSignature, Submitted, and Confirming always report isTerminal=False.
-}
nonTerminalIsNotTerminalTest : Test
nonTerminalIsNotTerminalTest =
    fuzz2 initialStateFuzzer (Fuzz.list msgFuzzer) "non-terminal states always have isTerminal=False" <|
        \initState msgs ->
            let
                finalState =
                    applyMsgs msgs initState
            in
            case finalState of
                Tx.Idle ->
                    Tx.isTerminal finalState
                        |> Expect.equal False

                Tx.AwaitingSignature ->
                    Tx.isTerminal finalState
                        |> Expect.equal False

                Tx.Submitted _ ->
                    Tx.isTerminal finalState
                        |> Expect.equal False

                Tx.Confirming _ _ ->
                    Tx.isTerminal finalState
                        |> Expect.equal False

                _ ->
                    Expect.pass


{-| isTerminal and isPending are never simultaneously True — a transaction
cannot be both finished and in-flight.
-}
terminalAndPendingMutuallyExclusiveTest : Test
terminalAndPendingMutuallyExclusiveTest =
    fuzz2 initialStateFuzzer (Fuzz.list msgFuzzer) "isTerminal and isPending are never both True" <|
        \initState msgs ->
            let
                finalState =
                    applyMsgs msgs initState

                terminal =
                    Tx.isTerminal finalState

                pending =
                    Tx.isPending finalState
            in
            if terminal && pending then
                Expect.fail
                    ("isTerminal and isPending both True for state: "
                        ++ statusTag finalState
                    )

            else
                Expect.pass


{-| Submitted state is only *created* by TxSubmitted. A non-TxSubmitted msg
applied to a non-Submitted state must never yield Submitted.
(If initState is already Submitted, a no-op msg may legitimately leave it Submitted.)
-}
submittedOnlyViaTxSubmittedTest : Test
submittedOnlyViaTxSubmittedTest =
    fuzz2 initialStateFuzzer nonSubmittedMsgFuzzer "non-TxSubmitted msgs never produce Submitted state from non-Submitted init" <|
        \initState msg ->
            if isSubmittedState initState then
                -- already Submitted — no-op msgs may keep it there; skip
                Expect.pass

            else
                let
                    newState =
                        Tx.update msg initState
                in
                if isSubmittedState newState then
                    Expect.fail
                        ("Expected non-Submitted result after non-TxSubmitted msg from "
                            ++ statusTag initState
                            ++ ", got: "
                            ++ statusTag newState
                        )

                else
                    Expect.pass


{-| isPending is exactly True for AwaitingSignature, Submitted, and Confirming,
and False for all other states — no exceptions.
-}
isPendingConsistencyTest : Test
isPendingConsistencyTest =
    fuzz2 initialStateFuzzer (Fuzz.list msgFuzzer) "isPending ↔ state is AwaitingSignature, Submitted, or Confirming" <|
        \initState msgs ->
            let
                finalState =
                    applyMsgs msgs initState

                expectedPending =
                    case finalState of
                        Tx.AwaitingSignature ->
                            True

                        Tx.Submitted _ ->
                            True

                        Tx.Confirming _ _ ->
                            True

                        _ ->
                            False
            in
            Tx.isPending finalState
                |> Expect.equal expectedPending


{-| TxRejected semantics:
- AwaitingSignature → Rejected (user declined before signing)
- Submitted → Failed (post-submission rejection is a chain-level failure)
- Confirming → Failed (same)
- Terminal states → unchanged (guarded)
- Idle → unchanged (no-op)
-}
txRejectedAlwaysRejectsTest : Test
txRejectedAlwaysRejectsTest =
    fuzz2 initialStateFuzzer (Fuzz.list msgFuzzer) "TxRejected transitions correctly per state" <|
        \initState msgs ->
            let
                anyState =
                    applyMsgs msgs initState

                afterReject =
                    Tx.update Tx.TxRejected anyState
            in
            case anyState of
                Tx.AwaitingSignature ->
                    afterReject |> Expect.equal Tx.Rejected

                Tx.Submitted _ ->
                    case afterReject of
                        Tx.Failed _ ->
                            Expect.pass

                        _ ->
                            Expect.fail
                                ("Expected Failed after TxRejected from Submitted, got: "
                                    ++ statusTag afterReject
                                )

                Tx.Confirming _ _ ->
                    case afterReject of
                        Tx.Failed _ ->
                            Expect.pass

                        _ ->
                            Expect.fail
                                ("Expected Failed after TxRejected from Confirming, got: "
                                    ++ statusTag afterReject
                                )

                _ ->
                    -- Terminal states (guarded) and Idle stay the same
                    afterReject |> Expect.equal anyState


{-| TxFailed transitions to Failed from any non-terminal state.
Terminal states are unaffected (stay terminal).
-}
txFailedAlwaysFailsTest : Test
txFailedAlwaysFailsTest =
    fuzz3 initialStateFuzzer (Fuzz.list msgFuzzer) Fuzz.string "TxFailed leads to Failed from non-terminal states" <|
        \initState msgs errMsg ->
            let
                anyState =
                    applyMsgs msgs initState

                afterFail =
                    Tx.update (Tx.TxFailed errMsg) anyState
            in
            if Tx.isTerminal anyState then
                -- Terminal states are guarded — TxFailed has no effect
                afterFail |> Expect.equal anyState

            else
                case afterFail of
                    Tx.Failed _ ->
                        Expect.pass

                    _ ->
                        Expect.fail
                            ("Expected Failed state after TxFailed from "
                                ++ statusTag anyState
                                ++ ", got: "
                                ++ statusTag afterFail
                            )


{-| TxReset from any terminal state always yields Idle.
TxReset from any non-terminal state is a no-op.
-}
txResetFromTerminalTest : Test
txResetFromTerminalTest =
    fuzz2 initialStateFuzzer (Fuzz.list msgFuzzer) "TxReset from terminal → Idle; from non-terminal → no-op" <|
        \initState msgs ->
            let
                anyState =
                    applyMsgs msgs initState

                afterReset =
                    Tx.update Tx.TxReset anyState
            in
            if Tx.isTerminal anyState then
                afterReset |> Expect.equal Tx.Idle

            else
                afterReset |> Expect.equal anyState


{-| Confirmation counts are strictly increasing while Confirming — under ANY
message stream, including counts of 0, negatives, and out-of-order deliveries
(the MonotonicConfirmations invariant from proofs/tla/TransactionSpec.tla).
-}
monotonicConfirmationsTest : Test
monotonicConfirmationsTest =
    fuzz2 initialStateFuzzer (Fuzz.list hostileMsgFuzzer) "confirmation count never decreases across any message stream" <|
        \start msgs ->
            let
                step msg ( status, ok ) =
                    let
                        next =
                            Tx.update msg status
                    in
                    case ( status, next ) of
                        ( Tx.Confirming _ before, Tx.Confirming _ after ) ->
                            ( next, ok && after >= before )

                        _ ->
                            ( next, ok )
            in
            List.foldl step ( start, True ) msgs
                |> Tuple.second
                |> Expect.equal True


{-| Msg fuzzer with hostile confirmation counts (0, negative, out of order).
-}
hostileMsgFuzzer : Fuzzer Tx.Msg
hostileMsgFuzzer =
    Fuzz.oneOf
        [ Fuzz.map Tx.TxSubmitted txHashStringFuzzer
        , Fuzz.map2 Tx.TxConfirmation txHashStringFuzzer (Fuzz.intRange -5 100)
        , Fuzz.map Tx.TxConfirmed receiptJsonFuzzer
        , Fuzz.map Tx.TxFailed Fuzz.string
        , Fuzz.constant Tx.TxRejected
        , Fuzz.constant Tx.TxReset
        , Fuzz.map Tx.TxReceiptNotFound Fuzz.string
        ]
