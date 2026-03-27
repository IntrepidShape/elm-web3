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
        , test "WrongChain + ChainChanged is a no-op (only Connected handles ChainChanged)" <|
            \_ ->
                let
                    wrongChain =
                        Wallet.update pulseChain (Wallet.WalletConnected validAddress 1) Wallet.Disconnected

                    newState =
                        Wallet.update pulseChain (Wallet.ChainChanged 369) wrongChain
                in
                case newState of
                    Wallet.WrongChain _ _ ->
                        Expect.pass

                    _ ->
                        Expect.fail "Expected WrongChain to remain (ChainChanged only handled in Connected state)"
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
        , test "decodes error message" <|
            \_ ->
                """{"tag":"error","message":"user rejected"}"""
                    |> D.decodeString Wallet.decoder
                    |> Expect.equal (Ok (Wallet.WalletError "user rejected"))
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
        ]
