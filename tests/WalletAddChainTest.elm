module WalletAddChainTest exposing (suite)

import Expect
import Json.Decode as D
import Test exposing (..)
import Web3.Types as T
import Web3.Wallet as Wallet


suite : Test
suite =
    describe "Web3.Wallet — addChain (EIP-3085)"
        [ encodeTests
        , decodeTests
        ]


pulseChainConfig : Wallet.ChainConfig
pulseChainConfig =
    { chainId = 369
    , chainName = "PulseChain"
    , rpcUrls = [ "https://rpc.pulsechain.com" ]
    , nativeCurrency = { name = "Pulse", symbol = "PLS", decimals = 18 }
    , blockExplorerUrls = [ "https://scan.pulsechain.com" ]
    }


pulseChain : T.ChainId
pulseChain =
    T.chainId 369


validAddress : String
validAddress =
    "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"


encodeTests : Test
encodeTests =
    describe "encode addChain"
        [ test "tag is 'addChain'" <|
            \_ ->
                Wallet.encode (Wallet.addChain pulseChainConfig)
                    |> D.decodeValue (D.field "tag" D.string)
                    |> Expect.equal (Ok "addChain")
        , test "chainId is encoded as int" <|
            \_ ->
                Wallet.encode (Wallet.addChain pulseChainConfig)
                    |> D.decodeValue (D.field "chainId" D.int)
                    |> Expect.equal (Ok 369)
        , test "chainName is encoded" <|
            \_ ->
                Wallet.encode (Wallet.addChain pulseChainConfig)
                    |> D.decodeValue (D.field "chainName" D.string)
                    |> Expect.equal (Ok "PulseChain")
        , test "rpcUrls is encoded as list" <|
            \_ ->
                Wallet.encode (Wallet.addChain pulseChainConfig)
                    |> D.decodeValue (D.field "rpcUrls" (D.list D.string))
                    |> Expect.equal (Ok [ "https://rpc.pulsechain.com" ])
        , test "nativeCurrency is encoded" <|
            \_ ->
                Wallet.encode (Wallet.addChain pulseChainConfig)
                    |> D.decodeValue
                        (D.field "nativeCurrency"
                            (D.map3 (\n s d -> ( n, s, d ))
                                (D.field "name" D.string)
                                (D.field "symbol" D.string)
                                (D.field "decimals" D.int)
                            )
                        )
                    |> Expect.equal (Ok ( "Pulse", "PLS", 18 ))
        , test "blockExplorerUrls is encoded" <|
            \_ ->
                Wallet.encode (Wallet.addChain pulseChainConfig)
                    |> D.decodeValue (D.field "blockExplorerUrls" (D.list D.string))
                    |> Expect.equal (Ok [ "https://scan.pulsechain.com" ])
        ]


decodeTests : Test
decodeTests =
    describe "decode chainAdded"
        [ test "decodes chainAdded tag" <|
            \_ ->
                """{"tag":"chainAdded"}"""
                    |> D.decodeString Wallet.decoder
                    |> Expect.equal (Ok Wallet.ChainAdded)
        , test "ChainAdded does not change Connected state" <|
            \_ ->
                let
                    connected =
                        Wallet.update pulseChain (Wallet.WalletConnected Nothing validAddress 369) Wallet.Disconnected

                    afterAdd =
                        Wallet.update pulseChain Wallet.ChainAdded connected
                in
                Wallet.isConnected afterAdd
                    |> Expect.equal True
        , test "ChainAdded does not change Disconnected state" <|
            \_ ->
                Wallet.update pulseChain Wallet.ChainAdded Wallet.Disconnected
                    |> Expect.equal Wallet.Disconnected
        ]
