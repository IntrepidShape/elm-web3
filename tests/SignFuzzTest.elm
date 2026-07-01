module SignFuzzTest exposing (suite)

{-| Property tests for Web3.Sign — signature-type non-confusion and state-machine
safety.

`SignStateTest` pins concrete transitions. This module fuzzes the two safety
properties that matter for a signing surface:

1.  **EIP-191 vs EIP-712 are never confused (backlog #7).** The typed-data
    encoder (`encode`) and the personal-sign encoder (`personalSign`) must emit
    distinct, correctly-tagged port messages — `"signTypedData"` vs
    `"personalSign"` — so the bridge can never route a raw message through the
    typed-data path or vice-versa. Each also carries the exact `id`/`from`.

2.  **State machine is safe under arbitrary message streams.** Terminal states
    (`Signed`/`SignFailed`/`SignRejected`) are absorbing; a response for a
    *different* correlation id never transitions a pending sign (no cross-request
    confusion); and no `SignMsg` alone can move `SignIdle` into a pending/signed
    state (a signature only exists if a request was started).

-}

import Dict
import Expect
import Fuzz exposing (Fuzzer)
import Json.Decode as D
import Json.Encode as E
import Test exposing (..)
import Web3.Sign as Sign exposing (SignMsg(..), SignState(..))
import Web3.Types as T


suite : Test
suite =
    describe "Web3.Sign"
        [ nonConfusionTests
        , stateMachineTests
        ]



-- FUZZERS


{-| A small pool of correlation ids so matched and mismatched pairs both occur
frequently under fuzzing.
-}
idFuzzer : Fuzzer String
idFuzzer =
    Fuzz.oneOfValues [ "a", "b", "c" ]


someAddress : T.Address
someAddress =
    unsafeAddress "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"


{-| Parse a known-valid address; a function (not a cyclic value) so the
unreachable fallback is legal. Terminates immediately for valid input.
-}
unsafeAddress : String -> T.Address
unsafeAddress s =
    case T.address s of
        Just a ->
            a

        Nothing ->
            unsafeAddress "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"


signStateFuzzer : Fuzzer SignState
signStateFuzzer =
    Fuzz.oneOf
        [ Fuzz.constant SignIdle
        , Fuzz.map SignPending idFuzzer
        , Fuzz.map2 Signed idFuzzer Fuzz.string
        , Fuzz.map2 SignFailed idFuzzer Fuzz.string
        , Fuzz.map SignRejected idFuzzer
        ]


terminalStateFuzzer : Fuzzer SignState
terminalStateFuzzer =
    Fuzz.oneOf
        [ Fuzz.map2 Signed idFuzzer Fuzz.string
        , Fuzz.map2 SignFailed idFuzzer Fuzz.string
        , Fuzz.map SignRejected idFuzzer
        ]


signMsgFuzzer : Fuzzer SignMsg
signMsgFuzzer =
    Fuzz.oneOf
        [ Fuzz.map2 SignResponse idFuzzer Fuzz.string
        , Fuzz.map2 SignError idFuzzer Fuzz.string
        , Fuzz.map SignCancel idFuzzer
        ]



-- 1. NON-CONFUSION


tagOf : E.Value -> Result D.Error String
tagOf v =
    D.decodeValue (D.field "tag" D.string) v


nonConfusionTests : Test
nonConfusionTests =
    describe "EIP-191 vs EIP-712 non-confusion"
        [ fuzz idFuzzer "encode (712) always tags signTypedData; personalSign (191) always tags personalSign; distinct" <|
            \id ->
                let
                    td =
                        Sign.typedData
                            { domain =
                                { name = Just "D"
                                , version = Nothing
                                , chainId = Just 1
                                , verifyingContract = Nothing
                                , salt = Nothing
                                }
                            , types = Dict.fromList [ ( "M", [ { name = "x", typeName = "uint256" } ] ) ]
                            , primaryType = "M"
                            , message = E.object [ ( "x", E.string "1" ) ]
                            }

                    typed =
                        Sign.encode id someAddress td

                    personal =
                        Sign.personalSign id someAddress "hello"
                in
                Expect.all
                    [ \_ -> tagOf typed |> Expect.equal (Ok "signTypedData")
                    , \_ -> tagOf personal |> Expect.equal (Ok "personalSign")
                    , \_ -> Expect.notEqual (tagOf typed) (tagOf personal)
                    ]
                    ()
        , fuzz2 idFuzzer Fuzz.string "personalSign carries exact id, from, and message" <|
            \id message ->
                let
                    v =
                        Sign.personalSign id someAddress message

                    field name =
                        D.decodeValue (D.field name D.string) v
                in
                Expect.all
                    [ \_ -> field "id" |> Expect.equal (Ok id)
                    , \_ -> field "from" |> Expect.equal (Ok (T.addressToString someAddress))
                    , \_ -> field "message" |> Expect.equal (Ok message)
                    ]
                    ()
        ]



-- 2. STATE MACHINE SAFETY


stateMachineTests : Test
stateMachineTests =
    describe "state machine safety"
        [ fuzz2 terminalStateFuzzer signMsgFuzzer "terminal states are absorbing (any message is a no-op)" <|
            \state msg ->
                Sign.signUpdate msg state
                    |> Expect.equal state
        , fuzz2 terminalStateFuzzer (Fuzz.list signMsgFuzzer) "terminal stays terminal under any message stream" <|
            \state msgs ->
                List.foldl Sign.signUpdate state msgs
                    |> Sign.isSignTerminal
                    |> Expect.equal True
        , fuzz (Fuzz.list signMsgFuzzer) "SignIdle never becomes pending/signed from messages alone" <|
            \msgs ->
                List.foldl Sign.signUpdate SignIdle msgs
                    |> Expect.equal SignIdle
        , fuzz3 idFuzzer idFuzzer Fuzz.string "a response for a different id never transitions a pending sign" <|
            \pendingId msgId sig ->
                let
                    result =
                        Sign.signUpdate (SignResponse msgId sig) (SignPending pendingId)
                in
                if pendingId == msgId then
                    result |> Expect.equal (Signed msgId sig)

                else
                    result |> Expect.equal (SignPending pendingId)
        , fuzz2 idFuzzer signMsgFuzzer "any matching-id message from Pending yields a terminal state carrying that id" <|
            \id msg ->
                let
                    -- force the message's id to match the pending id
                    matched =
                        case msg of
                            SignResponse _ sig ->
                                SignResponse id sig

                            SignError _ err ->
                                SignError id err

                            SignCancel _ ->
                                SignCancel id

                    result =
                        Sign.signUpdate matched (SignPending id)

                    carriesId s =
                        case s of
                            Signed i _ ->
                                i == id

                            SignFailed i _ ->
                                i == id

                            SignRejected i ->
                                i == id

                            _ ->
                                False
                in
                Expect.all
                    [ \_ -> Sign.isSignTerminal result |> Expect.equal True
                    , \_ -> carriesId result |> Expect.equal True
                    ]
                    ()
        ]
