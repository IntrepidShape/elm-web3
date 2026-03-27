# elm-web3

Type-safe EVM blockchain interaction for Elm. Zero runtime exceptions.

**80% of your frontend code gets zero runtime exceptions.** Not fewer. Zero. The Elm compiler guarantees it.

The remaining 20% is a ~500-line JavaScript port bridge that catches every error and routes it back to Elm as a typed message. Your app never white-screens.

## What it is

A package for building EVM dapps in Elm. It provides:

- **Opaque, validated types** for addresses, transaction hashes, chain IDs, and wei amounts — the compiler prevents mixing them up
- **Wallet state machine** that makes invalid states unrepresentable (no "connected but address is null")
- **Transaction lifecycle state machine** with exhaustive pattern matching including revert reason decoding
- **Typed contract calls** (reads and writes) with JSON encoders/decoders
- **Multicall** for batching multiple reads into one RPC round-trip
- **EIP-712 typed data signing** with a full state machine for the signing flow
- **EIP-6963 multi-wallet discovery** — MetaMask, Rabby, and any injected wallet
- **Balance, block, fee, and query modules** for on-chain reads with correlation IDs
- **Pure-Elm unit conversion** (ETH ↔ Wei, ERC-20 decimals)
- **ABI code generator** that reads Solidity ABI JSON and outputs typed Elm modules

The JS layer is ~500 lines with zero npm dependencies. No ethers. No viem. No web3.js. Just `window.ethereum.request()`.

The Elm layer depends only on the Elm standard library (`elm/core`, `elm/json`, `elm/http`, `elm/time`). No third-party Elm packages.

## Install

```bash
elm install intrepidshape/elm-web3
```

Then copy `js/elm-web3-ports.js` into your project and load it after your compiled Elm JS:

```html
<script src="elm.js"></script>
<script src="elm-web3-ports.js"></script>
<script>
  var app = Elm.Main.init({ node: document.getElementById('app') });
  setupPorts(app);
</script>
```

Define your Elm ports:

```elm
port module Ports exposing (..)

import Json.Encode as E
import Json.Decode as D

port web3Cmd : E.Value -> Cmd msg
port web3Sub : (D.Value -> msg) -> Sub msg
```

## Modules

### `Web3.Types`

Opaque types that prevent mixing up addresses, transaction hashes, and chain IDs.

```elm
address : String -> Maybe Address        -- validates 0x + 40 hex chars
txHash : String -> Maybe TxHash          -- validates 0x + 64 hex chars
chainId : Int -> ChainId
encodeBlockNumber : BlockNumber -> E.Value
```

You can't pass a `TxHash` where an `Address` is expected. The compiler catches it at build time.

### `Web3.Wallet`

Wallet connection as an explicit state machine. The central type is `State`:

```elm
type State
    = Disconnected
    | ReadOnly                                    -- rpcUrl configured, no wallet
    | Connecting
    | Connected { address : Address, chainId : ChainId }
    | WrongChain { address : Address, chainId : ChainId } ChainId
    | Error String
```

Key functions:

```elm
startConnect : State -> State              -- Disconnected → Connecting
update : ChainId -> Msg -> State -> State  -- drive state machine from port messages
connect, disconnect : WalletCmd
switchChain : ChainId -> WalletCmd
selectWallet : String -> WalletCmd         -- EIP-6963 RDNS identifier
addChain : ChainConfig -> WalletCmd        -- EIP-3085
watchAsset : { address, symbol, decimals, image } -> WalletCmd  -- EIP-747
requestPermissions, getPermissions : WalletCmd  -- EIP-2255
encode : WalletCmd -> E.Value
decoder : D.Decoder Msg
```

### `Web3.Transaction`

Transaction lifecycle as a state machine. The central type is `Status`:

```elm
type Status
    = Idle
    | AwaitingSignature
    | Submitted TxHash
    | Confirming TxHash Int      -- hash + confirmation count
    | Confirmed Receipt
    | Failed String              -- includes decoded revert reason when available
    | Rejected
```

Key functions:

```elm
update : Msg -> Status -> Status
isTerminal : Status -> Bool
isPending : Status -> Bool
transactionConfirmations : Int -> Receipt -> Int
encodeCmd : TxCmd -> E.Value          -- encode RequestReceipt for port
decoder : D.Decoder Msg
parseReceiptEvents : List (EventLog -> Maybe a) -> Receipt -> List a
```

### `Web3.Contract.Call`

Typed read-only contract calls (`eth_call`).

```elm
readCall :
    { contract : Address, method : String, args : List E.Value
    , decoder : D.Decoder a, id : String }
    -> ReadCall a

withBlock : BlockNumber -> ReadCall a -> ReadCall a
withFrom  : Address    -> ReadCall a -> ReadCall a   -- simulate write without broadcasting
encode : ReadCall a -> E.Value
responseDecoder : ReadCall a -> D.Decoder a
```

### `Web3.Contract.Send`

Typed write calls (`eth_sendTransaction`).

```elm
writeCall   : { contract, method, args } -> WriteCall
payableCall : { contract, method, args, value : BigInt } -> WriteCall
withGasLimit : Int -> WriteCall -> WriteCall
encode : WriteCall -> E.Value
estimateGas : WriteCall -> E.Value
deployCall : { bytecode, args, gasLimit } -> E.Value
encodeRawSend : String -> E.Value    -- broadcast pre-signed transaction
```

### `Web3.Contract.Event`

Event subscriptions and historical log queries.

```elm
watchEvent : EventFilter -> E.Value
getLogs : GetLogsQuery -> E.Value
decoder : D.Decoder a -> D.Decoder (EventLog a)
logsDecoder : D.Decoder a -> D.Decoder (List (EventLog a))
```

`EventLog a` carries `data`, `contract`, `topics`, `blockNumber`, `txHash`, and `logIndex`.

### `Web3.Multicall`

Batch multiple contract reads into one `eth_call` via the Multicall3 contract
(`0xcA11bde05977b3631167028862bE2a173976CA11`, deployed on all major networks).

```elm
callSpec : Address -> String -> List E.Value -> CallSpec
batch : String -> List CallSpec -> MulticallRequest
encode : MulticallRequest -> E.Value
responseDecoder : List (D.Decoder a) -> D.Decoder (List (Result String a))
```

One RPC round-trip instead of N. Essential for dashboards.

### `Web3.Sign`

EIP-712 typed data signing and EIP-191 personal signing.

```elm
typedData : { domain, types, primaryType, message } -> TypedData
encode : String -> Address -> TypedData -> E.Value    -- send via port
personalSign : String -> Address -> String -> E.Value

type SignState = SignIdle | SignPending String | Signed String String
              | SignFailed String String | SignRejected String

startSign : String -> SignState -> SignState
signUpdate : SignMsg -> SignState -> SignState
isSignTerminal : SignState -> Bool
signatureDecoder : D.Decoder String
```

### `Web3.Balance`

Native ETH/PLS balance queries. Each query carries a correlation ID so multiple queries can be in flight at once.

```elm
getBalance : Address -> String -> Cmd
encode : Cmd -> E.Value
decoder : D.Decoder Msg    -- GotBalance id wei
```

### `Web3.Block`

Block number queries, block data fetching, and block number watching.

```elm
getBlockNumber : String -> Cmd
getBlock : BlockNumber -> String -> Cmd
watchBlockNumber : String -> Cmd          -- polls every 4 seconds
getBlockTransactionCount : BlockNumber -> String -> Cmd
encode : Cmd -> E.Value
decoder : D.Decoder Msg    -- GotBlockNumber | GotBlock | GotBlockTxCount
```

### `Web3.Fee`

Gas price and EIP-1559 fee history.

```elm
getGasPrice : String -> Cmd
getFeeHistory : String -> Int -> Cmd    -- id, blockCount
encode : Cmd -> E.Value
decoder : D.Decoder Msg    -- GotGasPrice | GotFeeHistory
```

### `Web3.Query`

On-chain read queries: transaction count (nonce), storage slots, contract bytecode, and transaction lookup.

```elm
getTxCount : Address -> String -> Cmd
getStorageAt : Address -> Int -> String -> Cmd
getCode : Address -> String -> Cmd
getTransaction : TxHash -> String -> Cmd
encode : Cmd -> E.Value
decoder : D.Decoder Msg    -- GotTxCount | GotStorageAt | GotCode | GotTransaction | TransactionNotFound
```

### `Web3.Units`

Pure-Elm ETH and ERC-20 unit conversion. No port required.

```elm
formatEther : BigInt -> String           -- Wei to ETH string, trailing zeros trimmed
parseEther  : String -> Maybe BigInt     -- ETH string to Wei

formatUnits : Int -> BigInt -> String    -- custom decimals
parseUnits  : Int -> String -> Maybe BigInt
```

### `Web3.Chain`

Chain definitions for all major EVM networks:

```elm
ethereum, sepolia : Chain
pulsechain, pulsechainTestnet : Chain
bsc, polygon, arbitrum, optimism, base : Chain
avalanche, zksync, fantom, gnosis, linea, scroll : Chain
custom : { chainId, name, rpcUrl, blockExplorer, nativeCurrency } -> Chain

chainId : Chain -> T.ChainId
name, rpcUrl, blockExplorer : Chain -> String
```

### `Web3.BigInt`

Arbitrary-precision integers for uint256 and int256 values. No external dependencies — base-10^7 digit representation, safe within Elm's 53-bit integer range.

```elm
fromInt : Int -> BigInt
fromString : String -> Maybe BigInt
fromIntString : String -> Maybe BigInt
fromHexString : String -> Maybe BigInt    -- 0x-prefixed
toString : BigInt -> String

add, sub, mul : BigInt -> BigInt -> BigInt
div, mod : BigInt -> BigInt -> Maybe BigInt
compare : BigInt -> BigInt -> Order
gt, gte, lt, lte, eq : BigInt -> BigInt -> Bool
zero : BigInt
isZero : BigInt -> Bool
decoder : D.Decoder BigInt
```

### `Web3.Abi.Encode` / `Web3.Abi.Decode`

Helpers for encoding contract call parameters and decoding return values.

Encoders: `address`, `uint256`, `int256`, `bool`, `string`, `bytes`, `bytes32`, `bytesN`, `list`, `tuple2`, `tuple3`

Decoders: `address`, `uint256`, `int256`, `bool`, `string`, `bytes32`, `uint8`, `uint16`, `uint32`, `uint64`, `uint128`

Hex-slot decoders (for decoding raw ABI-encoded `hex` return values without a JS ABI library):
`hexSlot`, `uint256Slot`, `addressSlot`, `boolSlot`, `stringSlot`, `listSlot`, `tuple2Hex`, `tuple3Hex`

Revert reason extraction:
```elm
decodeRevertReason : String -> Maybe String   -- hex data -> human-readable string
```

### `Web3.Crypto`

Keccak256 hashing via port (JS side uses the built-in implementation).

```elm
keccak256 : String -> String -> Cmd    -- message, id
encode : Cmd -> E.Value
decoder : D.Decoder Msg    -- GotKeccak256 id hash
```

## Wallet connection flow

```elm
type alias Model =
    { wallet : Wallet.State
    , availableWallets : List Wallet.WalletProvider
    }

type Msg
    = ConnectWallet
    | SelectWallet String
    | Web3Response D.Value

expectedChain : T.ChainId
expectedChain = Web3.Chain.chainId Web3.Chain.pulsechain

update msg model =
    case msg of
        ConnectWallet ->
            ( { model | wallet = Wallet.startConnect model.wallet }
            , Ports.web3Cmd (Wallet.encode Wallet.connect)
            )

        SelectWallet rdns ->
            ( model
            , Ports.web3Cmd (Wallet.encode (Wallet.selectWallet rdns))
            )

        Web3Response value ->
            case D.decodeValue Wallet.decoder value of
                Ok walletMsg ->
                    let
                        newWallet =
                            Wallet.update expectedChain walletMsg model.wallet
                        wallets =
                            case walletMsg of
                                Wallet.WalletsDiscovered providers ->
                                    providers
                                _ ->
                                    model.availableWallets
                    in
                    ( { model | wallet = newWallet, availableWallets = wallets }
                    , Cmd.none
                    )
                Err _ ->
                    ( model, Cmd.none )

view model =
    case model.wallet of
        Wallet.Disconnected ->
            button [ onClick ConnectWallet ] [ text "Connect Wallet" ]

        Wallet.Connecting ->
            text "Connecting..."

        Wallet.Connected info ->
            text ("Connected: " ++ T.addressToString info.address)

        Wallet.WrongChain _ expectedId ->
            button
                [ onClick (Web3Response (Wallet.encode (Wallet.switchChain expectedId) |> always D.value)) ]
                [ text "Switch to PulseChain" ]

        Wallet.ReadOnly ->
            text "Read-only mode"

        Wallet.Error err ->
            text ("Error: " ++ err)
```

## Sending a transaction

```elm
import Web3.Contract.Send as Send
import Web3.Transaction as Tx

type Msg
    = Buy
    | TxResponse D.Value

buyCall : T.Address -> T.Wei -> Send.WriteCall
buyCall router value =
    Send.payableCall
        { contract = router
        , method = "buy(uint256)"
        , args = [ Encode.uint256 minTokensOut ]
        , value = value
        }

update msg model =
    case msg of
        Buy ->
            case Wallet.getAddress model.wallet of
                Just _ ->
                    ( { model | tx = Tx.AwaitingSignature }
                    , Ports.web3Cmd (Send.encode (buyCall routerAddress weiAmount))
                    )
                Nothing ->
                    ( model, Cmd.none )

        TxResponse value ->
            case D.decodeValue Tx.decoder value of
                Ok txMsg ->
                    ( { model | tx = Tx.update txMsg model.tx }, Cmd.none )
                Err _ ->
                    ( model, Cmd.none )

viewTx model =
    case model.tx of
        Tx.Idle          -> text ""
        Tx.AwaitingSignature -> text "Sign in wallet..."
        Tx.Submitted h   -> text ("Pending: " ++ T.txHashToString h)
        Tx.Confirming h n -> text (String.fromInt n ++ " confirmations")
        Tx.Confirmed r   -> text "Confirmed!"
        Tx.Failed err    -> text ("Failed: " ++ err)
        Tx.Rejected      -> text "Rejected"
```

## Contract reads and Multicall

```elm
import Web3.Contract.Call as Call
import Web3.Multicall as Multicall
import Web3.Abi.Encode as Encode
import Web3.Abi.Decode as Decode

-- Single read
balanceOfCall : T.Address -> T.Address -> Call.ReadCall T.Wei
balanceOfCall token holder =
    Call.readCall
        { contract = token
        , method = "balanceOf(address)"
        , args = [ Encode.address holder ]
        , decoder = Decode.uint256
        , id = "balance-" ++ T.addressToString holder
        }

-- Batch read (one RPC call)
batchBalances : T.Address -> List T.Address -> Multicall.MulticallRequest
batchBalances token holders =
    Multicall.batch "all-balances"
        (List.map
            (\holder ->
                Multicall.callSpec token "balanceOf(address)" [ Encode.address holder ]
            )
            holders
        )
```

## ABI encoding example

```elm
import Web3.Abi.Encode as E

-- function transfer(address to, uint256 amount) returns (bool)
transferArgs : T.Address -> BigInt -> List Json.Encode.Value
transferArgs to amount =
    [ E.address to
    , E.uint256 amount
    ]

-- function multicall((address target, bytes callData)[] calls)
multicallArgs : List ( T.Address, String ) -> List Json.Encode.Value
multicallArgs calls =
    [ E.list
        (E.tuple2 E.address E.bytes)
        calls
    ]
```

## EIP-712 signing

```elm
import Web3.Sign as Sign
import Dict

permitRequest : T.Address -> T.Address -> BigInt -> Int -> Sign.TypedData
permitRequest owner spender value nonce =
    Sign.typedData
        { domain =
            { name = Just "MyToken"
            , version = Just "1"
            , chainId = Just 369
            , verifyingContract = Just tokenAddress
            , salt = Nothing
            }
        , types =
            Dict.fromList
                [ ( "Permit"
                  , [ { name = "owner",    typeName = "address" }
                    , { name = "spender",  typeName = "address" }
                    , { name = "value",    typeName = "uint256" }
                    , { name = "nonce",    typeName = "uint256" }
                    , { name = "deadline", typeName = "uint256" }
                    ]
                  )
                ]
        , primaryType = "Permit"
        , message =
            Json.Encode.object
                [ ( "owner",    Json.Encode.string (T.addressToString owner) )
                , ( "spender",  Json.Encode.string (T.addressToString spender) )
                , ( "value",    Json.Encode.string (BigInt.toString value) )
                , ( "nonce",    Json.Encode.int nonce )
                , ( "deadline", Json.Encode.int 9999999999 )
                ]
        }

-- Send: web3Cmd (Sign.encode "permit-1" signerAddress (permitRequest ...))
-- Receive: case D.decodeValue Sign.signatureDecoder incoming of Ok sig -> ...
```

## Chain management

```elm
import Web3.Chain as Chain

-- Switch to a known chain
switchToPulseChain : Cmd msg
switchToPulseChain =
    Ports.web3Cmd
        (Wallet.encode (Wallet.switchChain (Chain.chainId Chain.pulsechain)))

-- Add a custom chain to the wallet
addCustomChain : Cmd msg
addCustomChain =
    Ports.web3Cmd
        (Wallet.encode
            (Wallet.addChain
                { chainId = 369
                , chainName = "PulseChain"
                , rpcUrls = [ "https://rpc.pulsechain.com" ]
                , nativeCurrency = { name = "Pulse", symbol = "PLS", decimals = 18 }
                , blockExplorerUrls = [ "https://scan.pulsechain.com" ]
                }
            )
        )
```

## Formal verification

The `proofs/` directory contains machine-checked Lean 4 proofs and TLA+ model-checked specifications. All proofs use only core Lean 4 — no Mathlib.

**Fully proved (zero `sorry`):**

- `Address.lean` — soundness, injectivity, and roundtrip for `address`/`addressToString`
- `TxHash.lean` — same three properties for `txHash`
- `HexString.lean` — same three properties for `hexString`
- `WalletCodec.lean` — encode/decode roundtrip, injectivity, partial inverse, and tag separation for `WalletCmd`
- `BigInt.lean` — nine arithmetic theorems (natNormalize, natAdd, natMulSmall, natAddSmall, shiftLeft, natSub, parseUnsigned, and more)
- `AbiCodec.lean` — bytes32 and address codec soundness/completeness/roundtrip
- `RevertReason.lean` — six theorems covering hex parsing, UTF-8 roundtrip, and selector/length guards

**TLA+ model-checked:**

- `WalletSpec.tla` — wallet state invariants and no-deadlock liveness
- `TransactionSpec.tla` — terminal states stay terminal, confirmation count is monotonic

See `proofs/COVERAGE.md` for the full coverage map.

## Code generator

```bash
bun codegen/generate.ts \
  out/MyContract.sol/MyContract.json \
  Generated.MyContract \
  src/Generated/MyContract.elm
```

Generates typed Elm modules from Solidity ABI JSON. Each function becomes a typed encoder; each event becomes a typed decoder. No magic strings in your app code.

## Supported chains

| Chain | ID | Constructor |
|---|---|---|
| Ethereum | 1 | `Chain.ethereum` |
| Sepolia | 11155111 | `Chain.sepolia` |
| PulseChain | 369 | `Chain.pulsechain` |
| PulseChain Testnet | 943 | `Chain.pulsechainTestnet` |
| BNB Smart Chain | 56 | `Chain.bsc` |
| Polygon | 137 | `Chain.polygon` |
| Arbitrum One | 42161 | `Chain.arbitrum` |
| Optimism | 10 | `Chain.optimism` |
| Base | 8453 | `Chain.base` |
| Avalanche C-Chain | 43114 | `Chain.avalanche` |
| zkSync Era | 324 | `Chain.zksync` |
| Fantom | 250 | `Chain.fantom` |
| Gnosis | 100 | `Chain.gnosis` |
| Linea | 59144 | `Chain.linea` |
| Scroll | 534352 | `Chain.scroll` |
| Any EVM chain | custom | `Chain.custom` |

## Prior art

- `cmditch/elm-ethereum` (2018) — web3.js era, Task-based, no longer maintained
- `purescript-web3` — similar concept in PureScript, stronger types but smaller ecosystem
- This package targets the modern wallet API (`window.ethereum`) with zero external JS dependencies

## License

MIT
