# EVM API coverage — what elm-web3 models, and what it deliberately doesn't

Honest answer to "have we exhaustively modeled the EVM API?": **no — and most
of the gaps are deliberate.** This document is the map: every EIP / JSON-RPC
method / provider event, its status in elm-web3 v1.2.x, and the reasoning.
Audited 2026-07-02 against `src/` (24 modules), `js/elm-web3-ports.ts`
(31 command handlers), and the Elm↔port wire tags (31 outbound / 30 inbound —
verified 1:1 against the port's switch).

Legend: ✅ covered · 🟡 partial/via-port-only · ❌ not covered (with verdict:
**gap** = worth adding, **skip** = deliberately out of scope).

---

## 1. Wallet / provider standards (EIPs)

| Standard | What | Status | Where / verdict |
|---|---|---|---|
| EIP-1193 | provider `request` + events | ✅ | port bridges `request`; events below |
| EIP-1193 `connect` / `disconnect` events | | ✅ | `Wallet.Msg` `WalletConnected`/`WalletDisconnected` |
| EIP-1193 `chainChanged` | | ✅ | `ChainChanged` (incl. WrongChain recovery) |
| EIP-1193 `accountsChanged` | | ✅ | `AccountChanged` |
| EIP-1193 `message` event | provider push messages | ❌ | **skip** — WS `eth_subscription` handled separately |
| EIP-6963 | multi-wallet discovery | ✅ | `WalletsDiscovered` / `selectWallet` |
| EIP-3085 | `wallet_addEthereumChain` | ✅ | `Wallet.addChain` |
| EIP-3326 | `wallet_switchEthereumChain` | ✅ | `Wallet.switchChain` + `SwitchChainOk` |
| EIP-747 | `wallet_watchAsset` | ✅ | `Wallet.watchAsset` |
| EIP-2255 | `wallet_requestPermissions` / `getPermissions` | ✅ | `Wallet.requestPermissions`/`getPermissions`; port also calls `wallet_revokePermissions` on disconnect |
| EIP-191 | `personal_sign` | ✅ | `Sign.personalSign` |
| EIP-712 | `eth_signTypedData_v4` | ✅ | `Sign.encode`/`typedData` (v4 only — v1/v3 are obsolete; **skip**) |
| EIP-5792 | `wallet_sendCalls` (batched txs) | ❌ | **gap (future)** — emerging standard, watch adoption |
| EIP-4844 | blob-tx fields (`maxFeePerBlobGas`, …) | ❌ | **skip** — dapp-irrelevant (rollup infra), and n/a on PulseChain |
| EIP-7702 | account delegation txs | ❌ | **skip for now** — too new, wallet support sparse |
| ENS | name resolution | ❌ | **skip** — PulseChain-first library; add if Ethereum-mainnet demand appears |

## 2. JSON-RPC read surface

| Method | Status | Elm module |
|---|---|---|
| `eth_call` | ✅ | `Contract.Call` (+ `readCallRaw`) |
| `eth_estimateGas` | ✅ | `Contract.Send` (estimate step) |
| `eth_getBalance` | ✅ | `Balance` |
| `eth_blockNumber` | ✅ | `Block.getBlockNumber` / `watchBlockNumber` (4s poll) |
| `eth_getBlockByNumber` / `ByHash` | ✅ | `Block.getBlock` |
| `eth_getBlockTransactionCountByNumber` | ✅ | `Block` |
| `eth_getBlockTransactionCountByHash` | ❌ | **skip** — ByNumber covers the use case |
| `eth_getCode` | ✅ | `Query.getCode` |
| `eth_getStorageAt` | ✅ | `Query.getStorageAt` |
| `eth_getTransactionCount` | ✅ | `Query` (nonce reads) |
| `eth_getTransactionByHash` | ✅ | `Query.getTransaction` |
| `eth_getTransactionReceipt` | ✅ | `Transaction.RequestReceipt` + port `pollReceipt` |
| `eth_getLogs` | ✅ | `Contract.Event.getLogs` |
| `eth_gasPrice` | ✅ | `Fee.getGasPrice` |
| `eth_feeHistory` | ✅ | `Fee.getFeeHistory` |
| `eth_maxPriorityFeePerGas` | ✅ | `Fee.getMaxPriorityFee` / `maxPriorityFeeDecoder` (1.3.0; standalone pair — extending `Fee.Msg` would be MAJOR) |
| `eth_chainId` / `eth_accounts` | ✅ | used internally by the port |
| `eth_getProof` (EIP-1186) | ❌ | **skip** — light-client/bridge tooling, not dapp UI |
| `eth_createAccessList` (EIP-2930) | ❌ | **skip** — gas micro-optimization, wallet's job |
| `eth_syncing` / `net_version` / `web3_clientVersion` | ❌ | **skip** — node introspection |
| `eth_getUncle*` / `eth_coinbase` / `eth_mining` / `eth_hashrate` | ❌ | **skip** — obsolete (post-merge / node-operator) |
| `eth_getTransactionByBlock*AndIndex` | ❌ | **skip** — indexer territory |

## 3. Write / signing surface

| Method | Status | Notes |
|---|---|---|
| `eth_sendTransaction` | ✅ | `Contract.Send` `writeCall`/`payableCall` (+`Raw` variants); `deploy` = sendTransaction without `to` |
| `eth_sendRawTransaction` | ✅ | `sendRawTransaction` port command |
| `eth_signTransaction` (sign, don't broadcast) | ❌ | **skip** — wallets barely support it; raw-tx flows use sendRaw |
| `personal_ecRecover` | ✅ | `Sign.verify` / `recoveredDecoder` (1.3.0) |
| Fee fields on writes | 🟡 | `WriteCall` carries `value` + `gasLimit` only — **no `maxFeePerGas`/`maxPriorityFeePerGas`/`nonce` overrides.** Deliberate: the wallet owns fee choice (and overrides dapp values anyway). Documented posture, revisit only on real demand |

## 4. Subscriptions / streaming

| Kind | Status | Notes |
|---|---|---|
| `eth_subscribe("logs")` | ✅ | `Subscription` (WS, shared socket, re-arm on reconnect; falls back to 4s `eth_getLogs` poll) |
| `eth_subscribe("newHeads")` | 🟡 | block numbers stream via `watchBlockNumber` **HTTP poll (4s)**, not a WS newHeads sub — same UX, higher latency. **gap (nice-to-have)** |
| `eth_subscribe("newPendingTransactions")` | ❌ | **skip** — mempool streaming is bot territory (swapnsync-class), not dapp UI |
| Polling filters (`eth_newFilter`/`getFilterChanges`/`uninstallFilter`) | ❌ | **skip** — superseded by getLogs + WS logs sub |

## 5. Non-RPC building blocks

| Thing | Status | Notes |
|---|---|---|
| ABI encode/decode (word level) | ✅ | `Abi.Encode`/`Abi.Decode` — Lean-proved codecs + fuzz |
| Calldata head/tail layout (pure Elm) | ✅ | `Abi.Calldata` — fuzz-verified offsets; selectors baked at codegen (no runtime keccak, by design) |
| keccak256 | 🟡 | `Crypto.keccak256` goes **through the JS port** — not pure Elm. Fine for hashing UX strings; calldata never needs it |
| BigInt (uint256 arithmetic) | ✅ | pure Elm, Lean + fuzz coverage |
| Units (wei/gwei/ether, arbitrary decimals) | ✅ | fuzz-verified exact |
| Multicall3 aggregate | ✅ | `Multicall` (fuzz-verified codec) |
| Revert-reason decoding (`Error(string)` selector) | ✅ | `Abi.Decode.decodeRevertReason` (Lean partial + fuzz) |
| Custom error decoding (non-`Error(string)` selectors) | ✅ | `Abi.Decode.decodeCustomError` (1.4.0) — baked selector fragments, disjoint-domain composition with `decodeRevertReason` |

## 6. Wire-protocol integrity

- All **31** Elm outbound command tags have exactly one handler in the port
  switch — verified 1:1, no orphans on either side.
- Port inbound tags without a library-level decoder (`callResult`,
  `gasEstimate`, `logs`, `subscribed`, `unknownCmd`) are *documented
  app-dispatch* tags — the app matches on `tag` and applies the module's
  decoder. Not a gap, but the reason there is no single total inbound decoder.
- Port-layer behaviors (exception containment, error-tag consistency) are
  covered by `JS_PORT_PROOF.md`, including its open findings (F1–F7).
  F8 (`watchBlockNumber` interval leak) was fixed in 1.3.0: pollers are
  keyed by id, replaced on re-issue, and `Block.unwatchBlockNumber` clears
  them. The F1–F7 re-audit against the current port remains open.

---

## Design note — total inbound decoder (`Web3.Incoming`), decided 2026-07-02

Today each module ships its own decoder and apps dispatch on the wire `tag`
by hand. The considered improvement: one exposed
`Web3.Incoming.decoder : Decoder Incoming` with a custom-type arm per inbound
tag, so an app writes a single `case` and the compiler enforces totality.

**Decision: build it as the headline of the next MINOR that touches the wire
(not standalone).** Rationale: (a) it must include every tag, so shipping it
between wire-changing releases immediately deprecates itself; (b) it is
purely additive (existing per-module decoders remain); (c) the union has ~35
arms — mechanical, but worth generating from the port's tag inventory to keep
the 1:1 wire-integrity property checkable. Sketch:
`type Incoming = WalletMsg Wallet.Msg | TxMsg Tx.Msg | FeeGasPrice String BigInt | … | Unknown String`
with `Unknown` carrying unrecognised tags (never a decode failure — forward
compatibility).

## Verdict

The library covers the **entire dapp-relevant EVM surface**: EIP-1193 +
discovery + chain/asset/permission management, both signing standards, all
routine reads, both write paths, log streaming, and the full ABI/BigInt/Units
stack with formal backing. It is **not** an exhaustive JSON-RPC binding — by
design. The ranked genuine gaps:

1. WS `newHeads` for `watchBlockNumber` (replace 4s poll)
2. Port F1–F7 re-audit against the current bridge
3. EIP-5792 batched calls (watch adoption before building; activation
   criterion: two major wallets shipping `wallet_sendCalls`)
