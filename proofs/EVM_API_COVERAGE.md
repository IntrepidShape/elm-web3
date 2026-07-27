# EVM API coverage — what elm-web3 models, and what it deliberately doesn't

Honest answer to "have we exhaustively modeled the EVM API?": **no — and most
of the gaps are deliberate.** This document is the map: every EIP / JSON-RPC
method / provider event, its status in elm-web3, and the reasoning.

Surface audited 2026-07-02 against `src/` and `js/elm-web3-ports.ts`;
**re-checked 2026-07-27 against 2.0.0** (`src/`: 21 modules, all exposed;
`js/elm-web3-ports.ts`: 35 command handlers plus a `default` arm). The wire-tag
counts that used to be quoted here by hand are gone — see
[§6](#6-wire-protocol-integrity), which now defers to a checker instead.

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
| `eth_subscribe("newHeads")` | ✅ | `watchBlockNumber` upgraded (1.4.1): WS newHeads push with automatic 4s-poll fallback; identical message shape, zero Elm changes |
| `eth_subscribe("newPendingTransactions")` | ❌ | **skip** — mempool streaming is trading-bot territory, not dapp UI |
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

### What "verified 1:1" meant, and what it did not

This section used to assert that the Elm↔port contract was "verified 1:1, no
orphans on either side". **That claim was about tag names only.** What was
actually checked, once, by hand, in July 2026: for every `E.string "<tag>"` in
`src/`, a `case '<tag>'` existed in the port switch, and vice versa.

What it never checked, and was never qualified as not checking:

- **Field names.** `{ tag: 'x', rawTx }` on one side and `cmd.raw` on the
  other are 1:1 by tag and broken in practice. The hand-maintained
  `js/elm-web3-ports.d.ts` had drifted from the runtime shape in several
  places (its own header conceded that drift "must be caught in code review";
  it wasn't). Those are tracked and being fixed in the Elm↔JS boundary work —
  read their current status from the checker below, not from this paragraph.
- **Field types and optionality.** A `Maybe` on the Elm side vs a required
  property on the TS side is invisible to a tag comparison.
- **Tag collisions.** Two Elm modules can emit the *same* tag with
  incompatible payloads and still satisfy a set-difference check. One does:
  `Subscription.open` and `Contract.Event.watchEvent` both emit `watchEvent`.
- **Whether it stays true.** A one-off manual comparison decays the moment
  either side changes, which is exactly how it decayed.

### What checks it now

`scripts/check-port-parity.ts` — a CI script that reads both sides
mechanically. It has a `--self-test` mode that injects a drift per failure
class and must be seen to reject each one, because a checker nobody has
watched fail is not evidence.

Be precise about how far it reaches, because this section's whole problem was
imprecision. **Gating** (a difference fails CI):

- `CMD-1` / `CMD-2` — every Elm command tag has a shim handler and vice versa.
- `CMD-3` — no command tag is emitted from two Elm sites with **different
  payload field sets**. This is field-level, and it is what catches the
  `watchEvent` collision.
- `SUB-1` / `SUB-2` — every tag the shim sends is decoded or documented by
  some Elm module, and every tag an Elm decoder matches is actually sent.
- `DTS` — `js/elm-web3-ports.d.ts` lists exactly the tags the shim handles and
  emits.

**Advisory** (printed under `--verbose`, deliberately does *not* gate): the
field-by-field diff between an Elm payload and what the shim reads. Those
heuristics are usually right and not yet trusted enough to fail a build, so
until they are, **field-name agreement between Elm and the shim is checked by
eye on those tags, not by a machine.** That is the honest current state.

**Counts and mismatches are deliberately not restated here** — they are
whatever the checker prints, and quoting them by hand is the habit that
produced the false claim above. Run:

```
bun run scripts/check-port-parity.ts --verbose
```

For the record, on 2026-07-27 it reported 35 Elm command tags against 35 shim
handlers, 42 shim response tags against 36 Elm receive branches, and three
open mismatches: the `watchEvent` tag collision above, plus `callResult` and
`unknownCmd`, which the shim sends and no Elm module decodes or documents.
The library-level decoder gap is genuine but bounded: several response tags
(`gasEstimate`, `logs`, `subscribed`, …) are *documented app-dispatch* tags
that an app matches by hand, which is also why there is no single total
inbound decoder — see the design note below.

### Port-layer behaviour

Exception containment and the error-tag surface are audited in
`JS_PORT_PROOF.md`, re-done 2026-07-27 against the TypeScript bridge (the
previous audit described a 509-line JavaScript file that no longer exists).
F1–F5 and F8 are fixed; F6 is only partly fixed; **F7's "resolved" verdict was
false and has been retracted** — there is no context field and failures are
not unified on one tag. Open findings F7 and F9–F13 are listed there.

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

1. EIP-5792 batched calls (watch adoption before building; activation
   criterion: two major wallets shipping `wallet_sendCalls`)
