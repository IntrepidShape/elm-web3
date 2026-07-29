module BoundaryHardeningTest exposing (suite)

{-| Regression coverage for the three boundary defects fixed in 3.0.0.

Each block here is red against the code that shipped in 2.1.0:

  - **A9** -- `Transaction.confirmReceipt` built `Confirmed` without ever
    reading `receipt.status`, so a mined-and-reverted transaction reached a
    terminal state whose own documentation rendered it as success.
  - **B4** -- no write carried a correlation id and no reply carried one back,
    so two transactions in flight produced replies that were literally
    indistinguishable.
  - **B3** -- `err.code` never crossed the JS boundary. 4902 (chain not added)
    arrived as an opaque string, which is why the standard
    switchChain -> addChain -> retry flow could not be written.

-}

import Dict
import Expect
import Json.Decode as D
import Json.Encode as E
import Test exposing (..)
import Web3.Abi.Encode as Encode
import Web3.BigInt as BigInt
import Web3.Contract.Send as Send
import Web3.Error as Err
import Web3.Transaction as Tx
import Web3.Types as T
import Web3.Wallet as Wallet


hashA : String
hashA =
    "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"


hashB : String
hashB =
    "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"


contractAddr : String
contractAddr =
    "0xcccccccccccccccccccccccccccccccccccccccc"


someAddress : T.Address
someAddress =
    case T.address "0xdddddddddddddddddddddddddddddddddddddddd" of
        Just a ->
            a

        Nothing ->
            -- unreachable: the literal above is a well-formed address
            Debug.todo "test fixture address is malformed"


submittedWith : String -> Tx.Status
submittedWith hash =
    Tx.update (Tx.TxSubmitted Nothing hash) Tx.AwaitingSignature


receipt : Bool -> Maybe String -> { txHash : String, blockNumber : Int, gasUsed : String, status : Bool, contractAddress : Maybe String, logs : List { address : String, topics : List String, data : String, blockNumber : Int, logIndex : Int } }
receipt ok deployedAt =
    { txHash = hashA
    , blockNumber = 100
    , gasUsed = "21000"
    , status = ok
    , contractAddress = deployedAt
    , logs = []
    }


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

        Tx.RevertedOnChain _ ->
            "RevertedOnChain"

        Tx.Failed msg ->
            "Failed(" ++ msg ++ ")"

        Tx.Rejected ->
            "Rejected"


suite : Test
suite =
    describe "boundary hardening (3.0.0)"
        [ revertedReceiptTests
        , correlationIdTests
        , errorTaxonomyTests
        ]



-- A9 -- MINED AND REVERTED IS NOT CONFIRMED


revertedReceiptTests : Test
revertedReceiptTests =
    describe "A9: a mined-and-reverted receipt is never Confirmed"
        [ test "receipt.status = False from Confirming -> RevertedOnChain, not Confirmed" <|
            \_ ->
                case Tx.update (Tx.TxConfirmed Nothing (receipt False Nothing)) (submittedWith hashA) of
                    Tx.RevertedOnChain r ->
                        r.status |> Expect.equal False

                    other ->
                        Expect.fail
                            ("A reverted receipt must not be Confirmed; got "
                                ++ statusTag other
                            )
        , test "receipt.status = True is still Confirmed" <|
            \_ ->
                case Tx.update (Tx.TxConfirmed Nothing (receipt True Nothing)) (submittedWith hashA) of
                    Tx.Confirmed r ->
                        r.status |> Expect.equal True

                    other ->
                        Expect.fail ("Expected Confirmed, got " ++ statusTag other)
        , test "RevertedOnChain keeps the receipt (hash, block, gas spent)" <|
            \_ ->
                case Tx.update (Tx.TxConfirmed Nothing (receipt False Nothing)) (submittedWith hashA) of
                    Tx.RevertedOnChain r ->
                        Expect.all
                            [ \x -> T.txHashToString x.txHash |> Expect.equal hashA
                            , \x -> x.blockNumber |> Expect.equal 100
                            , \x -> x.gasUsed |> Expect.equal "21000"
                            ]
                            r

                    other ->
                        Expect.fail ("Expected RevertedOnChain, got " ++ statusTag other)
        , test "RevertedOnChain is terminal and not pending" <|
            \_ ->
                let
                    reverted =
                        Tx.update (Tx.TxConfirmed Nothing (receipt False Nothing)) (submittedWith hashA)
                in
                Expect.all
                    [ \s -> Tx.isTerminal s |> Expect.equal True
                    , \s -> Tx.isPending s |> Expect.equal False
                    ]
                    reverted
        , test "a terminal RevertedOnChain absorbs later port messages" <|
            \_ ->
                let
                    reverted =
                        Tx.update (Tx.TxConfirmed Nothing (receipt False Nothing)) (submittedWith hashA)
                in
                Tx.update (Tx.TxConfirmation Nothing hashA 9) reverted
                    |> Expect.equal reverted
        , test "TxReset from RevertedOnChain -> Idle" <|
            \_ ->
                Tx.update Tx.TxReset
                    (Tx.update (Tx.TxConfirmed Nothing (receipt False Nothing)) (submittedWith hashA))
                    |> Expect.equal Tx.Idle
        , test "wire path: a confirmed message with status false decodes and lands in RevertedOnChain" <|
            \_ ->
                let
                    json =
                        "{\"tag\":\"confirmed\",\"hash\":\""
                            ++ hashA
                            ++ "\",\"blockNumber\":100,\"gasUsed\":\"21000\",\"status\":false,\"contractAddress\":null,\"logs\":[]}"
                in
                case D.decodeString Tx.decoder json of
                    Ok msg ->
                        case Tx.update msg (submittedWith hashA) of
                            Tx.RevertedOnChain _ ->
                                Expect.pass

                            other ->
                                Expect.fail
                                    ("status:false must not render as success; got "
                                        ++ statusTag other
                                    )

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "a deployment recovers its own contract address from the receipt" <|
            \_ ->
                case Tx.update (Tx.TxConfirmed Nothing (receipt True (Just contractAddr))) (submittedWith hashA) of
                    Tx.Confirmed r ->
                        Maybe.map T.addressToString r.contractAddress
                            |> Expect.equal (Just contractAddr)

                    other ->
                        Expect.fail ("Expected Confirmed, got " ++ statusTag other)
        , test "a plain call has no contractAddress" <|
            \_ ->
                case Tx.update (Tx.TxConfirmed Nothing (receipt True Nothing)) (submittedWith hashA) of
                    Tx.Confirmed r ->
                        r.contractAddress |> Expect.equal Nothing

                    other ->
                        Expect.fail ("Expected Confirmed, got " ++ statusTag other)
        , test "a null contractAddress on the wire decodes to Nothing, not a failure" <|
            \_ ->
                let
                    json =
                        "{\"tag\":\"receiptResult\",\"id\":\"poll-1\",\"hash\":\""
                            ++ hashA
                            ++ "\",\"blockNumber\":7,\"gasUsed\":\"21000\",\"status\":true,\"contractAddress\":null,\"logs\":[]}"
                in
                case D.decodeString Tx.decoder json of
                    Ok (Tx.TxConfirmed id r) ->
                        Expect.all
                            [ \_ -> id |> Expect.equal (Just "poll-1")
                            , \_ -> r.contractAddress |> Expect.equal Nothing
                            ]
                            ()

                    Ok _ ->
                        Expect.fail "Expected TxConfirmed from a receiptResult message"

                    Err e ->
                        Expect.fail (D.errorToString e)
        ]



-- B4 -- TWO WRITES IN FLIGHT ARE TELLABLE APART


sendCall : Send.WriteCall
sendCall =
    Send.writeCall
        { contract = someAddress
        , method = "approve(address,uint256)"
        , args = [ Encode.address someAddress, Encode.uint256 (BigInt.fromInt 1) ]
        }


fieldOf : String -> E.Value -> Maybe String
fieldOf name value =
    E.encode 0 value
        |> D.decodeString (D.maybe (D.field name D.string))
        |> Result.withDefault Nothing


submittedJson : String -> String -> String
submittedJson id hash =
    "{\"tag\":\"submitted\",\"id\":\"" ++ id ++ "\",\"hash\":\"" ++ hash ++ "\"}"


correlationIdTests : Test
correlationIdTests =
    describe "B4: correlation ids on the write path"
        [ test "withId puts the id on the send cmd" <|
            \_ ->
                Send.encode (Send.withId "approve-usdc" sendCall)
                    |> fieldOf "id"
                    |> Expect.equal (Just "approve-usdc")
        , test "a write without withId sends no id field at all" <|
            \_ ->
                Send.encode sendCall
                    |> fieldOf "id"
                    |> Expect.equal Nothing
        , test "estimateGas carries the same id as the send it estimates" <|
            \_ ->
                Send.estimateGas (Send.withId "approve-usdc" sendCall)
                    |> fieldOf "id"
                    |> Expect.equal (Just "approve-usdc")
        , test "deployCall carries its id" <|
            \_ ->
                Send.deployCall
                    { bytecode = "0x6080"
                    , args = []
                    , gasLimit = Nothing
                    , id = Just "deploy-token"
                    }
                    |> fieldOf "id"
                    |> Expect.equal (Just "deploy-token")
        , test "msgId reads the id back off every write reply" <|
            \_ ->
                D.decodeString Tx.decoder (submittedJson "buy-1" hashA)
                    |> Result.map Tx.msgId
                    |> Expect.equal (Ok (Just "buy-1"))
        , test "two concurrent writes are distinguishable by id" <|
            \_ ->
                let
                    -- Two writes in flight; the replies arrive interleaved and
                    -- out of order, exactly as two wallets would deliver them.
                    replies =
                        [ submittedJson "buy-2" hashB
                        , submittedJson "buy-1" hashA
                        ]

                    route json pending =
                        case D.decodeString Tx.decoder json of
                            Ok msg ->
                                case Tx.msgId msg of
                                    Just id ->
                                        Dict.update id (Maybe.map (Tx.update msg)) pending

                                    Nothing ->
                                        pending

                            Err _ ->
                                pending

                    routed =
                        List.foldl route
                            (Dict.fromList
                                [ ( "buy-1", Tx.AwaitingSignature )
                                , ( "buy-2", Tx.AwaitingSignature )
                                ]
                            )
                            replies

                    hashIn id =
                        case Dict.get id routed of
                            Just (Tx.Submitted h) ->
                                Just (T.txHashToString h)

                            _ ->
                                Nothing
                in
                Expect.all
                    [ \_ -> hashIn "buy-1" |> Expect.equal (Just hashA)
                    , \_ -> hashIn "buy-2" |> Expect.equal (Just hashB)
                    ]
                    ()
        , test "an untagged reply reports no id rather than guessing one" <|
            \_ ->
                D.decodeString Tx.decoder
                    ("{\"tag\":\"submitted\",\"hash\":\"" ++ hashA ++ "\"}")
                    |> Result.map Tx.msgId
                    |> Expect.equal (Ok Nothing)
        , test "confirmation, confirmed, failed and rejected all carry the id" <|
            \_ ->
                let
                    ids =
                        [ "{\"tag\":\"confirmation\",\"id\":\"x\",\"hash\":\"" ++ hashA ++ "\",\"count\":2}"
                        , "{\"tag\":\"confirmed\",\"id\":\"x\",\"hash\":\"" ++ hashA ++ "\",\"blockNumber\":1,\"gasUsed\":\"1\",\"status\":true,\"logs\":[]}"
                        , "{\"tag\":\"failed\",\"id\":\"x\",\"error\":\"boom\"}"
                        , "{\"tag\":\"rejected\",\"id\":\"x\"}"
                        ]
                            |> List.map
                                (D.decodeString Tx.decoder
                                    >> Result.map Tx.msgId
                                    >> Result.withDefault Nothing
                                )
                in
                ids |> Expect.equal [ Just "x", Just "x", Just "x", Just "x" ]
        ]



-- B3 -- ONE CANONICAL ERROR TYPE, WITH THE CODE INTACT


failedJson : String -> String
failedJson extra =
    "{\"tag\":\"failed\",\"error\":\"boom\"" ++ extra ++ "}"


errorTaxonomyTests : Test
errorTaxonomyTests =
    describe "B3: the error taxonomy"
        [ test "4902 surfaces as ChainNotAdded, not as an opaque string" <|
            \_ ->
                D.decodeString Err.decoder
                    "{\"tag\":\"failed\",\"error\":\"Unrecognized chain ID. Try adding the chain first.\",\"code\":4902}"
                    |> Expect.equal (Ok Err.ChainNotAdded)
        , test "4902 reaches the wallet FSM as ChainNotAdded (the addChain retry is now writable)" <|
            \_ ->
                let
                    incoming =
                        "{\"tag\":\"failed\",\"error\":\"Unrecognized chain ID\",\"code\":4902}"
                in
                case D.decodeString Wallet.decoder incoming of
                    Ok msg ->
                        Wallet.update (T.chainId 369) msg (Wallet.Connecting 1)
                            |> Expect.equal (Wallet.Error (Wallet.PortFailed Err.ChainNotAdded))

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "-32002 outside connect is RequestPending, not a network error" <|
            \_ ->
                D.decodeString Err.decoder (failedJson ",\"code\":-32002")
                    |> Expect.equal (Ok Err.RequestPending)
        , test "4001 is UserRejected" <|
            \_ ->
                D.decodeString Err.decoder (failedJson ",\"code\":4001")
                    |> Expect.equal (Ok Err.UserRejected)
        , test "the bare rejected tag is UserRejected too" <|
            \_ ->
                D.decodeString Err.decoder "{\"tag\":\"rejected\",\"code\":4001}"
                    |> Expect.equal (Ok Err.UserRejected)
        , test "an unrecognised code is preserved rather than flattened" <|
            \_ ->
                D.decodeString Err.decoder (failedJson ",\"code\":-32000")
                    |> Expect.equal (Ok (Err.RpcError -32000 "boom"))
        , test "no code at all is a NetworkError" <|
            \_ ->
                D.decodeString Err.decoder (failedJson "")
                    |> Expect.equal (Ok (Err.NetworkError "boom"))
        , test "revert data decodes to Reverted with the reason and the raw bytes" <|
            \_ ->
                let
                    -- Error(string) selector, offset word, length 0x12, then
                    -- the utf8 bytes of "Insufficient funds", zero padded.
                    revertData =
                        "0x08c379a000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000012496e73756666696369656e742066756e64730000000000000000000000000000"
                in
                D.decodeString Err.decoder
                    (failedJson (",\"code\":-32000,\"revertData\":\"" ++ revertData ++ "\""))
                    |> Expect.equal
                        (Ok
                            (Err.Reverted
                                { reason = Just "Insufficient funds"
                                , data = Just revertData
                                }
                            )
                        )
        , test "a Solidity panic keeps its code" <|
            \_ ->
                D.decodeString Err.decoder
                    (failedJson (",\"code\":-32000,\"revertData\":\"0x4e487b71" ++ String.repeat 62 "0" ++ "11\""))
                    |> Expect.equal (Ok (Err.Panic 17))
        , test "a custom error keeps its selector even though no reason decodes" <|
            \_ ->
                D.decodeString Err.decoder
                    (failedJson ",\"code\":-32000,\"revertData\":\"0xdeadbeef\"")
                    |> Expect.equal
                        (Ok (Err.Reverted { reason = Nothing, data = Just "0xdeadbeef" }))
        , test "a user rejection wins over any revert data attached to it" <|
            \_ ->
                D.decodeString Err.decoder (failedJson ",\"code\":4001,\"revertData\":\"0xdeadbeef\"")
                    |> Expect.equal (Ok Err.UserRejected)
        , test "code carries the EIP-1193 number back out for the named cases" <|
            \_ ->
                List.map Err.code [ Err.UserRejected, Err.RequestPending, Err.ChainNotAdded ]
                    |> Expect.equal [ Just 4001, Just -32002, Just 4902 ]
        , test "connectFailed keeps the reason it decoded instead of dropping it" <|
            \_ ->
                Wallet.update (T.chainId 369)
                    (Wallet.WalletConnectFailed 1 Wallet.NotFound "No wallet extension detected")
                    (Wallet.Connecting 1)
                    |> Expect.equal
                        (Wallet.Error (Wallet.ConnectFailed Wallet.NotFound "No wallet extension detected"))
        , test "the three connect failure reasons stay distinguishable" <|
            \_ ->
                let
                    reasonOf reason =
                        case Wallet.update (T.chainId 369) (Wallet.WalletConnectFailed 1 reason "x") (Wallet.Connecting 1) of
                            Wallet.Error (Wallet.ConnectFailed r _) ->
                                Just r

                            _ ->
                                Nothing
                in
                List.map reasonOf [ Wallet.NotFound, Wallet.NoAccounts, Wallet.NetworkError ]
                    |> Expect.equal
                        [ Just Wallet.NotFound, Just Wallet.NoAccounts, Just Wallet.NetworkError ]
        , test "a malformed address from the bridge is a DecodeError, not a mystery string" <|
            \_ ->
                Wallet.update (T.chainId 369)
                    (Wallet.WalletConnected (Just 1) "0xnope" 369)
                    (Wallet.Connecting 1)
                    |> Expect.equal
                        (Wallet.Error (Wallet.PortFailed (Err.DecodeError "Invalid address: 0xnope")))
        , test "failureMessage renders both shapes without matching on English" <|
            \_ ->
                [ Wallet.failureMessage (Wallet.ConnectFailed Wallet.NoAccounts "Wallet returned no accounts")
                , Wallet.failureMessage (Wallet.PortFailed Err.ChainNotAdded)
                ]
                    |> Expect.equal
                        [ "Wallet returned no accounts"
                        , "this chain is not configured in the wallet"
                        ]
        ]
