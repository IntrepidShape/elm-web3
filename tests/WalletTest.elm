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
        ]


stateTransitionTests : Test
stateTransitionTests =
    describe "update state transitions"
        [ test "Disconnected + WalletConnected on expected chain -> Connected" <|
            \_ ->
                Wallet.update pulseChain (Wallet.WalletConnected validAddress 369) Wallet.Disconnected
                    |> Wallet.isConnected
                    |> Expect.equal True
        , test "Disconnected + WalletConnected on wrong chain -> WrongChain" <|
            \_ ->
                let
                    newState =
                        Wallet.update pulseChain (Wallet.WalletConnected validAddress 1) Wallet.Disconnected
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
                        Wallet.update pulseChain (Wallet.WalletConnected "not-an-address" 369) Wallet.Disconnected
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
                        Wallet.update pulseChain (Wallet.WalletConnected validAddress 369) Wallet.Disconnected
                in
                Wallet.update pulseChain Wallet.WalletDisconnected connected
                    |> Expect.equal Wallet.Disconnected
        , test "Connected + ChainChanged to expected chain -> Connected" <|
            \_ ->
                let
                    connected =
                        Wallet.update pulseChain (Wallet.WalletConnected validAddress 369) Wallet.Disconnected

                    newState =
                        Wallet.update pulseChain (Wallet.ChainChanged 369) connected
                in
                Wallet.isConnected newState |> Expect.equal True
        , test "Connected + ChainChanged to wrong chain -> WrongChain" <|
            \_ ->
                let
                    connected =
                        Wallet.update pulseChain (Wallet.WalletConnected validAddress 369) Wallet.Disconnected

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
                        Wallet.update pulseChain (Wallet.WalletConnected validAddress 1) Wallet.Disconnected

                    newState =
                        Wallet.update pulseChain (Wallet.ChainChanged 369) wrongChain
                in
                Wallet.isConnected newState |> Expect.equal True
        , test "WrongChain + ChainChanged to another wrong chain -> stays WrongChain (chainId updated)" <|
            \_ ->
                let
                    wrongChain =
                        Wallet.update pulseChain (Wallet.WalletConnected validAddress 1) Wallet.Disconnected

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
                        Wallet.update pulseChain (Wallet.WalletConnected validAddress 369) Wallet.Disconnected
                in
                Wallet.update pulseChain Wallet.ReadOnlyMode connected
                    |> Wallet.isConnected
                    |> Expect.equal True
        , test "WrongChain + ReadOnlyMode is a no-op" <|
            \_ ->
                let
                    wrongChain =
                        Wallet.update pulseChain (Wallet.WalletConnected validAddress 1) Wallet.Disconnected
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
                        Wallet.update pulseChain (Wallet.WalletConnected validAddress 369) Wallet.Disconnected

                    newState =
                        Wallet.update pulseChain (Wallet.AccountChanged validAddress2) connected
                in
                Wallet.isConnected newState |> Expect.equal True
        , test "Connected + AccountChanged valid address -> address updates" <|
            \_ ->
                let
                    connected =
                        Wallet.update pulseChain (Wallet.WalletConnected validAddress 369) Wallet.Disconnected

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
                Wallet.update pulseChain (Wallet.WalletError "rejected") Wallet.Connecting
                    |> (\s ->
                            case s of
                                Wallet.Error _ ->
                                    Expect.pass

                                _ ->
                                    Expect.fail "Expected Error"
                       )
        , test "Connecting + WalletConnected on expected chain -> Connected" <|
            \_ ->
                Wallet.update pulseChain (Wallet.WalletConnected validAddress 369) Wallet.Connecting
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
                        Wallet.update pulseChain (Wallet.WalletConnected validAddress 1) Wallet.Disconnected

                    newState =
                        Wallet.update pulseChain (Wallet.SwitchChainOk 369) wrongChain
                in
                Wallet.isConnected newState |> Expect.equal True
        , test "SwitchChainOk from Connected -> no-op" <|
            \_ ->
                let
                    connected =
                        Wallet.update pulseChain (Wallet.WalletConnected validAddress 369) Wallet.Disconnected

                    newState =
                        Wallet.update pulseChain (Wallet.SwitchChainOk 369) connected
                in
                Wallet.isConnected newState |> Expect.equal True
        , test "SwitchChainOk on wrong chain from WrongChain -> still WrongChain" <|
            \_ ->
                let
                    wrongChain =
                        Wallet.update pulseChain (Wallet.WalletConnected validAddress 1) Wallet.Disconnected

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
                Wallet.startConnect Wallet.Disconnected
                    |> Expect.equal Wallet.Connecting
        , test "startConnect from Error -> Connecting" <|
            \_ ->
                Wallet.startConnect (Wallet.Error "oops")
                    |> Expect.equal Wallet.Connecting
        , test "startConnect from Connected -> no-op" <|
            \_ ->
                let
                    connected =
                        Wallet.update pulseChain (Wallet.WalletConnected validAddress 369) Wallet.Disconnected
                in
                Wallet.startConnect connected
                    |> Wallet.isConnected
                    |> Expect.equal True
        , test "startConnect from ReadOnly -> no-op" <|
            \_ ->
                Wallet.startConnect Wallet.ReadOnly
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
                Wallet.isConnected Wallet.Connecting |> Expect.equal False
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
                        Wallet.update pulseChain (Wallet.WalletConnected validAddress 369) Wallet.Disconnected
                in
                Wallet.isReadOnly connected |> Expect.equal False
        , test "isReadOnly is False for Connecting" <|
            \_ ->
                Wallet.isReadOnly Wallet.Connecting |> Expect.equal False
        , test "getAddress returns Nothing for Disconnected" <|
            \_ ->
                Wallet.getAddress Wallet.Disconnected |> Expect.equal Nothing
        , test "getAddress returns Just for Connected" <|
            \_ ->
                let
                    connected =
                        Wallet.update pulseChain (Wallet.WalletConnected validAddress 369) Wallet.Disconnected
                in
                Wallet.getAddress connected |> Expect.notEqual Nothing
        , test "getChainId returns Nothing for Disconnected" <|
            \_ ->
                Wallet.getChainId Wallet.Disconnected |> Expect.equal Nothing
        , test "getChainId returns Just for Connected" <|
            \_ ->
                let
                    connected =
                        Wallet.update pulseChain (Wallet.WalletConnected validAddress 369) Wallet.Disconnected
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
                Wallet.encode Wallet.connect
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
        [ test "decodes connected message" <|
            \_ ->
                """{"tag":"connected","address":"0xabcdefabcdefabcdefabcdefabcdefabcdefabcd","chainId":369}"""
                    |> D.decodeString Wallet.decoder
                    |> (\result ->
                            case result of
                                Ok (Wallet.WalletConnected addr chain) ->
                                    Expect.all
                                        [ \_ -> addr |> Expect.equal "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
                                        , \_ -> chain |> Expect.equal 369
                                        ]
                                        ()

                                _ ->
                                    Expect.fail "Expected WalletConnected"
                       )
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
