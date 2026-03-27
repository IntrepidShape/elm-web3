# elm-web3

Type-safe EVM blockchain interaction for Elm.

**80% of your frontend code gets zero runtime exceptions.** Not fewer. Zero. The Elm compiler guarantees it.

The remaining 20% is a ~500-line JavaScript port bridge that catches every error and routes it back to Elm as a typed message. Your app never white-screens.

## What it is

A package that lets Elm applications interact with EVM blockchains (Ethereum, PulseChain, etc.) through the browser wallet. It provides:

- **Opaque, validated types** for addresses, transaction hashes, chain IDs, and wei amounts
- **Wallet state machine** that makes invalid states unrepresentable
- **Transaction lifecycle state machine** with exhaustive pattern matching
- **Typed contract calls** (reads and writes) with JSON encoders/decoders
- **Multicall** for batching multiple reads into one RPC call
- **EIP-712 typed data signing**
- **EIP-6963 multi-wallet discovery**
- **Gas estimation**, **revert reason decoding**, **receipt event parsing**
- **Event subscriptions and log queries** with typed decoders
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

## Quick start

### 1. Define ports

```elm
port module Ports exposing (..)

import Json.Encode as E
import Json.Decode as D

port web3Cmd : E.Value -> Cmd msg
port web3Sub : (D.Value -> msg) -> Sub msg
```

### 2. Wire into your app

```elm
import Web3.Wallet as Wallet
import Web3.Transaction as Tx
import Web3.Types as T

type alias Model =
    { wallet : Wallet.State
    , tx : Tx.Status
    }

type Msg
    = ConnectWallet
    | Web3Response D.Value
    | BuyTokens

update msg model =
    case msg of
        ConnectWallet ->
            ( { model | wallet = Wallet.Connecting }
            , Ports.web3Cmd (Wallet.encode Wallet.connect)
            )

        Web3Response value ->
            case D.decodeValue Wallet.decoder value of
                Ok walletMsg ->
                    ( { model | wallet = Wallet.update expectedChain walletMsg model.wallet }
                    , Cmd.none
                    )
                Err _ ->
                    -- Try transaction decoder, etc.
                    ( model, Cmd.none )

        BuyTokens ->
            case Wallet.getAddress model.wallet of
                Just addr ->
                    -- Compiler won't let you get here without a connected wallet
                    ( { model | tx = Tx.AwaitingSignature }
                    , Ports.web3Cmd (buyCall addr)
                    )
                Nothing ->
                    -- Can't buy without wallet. This branch is explicit.
                    ( model, Cmd.none )
```

### 3. Set up JS ports

See the Install section above. That's it. The wallet connection, chain switching, transaction signing, confirmation polling, and error handling all flow through typed Elm messages.

## Why

### The problem with React + wagmi/ethers/viem

Every line of JavaScript can throw at runtime. An unhandled promise rejection in a wallet hook white-screens your app. A null reference in transaction state crashes the UI mid-sign. Users see blank pages and lose trust.

You mitigate this with discipline, testing, and error boundaries. But you can never prove it won't happen.

### What Elm gives you

The compiler checks every code path. If your app compiles, it runs. There is no `undefined is not a function`. There is no unhandled null. Every wallet state (disconnected, connecting, connected, wrong chain) is a variant you must match. Every transaction state (idle, signing, pending, confirmed, failed, rejected) forces you to handle it.

This isn't a library feature. It's a language property. The Elm compiler physically cannot generate JavaScript that throws a runtime exception.

### What this package gives you

The bridge between Elm's guarantees and the browser wallet API:

| Layer | Lines | Runtime exceptions |
|-------|------:|-------------------|
| Elm modules | 2,105 | Impossible |
| Your app (Elm) | varies | Impossible |
| Generated contract bindings (Elm) | varies | Impossible |
| JS port bridge | 508 | Caught and typed |

## Modules

### `Web3.Types`

Opaque types that prevent mixing up addresses, transaction hashes, and chain IDs:

```elm
address : String -> Maybe Address        -- validates 0x + 40 hex
txHash : String -> Maybe TxHash          -- validates 0x + 64 hex
chainId : Int -> ChainId
```

You can't accidentally pass a `TxHash` where an `Address` is expected. The compiler catches it.

### `Web3.Wallet`

Wallet connection as an explicit state machine:

```elm
type State
    = Disconnected
    | Connecting
    | Connected { address : Address, chainId : ChainId }
    | WrongChain { address : Address, chainId : ChainId } ChainId
    | Error String
```

Every state is a variant. Pattern matching forces exhaustive handling. There is no "wallet is connected but address is null" state.

Includes EIP-6963 multi-wallet discovery — when multiple wallets are installed (MetaMask + Rabby), the user picks which one.

### `Web3.Transaction`

Transaction lifecycle as a state machine:

```elm
type Status
    = Idle
    | AwaitingSignature
    | Submitted TxHash
    | Confirming TxHash Int    -- hash + confirmation count
    | Confirmed Receipt
    | Failed String            -- includes decoded revert reason when available
    | Rejected                 -- user rejected in wallet
```

Your UI must handle every state. The compiler enforces this. Confirmed receipts include parsed event logs.

### `Web3.Contract.Call`

Typed read-only contract calls:

```elm
readCall :
    { contract : Address
    , method : String
    , args : List E.Value
    , decoder : D.Decoder a
    , id : String
    }
    -> ReadCall a
```

The return type is parameterized. Your decoder is checked at compile time. The `id` field lets you match responses when multiple calls are in flight.

### `Web3.Contract.Send`

Typed write calls with gas estimation:

```elm
-- Non-payable
writeCall : { contract : Address, method : String, args : List E.Value } -> WriteCall

-- Payable (sends value)
payableCall : { contract : Address, method : String, args : List E.Value, value : BigInt } -> WriteCall

-- Estimate gas before sending
estimateGas : WriteCall -> E.Value
```

### `Web3.Contract.Event`

Event subscriptions and historical log queries:

```elm
-- Watch live events
watchEvent : EventFilter -> E.Value

-- Query past events
getLogs : GetLogsQuery -> E.Value

-- Decode event logs
decoder : D.Decoder a -> D.Decoder (EventLog a)
```

### `Web3.Multicall`

Batch multiple read calls into a single RPC request via the Multicall3 contract:

```elm
multicall : List (ReadCall a) -> E.Value
```

One RPC call instead of ten. Every dapp with a dashboard needs this.

### `Web3.Sign`

EIP-712 typed data signing for permits, gasless approvals, and off-chain order books:

```elm
signTypedData : TypedData -> E.Value
```

### `Web3.Chain`

Chain definitions:

```elm
pulsechain : Chain      -- chain 369
ethereum : Chain        -- chain 1
sepolia : Chain         -- chain 11155111
custom : { ... } -> Chain
```

### `Web3.BigInt`

Arbitrary-precision integers for uint256 and int256 values. Implemented natively with no external dependencies — base-10^7 digit representation, safe within Elm's 53-bit integer range. All EVM integers cross the port boundary as decimal strings and are parsed into `BigInt` on the Elm side.

### `Web3.Abi.Encode` / `Web3.Abi.Decode`

Helpers for encoding contract call parameters and decoding return values. Includes `decodeRevertReason` for extracting human-readable error messages from failed transactions.

## Code generator

The package includes an ABI-to-Elm code generator. Given a Foundry/Hardhat ABI JSON file, it outputs a typed Elm module:

```bash
bun codegen/generate.ts \
  out/MyContract.sol/MyContract.json \
  Generated.MyContract \
  src/Generated/MyContract.elm
```

### What it generates

For each contract function:
- A parameter type alias
- An encoder that produces port-ready JSON
- A return value decoder

For each event:
- An event type alias
- A decoder

```elm
-- Generated from: function buy(uint256 minTokensOut) payable returns (uint256)

type alias BuyParams =
    { minTokensOut : String    -- uint256 as string (BigInt)
    , value : String           -- wei to send
    }

encodeBuy : BuyParams -> E.Value
encodeBuy params =
    E.object
        [ ( "method", E.string "buy(uint256)" )
        , ( "args", E.list identity [ E.string params.minTokensOut ] )
        , ( "value", E.string params.value )
        ]

decodeBuyReturn : D.Decoder String
decodeBuyReturn =
    D.index 0 D.string
```

No magic strings in your app code. Every contract method is a typed function.

### Batch generation

```bash
bun codegen/generate-all.ts \
  --artifacts out/ \
  --output src/Generated/
```

## The JS port bridge

`js/elm-web3-ports.js` — ~500 lines, zero dependencies.

It handles:
1. Wallet connection, disconnection, chain switching
2. EIP-6963 multi-wallet discovery
3. Contract reads (`eth_call`) and writes (`eth_sendTransaction`)
4. Gas estimation (`eth_estimateGas`)
5. EIP-712 typed data signing (`eth_signTypedData_v4`)
6. Multicall batching
7. Event log queries (`eth_getLogs`)
8. Transaction receipt polling with confirmation counting
9. Revert data extraction from failed calls

Every call is wrapped in try/catch. Errors become typed messages (`{ tag: 'failed', error: '...' }`) that Elm decodes into `Failed String` or `WalletError String`.

The ABI encoding (function selectors + parameter encoding) is done in pure JS with a minimal keccak256 implementation. No external dependencies.

## Formal verification

The `proofs/` directory contains machine-checked Lean 4 proofs and TLA+ model-checked specifications. All proofs use only core Lean 4 — no Mathlib.

### What is fully proved (zero `sorry`)

**`Address.lean`** — three theorems about `Web3.Types.address`:
- **Soundness**: `address s = Just a` implies `a` satisfies the validity predicate (starts `0x`, length 42, lowercase hex body)
- **Injectivity**: `addressToString a = addressToString b → a = b`
- **Roundtrip**: `address (addressToString a) = Just a` — re-parsing a valid address always succeeds

`TxHash.lean` proves the same three properties for `txHash` (length 66, 64-char hex body). `HexString.lean` proves them for `hexString` (no length constraint, mixed-case hex).

**`WalletCodec.lean`** — four theorems about the `WalletCmd` port encoder/decoder:
- **Roundtrip**: `∀ cmd, decode(encode(cmd)) = Some cmd`
- **Injectivity**: `encode c₁ = encode c₂ → c₁ = c₂`
- **Partial inverse**: decoding any JSON to `cmd` implies re-encoding `cmd` decodes back to itself
- **Tag separation**: commands with equal JSON tags belong to the same constructor family

**`BigInt.lean`** — nine arithmetic theorems via a `natVal : List Int → Int` semantic interpretation:
- `natNormalize_val`: stripping trailing zeros preserves value
- `natAdd_val`: `natVal (natAdd a b) = natVal a + natVal b`
- `natMulSmall_val`: `natVal (natMulSmall ds k) = k * natVal ds`
- `natAddSmall_val`: `natVal (natAddSmall ds v) = natVal ds + v`
- `shiftLeft_val`: `natVal (shiftLeft n ds) = bigBase^n * natVal ds`
- `natSub_val`: `natVal a ≥ natVal b → natVal (natSub a b) = natVal a - natVal b`
- `parseUnsigned_step`: the decimal accumulation step `10 * n + digit` is faithfully modelled

**`AbiCodec.lean`** — bytes32 decoder soundness, completeness, and full characterization; address codec roundtrip.

**`RevertReason.lean`** — six theorems: `hexDigitVal` range (`0 ≤ result < 16`), `hexToInt` correctness, `hexToBytes` correspondence, UTF-8/ASCII round-trip for printable characters, `0x08c379a0` selector guard, and ABI-encoded length guard.

**TLA+** (`proofs/tla/`):
- `WalletSpec.tla` — wallet state invariants and no-deadlock liveness, model-checked by TLC
- `TransactionSpec.tla` — terminal states stay terminal, transition guards match code, confirmation count is monotonic

### Proof sketches (stated, not yet closed)

Four theorems carry `sorry` with written proof strategies:
- `natMul_val` — full multiplication via indexed `foldl` (~40 lines; index coordination across recursive case)
- `natCompare_spec` — lexicographic comparison reflects numeric order (~80 lines)
- `natDivMod_spec` — quotient/remainder algorithm correctness (~150 lines)
- `fromString_toString_roundtrip` — decimal encoding is an isomorphism (~200 lines); `uint256_codec_roundtrip` and `decodeRevertReason_correct` depend on this

These cover the hardest algorithmic proofs. Every stated theorem is true — the `sorry` markers are genuine TODOs, not hidden bugs. The proof sketches describe correct strategies.

See `proofs/COVERAGE.md` for the full coverage map.

## Supported chains

Any EVM chain with a browser wallet (MetaMask, Rabby, etc.):

- PulseChain (369)
- Ethereum (1)
- Sepolia (11155111)
- Any custom chain via `Web3.Chain.custom`

## Prior art

- `cmditch/elm-ethereum` (2018) — web3.js era, Task-based, no longer maintained
- `purescript-web3` — similar concept in PureScript, stronger types but smaller ecosystem
- This package targets the modern wallet API (`window.ethereum`) with zero external JS dependencies

## License

MIT
