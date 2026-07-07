module WalletFuzzTest exposing (suite)

{-| Fuzz tests for Web3.Wallet state machine.

Properties verified:
  1. Never crashes — update is total for any msg and any state.
  2. Connected state always has a valid, non-Nothing address.
  3. Disconnected is always reachable: WalletDisconnected from any state -> Disconnected.
  4. Error is always reachable: WalletError from any state -> Error.
  5. isConnected ↔ getAddress returns Just (consistency).
  6. isConnected ↔ getChainId returns Just (consistency).
  7. Address stored in Connected survives a T.address round-trip (validates the opaque type).

-}

import Expect
import Fuzz exposing (Fuzzer)
import Test exposing (..)
import Web3.Types as T
import Web3.Wallet as Wallet



-- CONSTANTS


expectedChain : T.ChainId
expectedChain =
    T.chainId 369



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


{-| Generate a valid Ethereum address string: "0x" + 40 lowercase hex chars.
-}
validAddressStringFuzzer : Fuzzer String
validAddressStringFuzzer =
    Fuzz.listOfLength 40 hexCharFuzzer
        |> Fuzz.map (\chars -> "0x" ++ String.fromList chars)


{-| Mix of valid and invalid address strings to stress-test the state machine.
-}
addressStringFuzzer : Fuzzer String
addressStringFuzzer =
    Fuzz.oneOf
        [ validAddressStringFuzzer
        , Fuzz.constant "not-an-address"
        , Fuzz.constant ""
        , Fuzz.constant "0x123"
        , Fuzz.constant "0xGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG"
        , Fuzz.string
        ]


{-| Mix of the expected chain, a known-wrong chain, and arbitrary chain IDs.
-}
chainIdIntFuzzer : Fuzzer Int
chainIdIntFuzzer =
    Fuzz.oneOf
        [ Fuzz.constant 369
        , Fuzz.constant 1
        , Fuzz.constant 56
        , Fuzz.intRange 0 99999
        ]


{-| A `RequestId` from a small range — small enough that fuzzed sequences
regularly generate MATCHING ids across messages (exercising the
accept/stale-drop logic), not just always-mismatched random Ints.
-}
requestIdFuzzer : Fuzzer Wallet.RequestId
requestIdFuzzer =
    Fuzz.intRange 0 5


connectFailureReasonFuzzer : Fuzzer Wallet.ConnectFailureReason
connectFailureReasonFuzzer =
    Fuzz.oneOf
        [ Fuzz.constant Wallet.NotFound
        , Fuzz.constant Wallet.NoAccounts
        , Fuzz.constant Wallet.NetworkError
        ]


{-| Generate any Wallet.Msg, including ones with invalid addresses or chain IDs.
-}
msgFuzzer : Fuzzer Wallet.Msg
msgFuzzer =
    Fuzz.oneOf
        [ Fuzz.map3 Wallet.WalletConnected (Fuzz.maybe requestIdFuzzer) addressStringFuzzer chainIdIntFuzzer
        , Fuzz.map Wallet.WalletConnectRejected requestIdFuzzer
        , Fuzz.map Wallet.WalletConnectPending requestIdFuzzer
        , Fuzz.map3 Wallet.WalletConnectFailed requestIdFuzzer connectFailureReasonFuzzer Fuzz.string
        , Fuzz.constant Wallet.WalletDisconnected
        , Fuzz.map Wallet.ChainChanged chainIdIntFuzzer
        , Fuzz.map Wallet.AccountChanged addressStringFuzzer
        , Fuzz.map Wallet.WalletError Fuzz.string
        , Fuzz.constant (Wallet.WalletsDiscovered [])
        , Fuzz.map Wallet.SwitchChainOk chainIdIntFuzzer
        ]


{-| Generate any initial state, including Connected and WrongChain
(reached by applying known-good messages).
-}
initialStateFuzzer : Fuzzer Wallet.State
initialStateFuzzer =
    Fuzz.oneOf
        [ Fuzz.constant Wallet.Disconnected
        , Fuzz.map Wallet.Connecting requestIdFuzzer
        , Fuzz.map Wallet.Error Fuzz.string
        , -- Connected on expected chain
          Fuzz.map
            (\addr ->
                Wallet.update expectedChain (Wallet.WalletConnected Nothing addr 369) Wallet.Disconnected
            )
            validAddressStringFuzzer
        , -- WrongChain
          Fuzz.map
            (\addr ->
                Wallet.update expectedChain (Wallet.WalletConnected Nothing addr 1) Wallet.Disconnected
            )
            validAddressStringFuzzer
        ]



-- HELPERS


applyMsgs : List Wallet.Msg -> Wallet.State -> Wallet.State
applyMsgs msgs state =
    List.foldl (Wallet.update expectedChain) state msgs


stateTag : Wallet.State -> String
stateTag state =
    case state of
        Wallet.Disconnected ->
            "Disconnected"

        Wallet.ReadOnly ->
            "ReadOnly"

        Wallet.Connecting _ ->
            "Connecting"

        Wallet.Connected _ ->
            "Connected"

        Wallet.WrongChain _ _ ->
            "WrongChain"

        Wallet.Error msg ->
            "Error(" ++ msg ++ ")"



-- SUITE


suite : Test
suite =
    describe "Web3.Wallet fuzz"
        [ neverCrashesTest
        , connectedAddressInvariantTest
        , disconnectedReachableTest
        , errorReachableTest
        , getAddressConsistencyTest
        , getChainIdConsistencyTest
        , addressRoundTripTest
        , errorRecoverableTest
        ]


{-| update is total — any sequence of messages from any initial state always
produces one of the five known State variants without runtime error.
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
                Wallet.Disconnected ->
                    Expect.pass

                Wallet.ReadOnly ->
                    Expect.pass

                Wallet.Connecting _ ->
                    Expect.pass

                Wallet.Connected _ ->
                    Expect.pass

                Wallet.WrongChain _ _ ->
                    Expect.pass

                Wallet.Error _ ->
                    Expect.pass


{-| Connected state always has a non-Nothing address from getAddress.
-}
connectedAddressInvariantTest : Test
connectedAddressInvariantTest =
    fuzz2 initialStateFuzzer (Fuzz.list msgFuzzer) "Connected state always has a non-Nothing address" <|
        \initState msgs ->
            let
                finalState =
                    applyMsgs msgs initState
            in
            case finalState of
                Wallet.Connected _ ->
                    Wallet.getAddress finalState
                        |> Expect.notEqual Nothing

                _ ->
                    Expect.pass


{-| WalletDisconnected transitions to Disconnected from any state except ReadOnly.
ReadOnly is a special mode (rpcUrl present, no wallet) that persists through disconnect.
-}
disconnectedReachableTest : Test
disconnectedReachableTest =
    fuzz2 initialStateFuzzer (Fuzz.list msgFuzzer) "WalletDisconnected leads to Disconnected or stays ReadOnly" <|
        \initState msgs ->
            let
                anyState =
                    applyMsgs msgs initState

                afterDisconnect =
                    Wallet.update expectedChain Wallet.WalletDisconnected anyState
            in
            case anyState of
                Wallet.ReadOnly ->
                    afterDisconnect |> Expect.equal Wallet.ReadOnly

                _ ->
                    afterDisconnect |> Expect.equal Wallet.Disconnected


{-| WalletError transitions to Error from any state except ReadOnly.
ReadOnly mode ignores WalletError to stay read-accessible.
-}
errorReachableTest : Test
errorReachableTest =
    fuzz3 initialStateFuzzer (Fuzz.list msgFuzzer) Fuzz.string "WalletError leads to Error or stays ReadOnly" <|
        \initState msgs errMsg ->
            let
                anyState =
                    applyMsgs msgs initState

                afterError =
                    Wallet.update expectedChain (Wallet.WalletError errMsg) anyState
            in
            case anyState of
                Wallet.ReadOnly ->
                    afterError |> Expect.equal Wallet.ReadOnly

                _ ->
                    case afterError of
                        Wallet.Error _ ->
                            Expect.pass

                        _ ->
                            Expect.fail
                                ("Expected Error state after WalletError, got: "
                                    ++ stateTag afterError
                                )


{-| isConnected and getAddress are perfectly consistent: both reflect
exactly the Connected constructor, nothing else.
-}
getAddressConsistencyTest : Test
getAddressConsistencyTest =
    fuzz2 initialStateFuzzer (Fuzz.list msgFuzzer) "isConnected ↔ getAddress returns Just" <|
        \initState msgs ->
            let
                state =
                    applyMsgs msgs initState
            in
            if Wallet.isConnected state then
                Wallet.getAddress state
                    |> Expect.notEqual Nothing

            else
                Wallet.getAddress state
                    |> Expect.equal Nothing


{-| isConnected and getChainId are perfectly consistent.
-}
getChainIdConsistencyTest : Test
getChainIdConsistencyTest =
    fuzz2 initialStateFuzzer (Fuzz.list msgFuzzer) "isConnected ↔ getChainId returns Just" <|
        \initState msgs ->
            let
                state =
                    applyMsgs msgs initState
            in
            if Wallet.isConnected state then
                Wallet.getChainId state
                    |> Expect.notEqual Nothing

            else
                Wallet.getChainId state
                    |> Expect.equal Nothing


{-| The opaque Address stored in a Connected state is always a well-formed
Ethereum address — it survives a round-trip through T.addressToString and
T.address. This verifies the opaque type never stores an invalid value.
-}
addressRoundTripTest : Test
addressRoundTripTest =
    fuzz2 initialStateFuzzer (Fuzz.list msgFuzzer) "Address in Connected state always passes T.address validation" <|
        \initState msgs ->
            let
                state =
                    applyMsgs msgs initState
            in
            case Wallet.getAddress state of
                Just addr ->
                    T.addressToString addr
                        |> T.address
                        |> Expect.notEqual Nothing

                Nothing ->
                    Expect.pass


{-| Error state is always recoverable: WalletDisconnected from Error always yields Disconnected.
-}
errorRecoverableTest : Test
errorRecoverableTest =
    fuzz Fuzz.string "Error state is always recoverable via WalletDisconnected" <|
        \errMsg ->
            let
                errState =
                    Wallet.Error errMsg

                afterDisconnect =
                    Wallet.update expectedChain Wallet.WalletDisconnected errState
            in
            afterDisconnect |> Expect.equal Wallet.Disconnected
