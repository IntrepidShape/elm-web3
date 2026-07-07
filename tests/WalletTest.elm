module WalletTest exposing (suite)

import Expect
import Json.Decode as D
import Test exposing (..)
import Web3.Types as T
import Web3.Wallet as Wallet


pulseChain : T.ChainId
pulseChain =
    T.chainId 369


ethereum : T.ChainId
ethereum =
    T.chainId 1


validAddress : String
validAddress =
    "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"


validAddress2 : String
validAddress2 =
    "0x1111111111111111111111111111111111111111"


suite : Test
suite =
    describe "Web3.Wallet"
        [ stateTransitionTests
        , helperTests
        , encoderTests
        , decoderTests
        , watchAssetTests
        , permissionsTests
        , requestIdTests
        ]


{-| The core correctness property of the whole RequestId mechanism: a
response/rejection/failure/timeout only takes effect if its id matches the
CURRENTLY active `Connecting` request — anything from a superseded, older
attempt is silently dropped rather than clobbering a newer one. This is what
makes "click Connect, give up, click Connect again" safe.
-}
requestIdTests : Test
requestIdTests =
    describe "RequestId stale-response handling"
        [ test "WalletConnected with a matching requestId resolves Connecting" <|
            \_ ->
                Wallet.update pulseChain (Wallet.WalletConnected (Just 1) validAddress 369) (Wallet.Connecting 1)
                    |> Wallet.isConnected
                    |> Expect.equal True
        , test "WalletConnected with a stale (non-matching) requestId is dropped" <|
            \_ ->
                Wallet.update pulseChain (Wallet.WalletConnected (Just 1) validAddress 369) (Wallet.Connecting 2)
                    |> Expect.equal (Wallet.Connecting 2)
        , test "WalletConnected with no requestId (silent reconnect) resolves from any state" <|
            \_ ->
                Wallet.update pulseChain (Wallet.WalletConnected Nothing validAddress 369) Wallet.Disconnected
                    |> Wallet.isConnected
                    |> Expect.equal True
        , test "WalletConnectRejected with a matching requestId -> Disconnected" <|
            \_ ->
                Wallet.update pulseChain (Wallet.WalletConnectRejected 1) (Wallet.Connecting 1)
                    |> Expect.equal Wallet.Disconnected
        , test "WalletConnectRejected with a stale requestId is dropped (stays Connecting)" <|
            \_ ->
                Wallet.update pulseChain (Wallet.WalletConnectRejected 1) (Wallet.Connecting 2)
                    |> Expect.equal (Wallet.Connecting 2)
        , test "WalletConnectPending never changes state, matching or not" <|
            \_ ->
                Wallet.update pulseChain (Wallet.WalletConnectPending 1) (Wallet.Connecting 1)
                    |> Expect.equal (Wallet.Connecting 1)
        , test "WalletConnectFailed with a matching requestId -> Error with the message" <|
            \_ ->
                Wallet.update pulseChain (Wallet.WalletConnectFailed 1 Wallet.NetworkError "boom") (Wallet.Connecting 1)
                    |> Expect.equal (Wallet.Error "boom")
        , test "WalletConnectFailed with a stale requestId is dropped (stays Connecting)" <|
            \_ ->
                Wallet.update pulseChain (Wallet.WalletConnectFailed 1 Wallet.NetworkError "boom") (Wallet.Connecting 2)
                    |> Expect.equal (Wallet.Connecting 2)
        , test "timeoutConnect with a matching requestId -> Disconnected" <|
            \_ ->
                Wallet.timeoutConnect 1 (Wallet.Connecting 1)
                    |> Expect.equal Wallet.Disconnected
        , test "timeoutConnect with a stale requestId is a no-op (a newer attempt superseded it)" <|
            \_ ->
                Wallet.timeoutConnect 1 (Wallet.Connecting 2)
                    |> Expect.equal (Wallet.Connecting 2)
        , test "timeoutConnect is a no-op once already Connected" <|
            \_ ->
                let
                    connected =
                        Wallet.update pulseChain (Wallet.WalletConnected (Just 1) validAddress 369) (Wallet.Connecting 1)
                in
                Wallet.timeoutConnect 1 connected
                    |> Expect.equal connected
        , test "isConnecting is True while Connecting, False otherwise" <|
            \_ ->
                Expect.all
                    [ \_ -> Wallet.isConnecting (Wallet.Connecting 1) |> Expect.equal True
                    , \_ -> Wallet.isConnecting Wallet.Disconnected |> Expect.equal False
                    , \_ -> Wallet.isConnecting Wallet.ReadOnly |> Expect.equal False
                    ]
                    ()
        , test "connectingRequestId returns Just the active id while Connecting, Nothing otherwise" <|
            \_ ->
                Expect.all
                    [ \_ -> Wallet.connectingRequestId (Wallet.Connecting 5) |> Expect.equal (Just 5)
                    , \_ -> Wallet.connectingRequestId Wallet.Disconnected |> Expect.equal Nothing
                    ]
                    ()
        , test "startConnect mints Connecting with the given id" <|
            \_ ->
                Wallet.startConnect 42 Wallet.Disconnected
                    |> Expect.equal (Wallet.Connecting 42)
        , test "startConnect while already Connecting supersedes with the new id (overlapping attempts)" <|
            \_ ->
                Wallet.startConnect 2 (Wallet.Connecting 1)
                    |> Expect.equal (Wallet.Connecting 2)
        , test "a superseded attempt's late response is dropped once startConnect has moved on" <|
            \_ ->
                let
                    superseded =
                        Wallet.startConnect 2 (Wallet.Connecting 1)
                in
                Wallet.update pulseChain (Wallet.WalletConnected (Just 1) validAddress 369) superseded
                    |> Expect.equal (Wallet.Connecting 2)
        ]


stateTransitionTests : Test
stateTransitionTests =
    describe "update state transitions"
        [ test "Disconnected + WalletConnected on expected chain -> Connected" <|
            \_ ->
                Wallet.update pulseChain (Wallet.WalletConnected Nothing validAddress 369) Wallet.Disconnected
                    |> Wallet.isConnected
                    |> Expect.equal True
        , test "Disconnected + WalletConnected on wrong chain -> WrongChain" <|
            \_ ->
                let
                    newState =
                        Wallet.update pulseChain (Wallet.WalletConnected Nothing validAddress 1) Wallet.Disconnected
                in
                case newState of
                    Wallet.WrongChain _ _ ->
                        Expect.pass

                    _ ->
                        Expect.fail "Expected WrongChain"
        , test "WalletConnected with invalid address -> Error" <|
            \_ ->
                let
                    newState =
                        Wallet.update pulseChain (Wallet.WalletConnected Nothing "not-an-address" 369) Wallet.Disconnected
                in
                case newState of
                    Wallet.Error _ ->
                        Expect.pass

                    _ ->
                        Expect.fail "Expected Error"
        , test "Connected + WalletDisconnected -> Disconnected" <|
            \_ ->
                let
                    connected =
                        Wallet.update pulseChain (Wallet.WalletConnected Nothing validAddress 369) Wallet.Disconnected
                in
                Wallet.update pulseChain Wallet.WalletDisconnected connected
                    |> Expect.equal Wallet.Disconnected
        , test "Connected + ChainChanged to expected chain -> Connected" <|
            \_ ->
                let
                    connected =
                        Wallet.update pulseChain (Wallet.WalletConnected Nothing validAddress 369) Wallet.Disconnected

                    newState =
                        Wallet.update pulseChain (Wallet.ChainChanged 369) connected
                in
                Wallet.isConnected newState |> Expect.equal True
        , test "Connected + ChainChanged to wrong chain -> WrongChain" <|
            \_ ->
                let
                    connected =
                        Wallet.update pulseChain (Wallet.WalletConnected Nothing validAddress 369) Wallet.Disconnected

                    newState =
                        Wallet.update pulseChain (Wallet.ChainChanged 1) connected
                in
                case newState of
                    Wallet.WrongChain _ _ ->
                        Expect.pass

                    _ ->
                        Expect.fail "Expected WrongChain"
        , test "WrongChain + ChainChanged to expected chain -> Connected (manual switch in wallet UI recovers)" <|
            \_ ->
                let
                    wrongChain =
                        Wallet.update pulseChain (Wallet.WalletConnected Nothing validAddress 1) Wallet.Disconnected

                    newState =
                        Wallet.update pulseChain (Wallet.ChainChanged 369) wrongChain
                in
                Wallet.isConnected newState |> Expect.equal True
        , test "WrongChain + ChainChanged to another wrong chain -> stays WrongChain (chainId updated)" <|
            \_ ->
                let
                    wrongChain =
                        Wallet.update pulseChain (Wallet.WalletConnected Nothing validAddress 1) Wallet.Disconnected

                    newState =
                        Wallet.update pulseChain (Wallet.ChainChanged 56) wrongChain
                in
                case newState of
                    Wallet.WrongChain info _ ->
                        T.chainIdToInt info.chainId |> Expect.equal 56

                    _ ->
                        Expect.fail "Expected WrongChain to remain"
        , test "Connected + ReadOnlyMode is a no-op (stray readOnly must not tear down a session)" <|
            \_ ->
                let
                    connected =
                        Wallet.update pulseChain (Wallet.WalletConnected Nothing validAddress 369) Wallet.Disconnected
                in
                Wallet.update pulseChain Wallet.ReadOnlyMode connected
                    |> Wallet.isConnected
                    |> Expect.equal True
        , test "WrongChain + ReadOnlyMode is a no-op" <|
            \_ ->
                let
                    wrongChain =
                        Wallet.update pulseChain (Wallet.WalletConnected Nothing validAddress 1) Wallet.Disconnected
                in
                case Wallet.update pulseChain Wallet.ReadOnlyMode wrongChain of
                    Wallet.WrongChain _ _ ->
                        Expect.pass

                    _ ->
                        Expect.fail "Expected WrongChain to survive ReadOnlyMode"
        , test "Disconnected + ReadOnlyMode -> ReadOnly" <|
            \_ ->
                Wallet.update pulseChain Wallet.ReadOnlyMode Wallet.Disconnected
                    |> Wallet.isReadOnly
                    |> Expect.equal True
        , test "Disconnected + ChainChanged -> Disconnected (no-op)" <|
            \_ ->
                Wallet.update pulseChain (Wallet.ChainChanged 1) Wallet.Disconnected
                    |> Expect.equal Wallet.Disconnected
        , test "Connected + AccountChanged valid address -> stays Connected" <|
            \_ ->
                let
                    connected =
                        Wallet.update pulseChain (Wallet.WalletConnected Nothing validAddress 369) Wallet.Disconnected

                    newState =
                        Wallet.update pulseChain (Wallet.AccountChanged validAddress2) connected
                in
                Wallet.isConnected newState |> Expect.equal True
        , test "Connected + AccountChanged valid address -> address updates" <|
            \_ ->
                let
                    connected =
                        Wallet.update pulseChain (Wallet.WalletConnected Nothing validAddress 369) Wallet.Disconnected

                    newState =
                        Wallet.update pulseChain (Wallet.AccountChanged validAddress2) connected
                in
                case Wallet.getAddress newState of
                    Just a ->
                        T.addressToString a |> Expect.equal validAddress2

                    Nothing ->
                        Expect.fail "Expected address"
        , test "Disconnected + AccountChanged -> Disconnected (no-op)" <|
            \_ ->
                Wallet.update pulseChain (Wallet.AccountChanged validAddress) Wallet.Disconnected
                    |> Expect.equal Wallet.Disconnected
        , test "any state + WalletError -> Error" <|
            \_ ->
                Wallet.update pulseChain (Wallet.WalletError "rejected") (Wallet.Connecting 1)
                    |> (\s ->
                            case s of
                                Wallet.Error _ ->
                                    Expect.pass

                                _ ->
                                    Expect.fail "Expected Error"
                       )
        , test "Connecting + WalletConnected on expected chain -> Connected" <|
            \_ ->
                Wallet.update pulseChain (Wallet.WalletConnected (Just 1) validAddress 369) (Wallet.Connecting 1)
                    |> Wallet.isConnected
                    |> Expect.equal True
        , test "ReadOnly + AccountChanged -> ReadOnly (no-op)" <|
            \_ ->
                Wallet.update pulseChain (Wallet.AccountChanged validAddress) Wallet.ReadOnly
                    |> Expect.equal Wallet.ReadOnly
        , test "Error + WalletDisconnected -> Disconnected (recovery)" <|
            \_ ->
                Wallet.update pulseChain Wallet.WalletDisconnected (Wallet.Error "something went wrong")
                    |> Expect.equal Wallet.Disconnected
        , test "SwitchChainOk on expected chain from WrongChain -> Connected" <|
            \_ ->
                let
                    wrongChain =
                        Wallet.update pulseChain (Wallet.WalletConnected Nothing validAddress 1) Wallet.Disconnected

                    newState =
                        Wallet.update pulseChain (Wallet.SwitchChainOk 369) wrongChain
                in
                Wallet.isConnected newState |> Expect.equal True
        , test "SwitchChainOk from Connected -> no-op" <|
            \_ ->
                let
                    connected =
                        Wallet.update pulseChain (Wallet.WalletConnected Nothing validAddress 369) Wallet.Disconnected

                    newState =
                        Wallet.update pulseChain (Wallet.SwitchChainOk 369) connected
                in
                Wallet.isConnected newState |> Expect.equal True
        , test "SwitchChainOk on wrong chain from WrongChain -> still WrongChain" <|
            \_ ->
                let
                    wrongChain =
                        Wallet.update pulseChain (Wallet.WalletConnected Nothing validAddress 1) Wallet.Disconnected

                    newState =
                        Wallet.update pulseChain (Wallet.SwitchChainOk 56) wrongChain
                in
                case newState of
                    Wallet.WrongChain _ _ ->
                        Expect.pass

                    _ ->
                        Expect.fail "Expected WrongChain"
        , test "startConnect from Disconnected -> Connecting" <|
            \_ ->
                Wallet.startConnect 1 Wallet.Disconnected
                    |> Expect.equal (Wallet.Connecting 1)
        , test "startConnect from Error -> Connecting" <|
            \_ ->
                Wallet.startConnect 1 (Wallet.Error "oops")
                    |> Expect.equal (Wallet.Connecting 1)
        , test "startConnect from Connected -> no-op" <|
            \_ ->
                let
                    connected =
                        Wallet.update pulseChain (Wallet.WalletConnected Nothing validAddress 369) Wallet.Disconnected
                in
                Wallet.startConnect 1 connected
                    |> Wallet.isConnected
                    |> Expect.equal True
        , test "startConnect from ReadOnly -> no-op" <|
            \_ ->
                Wallet.startConnect 1 Wallet.ReadOnly
                    |> Wallet.isReadOnly
                    |> Expect.equal True
        ]


helperTests : Test
helperTests =
    describe "helper functions"
        [ test "isConnected is False for Disconnected" <|
            \_ ->
                Wallet.isConnected Wallet.Disconnected |> Expect.equal False
        , test "isConnected is False for Connecting" <|
            \_ ->
                Wallet.isConnected (Wallet.Connecting 1) |> Expect.equal False
        , test "isReadOnly is True for ReadOnly" <|
            \_ ->
                Wallet.isReadOnly Wallet.ReadOnly |> Expect.equal True
        , test "isReadOnly is False for Disconnected" <|
            \_ ->
                Wallet.isReadOnly Wallet.Disconnected |> Expect.equal False
        , test "isReadOnly is False for Connected" <|
            \_ ->
                let
                    connected =
                        Wallet.update pulseChain (Wallet.WalletConnected Nothing validAddress 369) Wallet.Disconnected
                in
                Wallet.isReadOnly connected |> Expect.equal False
        , test "isReadOnly is False for Connecting" <|
            \_ ->
                Wallet.isReadOnly (Wallet.Connecting 1) |> Expect.equal False
        , test "getAddress returns Nothing for Disconnected" <|
            \_ ->
                Wallet.getAddress Wallet.Disconnected |> Expect.equal Nothing
        , test "getAddress returns Just for Connected" <|
            \_ ->
                let
                    connected =
                        Wallet.update pulseChain (Wallet.WalletConnected Nothing validAddress 369) Wallet.Disconnected
                in
                Wallet.getAddress connected |> Expect.notEqual Nothing
        , test "getChainId returns Nothing for Disconnected" <|
            \_ ->
                Wallet.getChainId Wallet.Disconnected |> Expect.equal Nothing
        , test "getChainId returns Just for Connected" <|
            \_ ->
                let
                    connected =
                        Wallet.update pulseChain (Wallet.WalletConnected Nothing validAddress 369) Wallet.Disconnected
                in
                case Wallet.getChainId connected of
                    Just cid ->
                        T.chainIdToInt cid |> Expect.equal 369

                    Nothing ->
                        Expect.fail "Expected chainId"
        ]


encoderTests : Test
encoderTests =
    describe "encode"
        [ test "connect encodes tag" <|
            \_ ->
                Wallet.encode (Wallet.connect 1)
                    |> D.decodeValue (D.field "tag" D.string)
                    |> Expect.equal (Ok "connect")
        , test "disconnect encodes tag" <|
            \_ ->
                Wallet.encode Wallet.disconnect
                    |> D.decodeValue (D.field "tag" D.string)
                    |> Expect.equal (Ok "disconnect")
        , test "switchChain encodes tag and chainId" <|
            \_ ->
                Wallet.encode (Wallet.switchChain pulseChain)
                    |> D.decodeValue
                        (D.map2 Tuple.pair
                            (D.field "tag" D.string)
                            (D.field "chainId" D.int)
                        )
                    |> Expect.equal (Ok ( "switchChain", 369 ))
        ]


decoderTests : Test
decoderTests =
    describe "decoder"
        [ test "decodes connected message with no requestId (silent reconnect shape)" <|
            \_ ->
                """{"tag":"connected","address":"0xabcdefabcdefabcdefabcdefabcdefabcdefabcd","chainId":369}"""
                    |> D.decodeString Wallet.decoder
                    |> (\result ->
                            case result of
                                Ok (Wallet.WalletConnected maybeRid addr chain) ->
                                    Expect.all
                                        [ \_ -> maybeRid |> Expect.equal Nothing
                                        , \_ -> addr |> Expect.equal "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
                                        , \_ -> chain |> Expect.equal 369
                                        ]
                                        ()

                                _ ->
                                    Expect.fail "Expected WalletConnected"
                       )
        , test "decodes connected message with a requestId" <|
            \_ ->
                """{"tag":"connected","requestId":7,"address":"0xabcdefabcdefabcdefabcdefabcdefabcdefabcd","chainId":369}"""
                    |> D.decodeString Wallet.decoder
                    |> (\result ->
                            case result of
                                Ok (Wallet.WalletConnected maybeRid _ _) ->
                                    maybeRid |> Expect.equal (Just 7)

                                _ ->
                                    Expect.fail "Expected WalletConnected"
                       )
        , test "decodes connectRejected message" <|
            \_ ->
                """{"tag":"connectRejected","requestId":3}"""
                    |> D.decodeString Wallet.decoder
                    |> Expect.equal (Ok (Wallet.WalletConnectRejected 3))
        , test "decodes connectPending message" <|
            \_ ->
                """{"tag":"connectPending","requestId":3}"""
                    |> D.decodeString Wallet.decoder
                    |> Expect.equal (Ok (Wallet.WalletConnectPending 3))
        , test "decodes connectFailed message with reason not_found" <|
            \_ ->
                """{"tag":"connectFailed","requestId":3,"reason":"not_found","error":"No wallet extension detected"}"""
                    |> D.decodeString Wallet.decoder
                    |> Expect.equal (Ok (Wallet.WalletConnectFailed 3 Wallet.NotFound "No wallet extension detected"))
        , test "decodes connectFailed message with reason no_accounts" <|
            \_ ->
                """{"tag":"connectFailed","requestId":3,"reason":"no_accounts","error":"Wallet returned no accounts"}"""
                    |> D.decodeString Wallet.decoder
                    |> Expect.equal (Ok (Wallet.WalletConnectFailed 3 Wallet.NoAccounts "Wallet returned no accounts"))
        , test "decodes connectFailed message with an unrecognized reason as NetworkError" <|
            \_ ->
                """{"tag":"connectFailed","requestId":3,"reason":"whatever","error":"boom"}"""
                    |> D.decodeString Wallet.decoder
                    |> Expect.equal (Ok (Wallet.WalletConnectFailed 3 Wallet.NetworkError "boom"))
        , test "decodes disconnected message" <|
            \_ ->
                """{"tag":"disconnected"}"""
                    |> D.decodeString Wallet.decoder
                    |> Expect.equal (Ok Wallet.WalletDisconnected)
        , test "decodes chainChanged message" <|
            \_ ->
                """{"tag":"chainChanged","chainId":1}"""
                    |> D.decodeString Wallet.decoder
                    |> Expect.equal (Ok (Wallet.ChainChanged 1))
        , test "decodes accountChanged message" <|
            \_ ->
                """{"tag":"accountChanged","address":"0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"}"""
                    |> D.decodeString Wallet.decoder
                    |> Expect.equal (Ok (Wallet.AccountChanged "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"))
        , test "decodes failed message as WalletError" <|
            \_ ->
                """{"tag":"failed","error":"connection dropped"}"""
                    |> D.decodeString Wallet.decoder
                    |> Expect.equal (Ok (Wallet.WalletError "connection dropped"))
        , test "unknown tag 'error' is now rejected (use 'failed')" <|
            \_ ->
                """{"tag":"error","error":"user rejected"}"""
                    |> D.decodeString Wallet.decoder
                    |> (\result ->
                            case result of
                                Err _ ->
                                    Expect.pass

                                Ok _ ->
                                    Expect.fail "Expected decode failure: 'error' tag removed, use 'failed'"
                       )
        , test "decodes switchChainOk message" <|
            \_ ->
                """{"tag":"switchChainOk","chainId":369}"""
                    |> D.decodeString Wallet.decoder
                    |> Expect.equal (Ok (Wallet.SwitchChainOk 369))
        , test "fails on unknown tag" <|
            \_ ->
                """{"tag":"unknown"}"""
                    |> D.decodeString Wallet.decoder
                    |> (\result ->
                            case result of
                                Err _ ->
                                    Expect.pass

                                Ok _ ->
                                    Expect.fail "Expected decode failure"
                       )
        , test "fails on missing tag" <|
            \_ ->
                """{"address":"0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"}"""
                    |> D.decodeString Wallet.decoder
                    |> (\result ->
                            case result of
                                Err _ ->
                                    Expect.pass

                                Ok _ ->
                                    Expect.fail "Expected decode failure"
                       )
        , test "decodes readOnly message as ReadOnlyMode" <|
            \_ ->
                """{"tag":"readOnly"}"""
                    |> D.decodeString Wallet.decoder
                    |> Expect.equal (Ok Wallet.ReadOnlyMode)
        , test "ReadOnlyMode update transitions to ReadOnly state" <|
            \_ ->
                Wallet.update pulseChain Wallet.ReadOnlyMode Wallet.Disconnected
                    |> Wallet.isReadOnly
                    |> Expect.equal True
        ]


watchAssetTests : Test
watchAssetTests =
    describe "watchAsset"
        [ test "watchAsset encode has correct tag" <|
            \_ ->
                case T.address validAddress of
                    Just addr ->
                        Wallet.encode (Wallet.watchAsset { address = addr, symbol = "HEX", decimals = 8, image = "" })
                            |> D.decodeValue (D.field "tag" D.string)
                            |> Expect.equal (Ok "watchAsset")

                    Nothing ->
                        Expect.fail "Invalid address"
        , test "watchAsset encode has address field" <|
            \_ ->
                case T.address validAddress of
                    Just addr ->
                        Wallet.encode (Wallet.watchAsset { address = addr, symbol = "HEX", decimals = 8, image = "" })
                            |> D.decodeValue (D.field "address" D.string)
                            |> Expect.equal (Ok validAddress)

                    Nothing ->
                        Expect.fail "Invalid address"
        , test "assetWatched decodes to AssetWatched" <|
            \_ ->
                """{"tag":"assetWatched"}"""
                    |> D.decodeString Wallet.decoder
                    |> Expect.equal (Ok Wallet.AssetWatched)
        ]


permissionsTests : Test
permissionsTests =
    describe "permissions"
        [ test "requestPermissions encode has correct tag" <|
            \_ ->
                Wallet.encode Wallet.requestPermissions
                    |> D.decodeValue (D.field "tag" D.string)
                    |> Expect.equal (Ok "requestPermissions")
        , test "getPermissions encode has correct tag" <|
            \_ ->
                Wallet.encode Wallet.getPermissions
                    |> D.decodeValue (D.field "tag" D.string)
                    |> Expect.equal (Ok "getPermissions")
        , test "permissions message decodes to GotPermissions" <|
            \_ ->
                """{"tag":"permissions","permissions":["eth_accounts"]}"""
                    |> D.decodeString Wallet.decoder
                    |> Expect.equal (Ok (Wallet.GotPermissions [ "eth_accounts" ]))
        ]
