/**
 * TypeScript declaration file for `elm-web3-ports.js`.
 *
 * Authored as a first-class types layer: every Cmd the Elm side sends and
 * every Sub message the JS side emits is typed exhaustively as a discriminated
 * union. Branded `Hex` / `Address` / `TxHash` types prevent mixing semantics.
 * Strict Pocock-style — `noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`,
 * `strictFunctionTypes` all hold against this file.
 *
 * Consumers get:
 *   - Editor autocomplete on every `app.ports.web3Cmd.send({ tag: ... })` call
 *   - Exhaustiveness checking when destructuring `app.ports.web3Sub.send({ tag: ... })`
 *   - Compile-time refusal of `cmd.value` typos and similar
 *   - Type-checked branded values: an `Address` can't accidentally be passed
 *     to a function expecting a `TxHash`
 *
 * The runtime source-of-truth is `elm-web3-ports.ts` (`elm-web3-ports.js` is
 * its bundled artifact). This file is the type-level contract, and it is NOT
 * generated: `tsc --declaration` can only emit what the implementation's own
 * types say, and there the sub channel is a single open record
 * (`{ tag: string; [k: string]: unknown }`) -- generating would delete every
 * payload documented below. Instead the tag sets are machine-checked against
 * the implementation on every CI run by
 * `scripts/check-port-parity.ts` (codes DTS-CMD-* / DTS-SUB-*), so a renamed
 * or added tag fails the build rather than waiting for a code review. Field
 * names within a tag are still hand-maintained.
 *
 * Distributed alongside `elm-web3-ports.js` so consumers importing the module
 * via `import { setupPorts } from './elm-web3-ports.js'` get types for free.
 */

// ─────────────────────────────────────────────────────────────────────
// Branded primitives
// ─────────────────────────────────────────────────────────────────────

/** A 0x-prefixed lowercase hex string. */
export type Hex = `0x${string}`

/** A 20-byte EVM address. Branded — distinct from Hex and TxHash. */
export type Address = Hex & { readonly __brand: 'Address' }

/** A 32-byte transaction hash. Branded — distinct from Hex and Address. */
export type TxHash = Hex & { readonly __brand: 'TxHash' }

/** A 32-byte storage slot or topic. */
export type Bytes32 = Hex & { readonly __brand: 'Bytes32' }

/** Block reference: `latest` | `earliest` | `pending` | block number. */
export type BlockTag = number | 'latest' | 'earliest' | 'pending'

// ─────────────────────────────────────────────────────────────────────
// Elm app shape (subset we touch)
// ─────────────────────────────────────────────────────────────────────

/** The Elm app handle returned by `Elm.Main.init`. We only access ports. */
export interface ElmApp {
  readonly ports: {
    readonly web3Cmd: {
      subscribe(handler: (cmd: Web3Cmd) => void): void
      send(cmd: Web3Cmd): void
    }
    readonly web3Sub: {
      send(sub: Web3Sub): void
    }
    /** Optional clipboard port; consumers may not declare it. */
    readonly copyToClipboard?: {
      subscribe(handler: (value: string) => void): void
    }
  }
}

// ─────────────────────────────────────────────────────────────────────
// Cmd surface (Elm → JS)
// ─────────────────────────────────────────────────────────────────────

/** Pre-built ABI calldata. When present it is sent verbatim and `method` /
 *  `args` are ignored -- the Elm raw builders (`Contract.Call.readCallRaw`,
 *  `Contract.Send.writeCallRaw`, `payableCallRaw`) always take this path. */
type Calldata = { readonly data: Hex; readonly method?: string; readonly args?: readonly unknown[] }
/** Signature + arguments, encoded by the shim's own ABI encoder. */
type Signature = { readonly data?: undefined; readonly method: string; readonly args: readonly unknown[] }
type CallPayload = Calldata | Signature

/** Every command the Elm side can emit. Discriminated by `tag`. */
export type Web3Cmd =
  // Wallet lifecycle
  | { readonly tag: 'connect'; readonly requestId: number }
  | { readonly tag: 'disconnect' }
  | { readonly tag: 'switchChain'; readonly chainId: number }
  | { readonly tag: 'selectWallet'; readonly rdns: string; readonly requestId: number }
  | { readonly tag: 'addChain'; readonly chainId: number; readonly chainName: string; readonly rpcUrls: readonly string[]; readonly blockExplorerUrls: readonly string[]; readonly nativeCurrency: { readonly name: string; readonly symbol: string; readonly decimals: number } }
  | { readonly tag: 'watchAsset'; readonly address: Address; readonly symbol: string; readonly decimals: number; readonly image: string }
  | { readonly tag: 'requestPermissions' }
  | { readonly tag: 'getPermissions' }

  // Reads
  | ({ readonly tag: 'call'; readonly id: string; readonly contract: Address; readonly from?: Address; readonly block: BlockTag } & CallPayload)
  | { readonly tag: 'multicall'; readonly id: string; readonly calls: ReadonlyArray<{ readonly contract: Address; readonly method: string; readonly args: readonly unknown[] }> }
  | { readonly tag: 'getBalance'; readonly id: string; readonly address: Address; readonly block?: BlockTag }
  | { readonly tag: 'getStorageAt'; readonly id: string; readonly contract: Address; readonly slot: Bytes32; readonly block?: BlockTag }
  | { readonly tag: 'getCode'; readonly id: string; readonly contract: Address; readonly block?: BlockTag }
  | { readonly tag: 'getTransactionCount'; readonly id: string; readonly address: Address; readonly block?: BlockTag }
  | { readonly tag: 'getGasPrice'; readonly id: string }
  | { readonly tag: 'getMaxPriorityFee'; readonly id: string }
  // `newestBlock` is pinned to 'latest' and reward percentiles to [] by the
  // shim; only `blockCount` crosses the boundary.
  | { readonly tag: 'getFeeHistory'; readonly id: string; readonly blockCount: number }
  | { readonly tag: 'getBlockNumber'; readonly id: string }
  | { readonly tag: 'getBlock'; readonly id: string; readonly block: BlockTag }
  | { readonly tag: 'getBlockTransactionCount'; readonly id: string; readonly block: BlockTag }
  | { readonly tag: 'getTransaction'; readonly id: string; readonly hash: TxHash }
  | { readonly tag: 'getTransactionReceipt'; readonly id: string; readonly hash: TxHash }
  | { readonly tag: 'getLogs'; readonly contract: Address; readonly fromBlock: BlockTag; readonly toBlock: BlockTag; readonly topics?: ReadonlyArray<Hex | null> }

  // Writes
  | ({ readonly tag: 'estimateGas'; readonly contract: Address; readonly from?: Address; readonly value?: string } & CallPayload)
  | ({ readonly tag: 'send'; readonly contract: Address; readonly from?: Address; readonly value?: string; readonly gasLimit?: number; readonly skipSimulate?: boolean } & CallPayload)
  | { readonly tag: 'sendRawTransaction'; readonly rawTx: Hex }
  | { readonly tag: 'deploy'; readonly bytecode: Hex; readonly args?: readonly string[]; readonly value?: string; readonly gasLimit?: number }

  // Signing
  | { readonly tag: 'personalSign'; readonly id: string; readonly from: Address; readonly message: string }
  | { readonly tag: 'signTypedData'; readonly id: string; readonly from: Address; readonly data: unknown }
  | { readonly tag: 'ecRecover'; readonly id: string; readonly message: string; readonly signature: Hex }

  // Misc
  | { readonly tag: 'keccak256'; readonly id: string; readonly message: string }
  // Event subscriptions. Prefer WS (eth_subscribe) when wsUrls/rpcUrls are
  // configured; fall back to a 4s eth_getLogs poll if every WS endpoint
  // fails to handshake. Replies via `eventLog` + `subscribed` Subs.
  //
  // NOTE: `Web3.Contract.Event.watchEvent` emits this same tag with a
  // DIFFERENT payload (`{ contract, event, topics }` -- no `id`, and the
  // address under a different key). The shim reads the shape below; the
  // other shape subscribes with `address: undefined`, i.e. every log on
  // chain. Use `Web3.Subscription.open` until that is reconciled.
  | { readonly tag: 'watchEvent'; readonly id: string; readonly address: Address | null; readonly topics?: ReadonlyArray<Hex | null> }
  | { readonly tag: 'unwatchEvent'; readonly id: string }
  | { readonly tag: 'watchBlockNumber'; readonly id: string }
  | { readonly tag: 'unwatchBlockNumber'; readonly id: string }

// ─────────────────────────────────────────────────────────────────────
// Sub surface (JS → Elm)
// ─────────────────────────────────────────────────────────────────────

/** A log as it appears inside a receipt (`confirmed` / `receiptResult`). */
export interface ReceiptLogJson {
  readonly address: Address
  readonly topics: readonly Hex[]
  readonly data: Hex
  readonly blockNumber: number
  readonly logIndex: number
}

/** A log delivered by a live subscription (`eventLog`). */
export interface EventLogJson {
  readonly address: Address
  readonly topics: readonly Hex[]
  readonly data: Hex
  readonly blockNumber: number
  readonly logIndex: number
  /** `false` on canonical logs, `true` when a chain reorg invalidates a
   *  previously-emitted log. The polling fallback always emits `false`. */
  readonly removed: boolean
  /** Transaction hash that produced this log. */
  readonly transactionHash: TxHash
}

/** A log from a batch `getLogs` query. Note `contract` / `txHash`: this
 *  shape differs from `EventLogJson` on purpose -- it mirrors the field
 *  names `Web3.Contract.Event.logDecoder` expects. */
export interface QueriedLogJson {
  readonly contract: Address
  readonly data: Hex
  readonly topics: readonly Hex[]
  readonly blockNumber: number
  readonly txHash: TxHash
  readonly logIndex: number
}

/** Status transitions surfaced by a long-lived eth_subscribe stream. */
export type SubscriptionStatus = 'open' | 'closed' | 'failed'

/** Why a connect attempt failed, before any error string. */
export type ConnectFailureReason = 'not_found' | 'no_accounts' | 'network'

export interface WalletProviderInfo {
  readonly name: string
  readonly icon: string
  readonly rdns: string
}

/** Every message the JS port can send back. Discriminated by `tag`.
 *
 *  `requestId` echoes the id of the connect attempt that caused the reply,
 *  so a stale wallet prompt resolving after a newer one can be discarded
 *  (`Web3.Wallet`'s supersession FSM depends on it). */
export type Web3Sub =
  // Wallet lifecycle
  | { readonly tag: 'connected'; readonly requestId: number; readonly address: Address; readonly chainId: number }
  | { readonly tag: 'connectRejected'; readonly requestId: number }
  | { readonly tag: 'connectPending'; readonly requestId: number }
  | { readonly tag: 'connectFailed'; readonly requestId: number; readonly reason: ConnectFailureReason; readonly error: string }
  | { readonly tag: 'disconnected' }
  | { readonly tag: 'accountChanged'; readonly address: Address }
  | { readonly tag: 'chainChanged'; readonly chainId: number }
  | { readonly tag: 'walletsDiscovered'; readonly wallets: readonly WalletProviderInfo[] }
  | { readonly tag: 'readOnly' }
  | { readonly tag: 'switchChainOk'; readonly chainId: number }
  | { readonly tag: 'chainAdded' }
  | { readonly tag: 'assetWatched' }
  | { readonly tag: 'permissions'; readonly permissions: readonly string[] }
  | { readonly tag: 'rejected' }

  // Tx lifecycle
  | { readonly tag: 'submitted'; readonly hash: TxHash }
  | { readonly tag: 'confirmation'; readonly hash: TxHash; readonly count: number }
  | { readonly tag: 'confirmed'; readonly hash: TxHash; readonly blockNumber: number; readonly gasUsed: string; readonly status: boolean; readonly logs: readonly ReceiptLogJson[] }
  /** `status: false` means mined-and-reverted, not "not yet mined". */
  | { readonly tag: 'receiptResult'; readonly id: string; readonly hash: TxHash; readonly blockNumber: number; readonly gasUsed: string; readonly status: boolean; readonly logs: readonly ReceiptLogJson[] }
  | { readonly tag: 'receiptNotFound'; readonly id: string }
  | { readonly tag: 'failed'; readonly error: string; readonly revertData?: Hex }
  | { readonly tag: 'gasEstimate'; readonly gas: string }

  // Reads. Every wei-denominated field crosses as a decimal STRING: JSON
  // numbers are doubles and uint256 does not fit in one.
  | { readonly tag: 'callResult'; readonly id: string; readonly data: Hex }
  | { readonly tag: 'multicallResult'; readonly id: string; readonly results: ReadonlyArray<{ readonly success: boolean; readonly data: Hex }> }
  | { readonly tag: 'balance'; readonly id: string; readonly wei: string }
  | { readonly tag: 'storageAt'; readonly id: string; readonly data: Hex }
  | { readonly tag: 'code'; readonly id: string; readonly data: Hex }
  | { readonly tag: 'txCount'; readonly id: string; readonly count: number }
  | { readonly tag: 'gasPrice'; readonly id: string; readonly wei: string }
  | { readonly tag: 'maxPriorityFee'; readonly id: string; readonly wei: string }
  | { readonly tag: 'feeHistory'; readonly id: string; readonly oldestBlock: number; readonly baseFeePerGas: readonly string[]; readonly gasUsedRatio: readonly number[] }
  | { readonly tag: 'blockNumber'; readonly id: string; readonly number: number }
  | { readonly tag: 'block'; readonly id: string; readonly number: number; readonly hash: Hex; readonly timestamp: number; readonly gasLimit: string; readonly gasUsed: string; readonly baseFeePerGas: string | null; readonly parentHash: Hex }
  | { readonly tag: 'blockTxCount'; readonly id: string; readonly count: number }
  | { readonly tag: 'transaction'; readonly id: string; readonly hash: TxHash; readonly from: Address; readonly to: Address | null; readonly value: string; readonly nonce: number; readonly data: Hex; readonly gas: number; readonly blockNumber: number | null; readonly blockHash: Hex | null }
  | { readonly tag: 'transactionNotFound'; readonly id: string }
  | { readonly tag: 'logs'; readonly logs: readonly QueriedLogJson[] }
  | { readonly tag: 'keccak256Result'; readonly id: string; readonly hash: Hex }

  // Live subscriptions (WS preferred, polling fallback)
  | ({ readonly tag: 'eventLog'; readonly id: string } & EventLogJson)
  | { readonly tag: 'subscribed'; readonly id: string; readonly status: SubscriptionStatus }

  // Signing
  | { readonly tag: 'signed'; readonly id: string; readonly signature: Hex }
  | { readonly tag: 'recovered'; readonly id: string; readonly address: Address }

  // Catch-all: a cmd tag the shim has no handler for. No Elm decoder
  // currently matches this, so it is dropped by the port sub.
  | { readonly tag: 'unknownCmd'; readonly cmd: string }

// ─────────────────────────────────────────────────────────────────────
// Module exports
// ─────────────────────────────────────────────────────────────────────

export interface SetupOptions {
  /** **Preferred.** Pool of public JSON-RPC HTTPS endpoints. The wallet
   *  provider (when connected) is canonical for every read; this pool
   *  is the fallback when no wallet is present or the wallet errors
   *  on a read. The runtime shuffles the pool order per page load
   *  (so no endpoint is trusted by default) and circuit-breaks any
   *  endpoint that returns three consecutive transport failures
   *  (60-second cooldown). Logical JSON-RPC errors propagate
   *  immediately — every endpoint returns the same answer for a
   *  given query, so a revert isn't a health signal. */
  readonly rpcUrls?: ReadonlyArray<string>

  /** Pool of WebSocket endpoints for `eth_subscribe`. If omitted, the
   *  runtime derives WS endpoints from `rpcUrls` by rewriting
   *  `https://` → `wss://`. Most public RPC providers expose WS at
   *  the same hostname; override here if yours doesn't. */
  readonly wsUrls?: ReadonlyArray<string>

  /** Deprecated single-endpoint alias for `rpcUrls`. New consumers
   *  should pass `rpcUrls: [url]` instead. Kept for backward
   *  compatibility — `rpcUrl: 'x'` is equivalent to `rpcUrls: ['x']`. */
  readonly rpcUrl?: string
}

/** Wire the Elm ports into the JS runtime. Subscribes `web3Cmd` and starts
 *  listening for wallet events. Call once at app boot, right after
 *  `Elm.Main.init`. */
export function setupPorts(app: ElmApp, opts?: SetupOptions): void

/** Plug an external EIP-1193 provider (WalletConnect, Coinbase SDK, embedded
 *  wallet, ...) into the same code path as `window.ethereum`. Re-binds
 *  chainChanged / accountsChanged / disconnect listeners so Elm stays in sync. */
export function setupExternalProvider(app: ElmApp, provider: Eip1193Provider): void

/** Start EIP-6963 wallet discovery. Browser extensions auto-announce; this
 *  function listens for those announcements and notifies Elm. Idempotent. */
export function watchWallets(app: ElmApp): void

/** Register a non-EIP-6963 provider (WalletConnect, Coinbase SDK, ...) so it
 *  appears in the same wallet picker as browser extensions. */
export function registerProvider(
  app: ElmApp,
  info: WalletProviderInfo,
  provider: Eip1193Provider
): void

// ─────────────────────────────────────────────────────────────────────
// EIP-1193 provider (the structural type for window.ethereum and BYO)
// ─────────────────────────────────────────────────────────────────────

/** Minimal EIP-1193 provider surface this port script depends on. */
export interface Eip1193Provider {
  request<T = unknown>(args: { method: string; params?: readonly unknown[] | object }): Promise<T>
  on?(event: 'chainChanged' | 'accountsChanged' | 'disconnect' | 'connect', handler: (...args: never[]) => void): void
  removeListener?(event: string, handler: (...args: never[]) => void): void
}

// ─────────────────────────────────────────────────────────────────────
// Type guards (consumers can re-use)
// ─────────────────────────────────────────────────────────────────────

/** Returns true if `value` is a 0x-prefixed hex string. */
export function isHex(value: unknown): value is Hex

/** Returns true if `value` is a 20-byte EVM address (0x + 40 hex chars). */
export function isAddress(value: unknown): value is Address

/** Returns true if `value` is a 32-byte transaction hash (0x + 64 hex chars). */
export function isTxHash(value: unknown): value is TxHash

// ─────────────────────────────────────────────────────────────────────
// Augment Window for browser-extension provider discovery
// ─────────────────────────────────────────────────────────────────────

declare global {
  interface Window {
    /** EIP-1193 provider injected by the user's wallet, if any. */
    ethereum?: Eip1193Provider
  }
}
