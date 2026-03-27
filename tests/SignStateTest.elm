module SignStateTest exposing (suite)

import Expect
import Test exposing (..)
import Web3.Sign as Sign


suite : Test
suite =
    describe "Web3.Sign state machine"
        [ startSignTests
        , signUpdateTests
        , isTerminalTests
        ]


startSignTests : Test
startSignTests =
    describe "startSign"
        [ test "SignIdle + startSign -> SignPending" <|
            \_ ->
                Sign.startSign "req-1" Sign.SignIdle
                    |> Expect.equal (Sign.SignPending "req-1")
        , test "SignPending + startSign -> no-op (already pending)" <|
            \_ ->
                Sign.startSign "req-2" (Sign.SignPending "req-1")
                    |> Expect.equal (Sign.SignPending "req-1")
        , test "Signed + startSign -> no-op (terminal)" <|
            \_ ->
                Sign.startSign "req-2" (Sign.Signed "req-1" "0xsig")
                    |> Expect.equal (Sign.Signed "req-1" "0xsig")
        , test "SignFailed + startSign -> no-op (terminal)" <|
            \_ ->
                Sign.startSign "req-2" (Sign.SignFailed "req-1" "error")
                    |> Expect.equal (Sign.SignFailed "req-1" "error")
        , test "SignRejected + startSign -> no-op (terminal)" <|
            \_ ->
                Sign.startSign "req-2" (Sign.SignRejected "req-1")
                    |> Expect.equal (Sign.SignRejected "req-1")
        ]


signUpdateTests : Test
signUpdateTests =
    describe "signUpdate"
        [ test "SignPending + SignResponse (matching id) -> Signed" <|
            \_ ->
                Sign.signUpdate (Sign.SignResponse "req-1" "0xdeadbeef") (Sign.SignPending "req-1")
                    |> Expect.equal (Sign.Signed "req-1" "0xdeadbeef")
        , test "SignPending + SignResponse (mismatched id) -> no-op" <|
            \_ ->
                Sign.signUpdate (Sign.SignResponse "req-2" "0xdeadbeef") (Sign.SignPending "req-1")
                    |> Expect.equal (Sign.SignPending "req-1")
        , test "SignPending + SignError (matching id) -> SignFailed" <|
            \_ ->
                Sign.signUpdate (Sign.SignError "req-1" "rpc error") (Sign.SignPending "req-1")
                    |> Expect.equal (Sign.SignFailed "req-1" "rpc error")
        , test "SignPending + SignError (mismatched id) -> no-op" <|
            \_ ->
                Sign.signUpdate (Sign.SignError "req-2" "rpc error") (Sign.SignPending "req-1")
                    |> Expect.equal (Sign.SignPending "req-1")
        , test "SignPending + SignCancel (matching id) -> SignRejected" <|
            \_ ->
                Sign.signUpdate (Sign.SignCancel "req-1") (Sign.SignPending "req-1")
                    |> Expect.equal (Sign.SignRejected "req-1")
        , test "SignPending + SignCancel (mismatched id) -> no-op" <|
            \_ ->
                Sign.signUpdate (Sign.SignCancel "req-2") (Sign.SignPending "req-1")
                    |> Expect.equal (Sign.SignPending "req-1")
        , test "SignIdle + SignResponse -> no-op" <|
            \_ ->
                Sign.signUpdate (Sign.SignResponse "req-1" "0xsig") Sign.SignIdle
                    |> Expect.equal Sign.SignIdle
        , test "Signed + SignResponse -> no-op (terminal)" <|
            \_ ->
                let
                    terminal =
                        Sign.Signed "req-1" "0xfirst"
                in
                Sign.signUpdate (Sign.SignResponse "req-1" "0xsecond") terminal
                    |> Expect.equal terminal
        , test "SignFailed + SignCancel -> no-op (terminal)" <|
            \_ ->
                let
                    terminal =
                        Sign.SignFailed "req-1" "error"
                in
                Sign.signUpdate (Sign.SignCancel "req-1") terminal
                    |> Expect.equal terminal
        , test "SignRejected + SignResponse -> no-op (terminal)" <|
            \_ ->
                let
                    terminal =
                        Sign.SignRejected "req-1"
                in
                Sign.signUpdate (Sign.SignResponse "req-1" "0xsig") terminal
                    |> Expect.equal terminal
        ]


isTerminalTests : Test
isTerminalTests =
    describe "isSignTerminal"
        [ test "SignIdle is not terminal" <|
            \_ ->
                Sign.isSignTerminal Sign.SignIdle |> Expect.equal False
        , test "SignPending is not terminal" <|
            \_ ->
                Sign.isSignTerminal (Sign.SignPending "req-1") |> Expect.equal False
        , test "Signed is terminal" <|
            \_ ->
                Sign.isSignTerminal (Sign.Signed "req-1" "0xsig") |> Expect.equal True
        , test "SignFailed is terminal" <|
            \_ ->
                Sign.isSignTerminal (Sign.SignFailed "req-1" "err") |> Expect.equal True
        , test "SignRejected is terminal" <|
            \_ ->
                Sign.isSignTerminal (Sign.SignRejected "req-1") |> Expect.equal True
        ]
