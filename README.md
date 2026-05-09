# elm-web3

EVM blockchain interaction for Elm applications.

Provides typed wrappers around the browser wallet API (`window.ethereum`), a small JavaScript port bridge, and pure-Elm utilities for working with blockchain data. The goal is to make wallet connection, transaction submission, and contract interaction feel like ordinary Elm — pattern-matched state machines, opaque types, and explicit update functions rather than callbacks or effects hidden in subscriptions.

## Install

```sh
elm install intrepidshape/elm-web3
```

Copy `js/elm-web3-ports.js` into your project and wire it up after your compiled Elm bundle:

```html
<script src="elm.js"></script>
<script src="elm-web3-ports.js"></script>
<script>
  var app = Elm.Main.init({ node: document.getElementById('app') });
  setupPorts(app);
</script>
```

Declare two ports in your Elm app:

```elm
port module Ports exposing (..)

import Json.Encode as E
import Json.Decode as D

port web3Cmd : E.Value -> Cmd msg
port web3Sub : (D.Value -> msg) -> Sub msg
```

## Design

The package communicates with the browser over two ports — one outgoing (`web3Cmd`) and one incoming (`web3Sub`). Everything in the JS bridge is wrapped in try/catch so errors arrive as typed `Msg` values rather than uncaught exceptions.

State machines are central to the design. `Wallet.State`, `Transaction.Status`, and `Sign.SignState` are all explicit union types — the compiler will tell you if you forget a branch.

The JS bridge has no npm dependencies. It calls `window.ethereum.request()` directly.

## Modules

### `Web3.Types`

Opaque types for the primitives that appear everywhere:

```elm
address : String -> Maybe Address        -- "0x" + 40 hex chars
txHash  : String -> Maybe TxHash         -- "0x" + 64 hex chars
chainId : Int    -> ChainId

addressToString : Address -> String
txHashToString  : TxHash  -> String
chainIdToInt    : ChainId -> Int
```

Passing a `TxHash` where an `Address` is expected is a compile error.

---

### `Web3.Wallet`

Wallet state as an explicit state machine:

```elm
type State
    = Disconnected
    | ReadOnly                              -- rpcUrl set, no wallet
    | Connecting
    | Connected { address : Address, chainId : ChainId }
    | WrongChain { address : Address, chainId : ChainId } ChainId
    | Error String
```

```elm
startConnect : State -> State
update : ChainId -> Msg -> State -> State

connect, disconnect : WalletCmd
switchChain         : ChainId -> WalletCmd
selectWallet        : String  -> WalletCmd   -- EIP-6963 RDNS
addChain            : ChainConfig -> WalletCmd   -- EIP-3085
watchAsset          : { address, symbol, decimals, image } -> WalletCmd  -- EIP-747
requestPermissions, getPermissions : WalletCmd  -- EIP-2255

encode  : WalletCmd -> E.Value
decoder : D.Decoder Msg
```

A minimal wallet flow:

```elm
type alias Model =
    { wallet : Wallet.State
    , providers : List Wallet.WalletProvider
    }

type Msg
    = ConnectWallet
    | PickWallet String
    | Web3Msg D.Value

expectedChain : T.ChainId
expectedChain =
    Chain.chainId Chain.pulsechain

update msg model =
    case msg of
        ConnectWallet ->
            ( { model | wallet = Wallet.startConnect model.wallet }
            , Ports.web3Cmd (Wallet.encode Wallet.connect)
            )

        PickWallet rdns ->
            ( model
            , Ports.web3Cmd (Wallet.encode (Wallet.selectWallet rdns))
            )

        Web3Msg raw ->
            case D.decodeValue Wallet.decoder raw of
                Ok walletMsg ->
                    let
                        newWallet =
                            Wallet.update expectedChain walletMsg model.wallet

                        providers =
                            case walletMsg of
                                Wallet.WalletsDiscovered ps -> ps
                                _ -> model.providers
                    in
                    ( { model | wallet = newWallet, providers = providers }
                    , Cmd.none
                    )

                Err _ ->
                    ( model, Cmd.none )

view model =
    case model.wallet of
        Wallet.Disconnected ->
            button [ onClick ConnectWallet ] [ text "Connect" ]

        Wallet.Connecting ->
            text "Connecting…"

        Wallet.Connected info ->
            text (T.addressToString info.address)

        Wallet.WrongChain _ expected ->
            button [ onClick (PickWallet "") ] [ text "Switch network" ]

        Wallet.ReadOnly ->
            text "Read-only"

        Wallet.Error err ->
            text ("Error: " ++ err)
```

---

### `Web3.Transaction`

Transaction lifecycle:

```elm
type Status
    = Idle
    | AwaitingSignature
    | Submitted TxHash
    | Confirming TxHash Int    -- confirmation count
    | Confirmed Receipt
    | Failed String            -- includes decoded revert reason when available
    | Rejected
```

```elm
update      : Msg    -> Status -> Status
isPending   : Status -> Bool
isTerminal  : Status -> Bool
encodeCmd   : TxCmd  -> E.Value      -- encode RequestReceipt for port
decoder     : D.Decoder Msg
parseReceiptEvents : List (EventLog -> Maybe a) -> Receipt -> List a
```

Sending a transaction:

```elm
import Web3.Contract.Send as Send
import Web3.Transaction as Tx

type Msg
    = Submit
    | TxMsg D.Value

update msg model =
    case msg of
        Submit ->
            ( { model | tx = Tx.AwaitingSignature }
            , Ports.web3Cmd
                (Send.encode
                    (Send.payableCall
                        { contract = routerAddress
                        , method   = "buy(uint256)"
                        , args     = [ Encode.uint256 minOut ]
                        , value    = weiAmount
                        }
                    )
                )
            )

        TxMsg raw ->
            case D.decodeValue Tx.decoder raw of
                Ok txMsg ->
                    ( { model | tx = Tx.update txMsg model.tx }, Cmd.none )
                Err _ ->
                    ( model, Cmd.none )

viewTx status =
    case status of
        Tx.Idle             -> text ""
        Tx.AwaitingSignature -> text "Sign in your wallet…"
        Tx.Submitted h      -> text ("Pending: " ++ T.txHashToString h)
        Tx.Confirming h n   -> text (String.fromInt n ++ " confirmations")
        Tx.Confirmed _      -> text "Confirmed"
        Tx.Failed err       -> text ("Failed: " ++ err)
        Tx.Rejected         -> text "Rejected"
```

---

### `Web3.Contract.Call`

Read-only contract calls (`eth_call`):

```elm
readCall :
    { contract : Address
    , method   : String
    , args     : List E.Value
    , decoder  : D.Decoder a
    , id       : String
    }
    -> ReadCall a

withBlock : BlockNumber -> ReadCall a -> ReadCall a
withFrom  : Address    -> ReadCall a -> ReadCall a
encode    : ReadCall a -> E.Value
responseDecoder : ReadCall a -> D.Decoder a
```

---

### `Web3.Contract.Send`

Write calls and deployments:

```elm
writeCall   : { contract, method, args } -> WriteCall
payableCall : { contract, method, args, value : BigInt } -> WriteCall
withGasLimit : Int -> WriteCall -> WriteCall
encode       : WriteCall -> E.Value
estimateGas  : WriteCall -> E.Value
deployCall   : { bytecode, args, gasLimit } -> E.Value
encodeRawSend : String -> E.Value
```

---

### `Web3.Contract.Event`

Event subscriptions and log queries:

```elm
watchEvent : EventFilter -> E.Value
getLogs    : GetLogsQuery -> E.Value
decoder    : D.Decoder a -> D.Decoder (EventLog a)
logsDecoder : D.Decoder a -> D.Decoder (List (EventLog a))
```

`EventLog a` carries `data`, `contract`, `topics`, `blockNumber`, `txHash`, and `logIndex`.

---

### `Web3.Multicall`

Batch multiple reads into one `eth_call` using the Multicall3 contract
(`0xcA11bde05977b3631167028862bE2a173976CA11`):

```elm
callSpec : Address -> String -> List E.Value -> CallSpec
batch    : String  -> List CallSpec -> MulticallRequest
encode   : MulticallRequest -> E.Value
responseDecoder : List (D.Decoder a) -> D.Decoder (List (Result String a))
```

---

### `Web3.Sign`

EIP-712 typed data signing and EIP-191 personal signing:

```elm
typedData    : { domain, types, primaryType, message } -> TypedData
encode       : String -> Address -> TypedData -> E.Value
personalSign : String -> Address -> String -> E.Value

type SignState
    = SignIdle
    | SignPending String
    | Signed      String String
    | SignFailed  String String
    | SignRejected String

startSign       : String  -> SignState -> SignState
signUpdate      : SignMsg -> SignState -> SignState
isSignTerminal  : SignState -> Bool
signatureDecoder : D.Decoder String
```

EIP-712 permit example:

```elm
permitRequest : T.Address -> T.Address -> BigInt -> Int -> Sign.TypedData
permitRequest owner spender value nonce =
    Sign.typedData
        { domain =
            { name = Just "MyToken", version = Just "1"
            , chainId = Just 369, verifyingContract = Just tokenAddress
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
```

---

### `Web3.Balance`

Native balance queries with correlation IDs:

```elm
getBalance : Address -> String -> Cmd
encode     : Cmd -> E.Value
decoder    : D.Decoder Msg    -- GotBalance id wei
```

---

### `Web3.Block`

Block queries and polling:

```elm
getBlockNumber          : String -> Cmd
getBlock                : BlockNumber -> String -> Cmd
watchBlockNumber        : String -> Cmd       -- polls every ~4 seconds
getBlockTransactionCount : BlockNumber -> String -> Cmd
encode  : Cmd -> E.Value
decoder : D.Decoder Msg
```

---

### `Web3.Fee`

Gas price and EIP-1559 fee history:

```elm
getGasPrice  : String -> Cmd
getFeeHistory : String -> Int -> Cmd
encode  : Cmd -> E.Value
decoder : D.Decoder Msg
```

---

### `Web3.Query`

Miscellaneous on-chain reads:

```elm
getTxCount   : Address -> String -> Cmd
getStorageAt : Address -> Int -> String -> Cmd
getCode      : Address -> String -> Cmd
getTransaction : TxHash -> String -> Cmd
encode  : Cmd -> E.Value
decoder : D.Decoder Msg
```

---

### `Web3.Units`

Pure-Elm unit conversion, no port needed:

```elm
formatEther : BigInt -> String
parseEther  : String -> Maybe BigInt

formatUnits : Int -> BigInt -> String
parseUnits  : Int -> String -> Maybe BigInt
```

---

### `Web3.Chain`

Chain definitions:

```elm
ethereum, sepolia : Chain
pulsechain, pulsechainTestnet : Chain
bsc, polygon, arbitrum, optimism, base : Chain
avalanche, zksync, fantom, gnosis, linea, scroll : Chain
custom : { chainId, name, rpcUrl, blockExplorer, nativeCurrency } -> Chain

chainId      : Chain -> T.ChainId
name         : Chain -> String
rpcUrl       : Chain -> String
blockExplorer : Chain -> String
```

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

---

### `Web3.BigInt`

Arbitrary-precision integers for `uint256` and `int256` values. Base-10⁷ digit representation, no external dependencies.

```elm
fromInt       : Int    -> BigInt
fromString    : String -> Maybe BigInt
fromIntString : String -> Maybe BigInt
fromHexString : String -> Maybe BigInt   -- 0x-prefixed
toString      : BigInt -> String

add, sub, mul : BigInt -> BigInt -> BigInt
div, mod      : BigInt -> BigInt -> Maybe BigInt
compare       : BigInt -> BigInt -> Order
gt, gte, lt, lte, eq : BigInt -> BigInt -> Bool
zero   : BigInt
isZero : BigInt -> Bool
decoder : D.Decoder BigInt
```

---

### `Web3.Abi.Encode` / `Web3.Abi.Decode`

ABI parameter helpers.

**Encoders:** `address`, `uint256`, `int256`, `bool`, `string`, `bytes`, `bytes32`, `bytesN`, `list`, `tuple2`, `tuple3`

**Decoders:** `address`, `uint256`, `int256`, `bool`, `string`, `bytes32`, `uint8`, `uint16`, `uint32`, `uint64`, `uint128`

**Hex-slot decoders** (for raw ABI hex without a JS ABI library):
`hexSlot`, `uint256Slot`, `addressSlot`, `boolSlot`, `stringSlot`, `listSlot`, `tuple2Hex`, `tuple3Hex`

**Revert reason decoding:**
```elm
decodeRevertReason : String -> Maybe String
```

---

### `Web3.Crypto`

Keccak256 via port:

```elm
keccak256 : String -> String -> Cmd
encode    : Cmd -> E.Value
decoder   : D.Decoder Msg
```

## Code generator

Generates typed Elm modules from Solidity ABI JSON:

```sh
bun codegen/generate.ts \
  out/MyContract.sol/MyContract.json \
  Generated.MyContract \
  src/Generated/MyContract.elm
```

Each ABI function becomes a typed encoder; each event becomes a typed decoder.

## Formal verification

The `proofs/` directory contains Lean 4 proofs and TLA+ specifications.

**Lean 4 (all proofs close without `sorry`):**

- `Address.lean` — soundness, injectivity, and roundtrip for `address`/`addressToString`
- `TxHash.lean` — same three properties for `txHash`
- `HexString.lean` — same three properties for `hexString`
- `WalletCodec.lean` — encode/decode roundtrip, injectivity, partial inverse, and tag separation for `WalletCmd`
- `BigInt.lean` — nine arithmetic theorems (normalize, add, multiply, shift, subtract, parse)
- `AbiCodec.lean` — bytes32 and address codec soundness, completeness, and roundtrip
- `RevertReason.lean` — six theorems covering hex parsing, UTF-8 roundtrip, and selector/length guards

**TLA+ model-checked:**

- `WalletSpec.tla` — wallet state invariants, no-deadlock liveness
- `TransactionSpec.tla` — terminal states stay terminal, confirmation count is monotonic

See `proofs/COVERAGE.md` for the full coverage map. All proofs use only core Lean 4 — no Mathlib.

## Prior art

- `cmditch/elm-ethereum` — web3.js era, Task-based, no longer maintained
- `purescript-web3` — similar concept in PureScript

## License

MIT © Intrepid Development
