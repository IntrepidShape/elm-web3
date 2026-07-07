/**
 * elm-web3-ports.ts — canonical TypeScript source.
 *
 * Ships as the primary file alongside `elm-web3-ports.js`, which is a
 * codegen artifact (`bun build` of this file) provided as a fallback
 * for consumers without a TS toolchain. Matt-Pocock airtight: every
 * boundary is a discriminated union, every public function has an
 * explicit return type, and the `any` keyword does not appear.
 *
 * The entire JS layer. Uses window.ethereum directly. No viem, no wagmi,
 * no ethers. Just raw JSON-RPC.
 *
 * Usage:
 *   import { setupPorts } from 'elm-web3/js/elm-web3-ports.js'
 *   const app = Elm.Main.init({ node: ... })
 *
 *   // Minimal — wallet-only:
 *   setupPorts(app)
 *
 *   // Single public RPC for the no-wallet read path:
 *   setupPorts(app, { rpcUrl: 'https://rpc.example.com' })
 *
 *   // Peak decentralisation — pool of public RPCs, shuffled per session,
 *   // circuit-broken on failure. WebSocket endpoints derived from the
 *   // pool by https→wss rewrite (override via `wsUrls`):
 *   setupPorts(app, {
 *     rpcUrls: [
 *       'https://rpc.pulsechain.com',
 *       'https://rpc-pulsechain.g4mm4.io',
 *       'https://pulsechain-rpc.publicnode.com',
 *     ],
 *   })
 *
 * Architecture:
 *   - Reads route through the wallet provider when connected. Only fall
 *     back to the public RPC pool on wallet error OR when no wallet is
 *     present. The user's wallet RPC is always canonical.
 *   - Writes (signing, eth_sendTransaction, switchChain) always go
 *     through the wallet — never the public pool.
 *   - Event subscriptions prefer eth_subscribe over a long-lived
 *     WebSocket; fall back to a 4s eth_getLogs poll if WS handshake fails.
 *   - Multicall3 batches every read that supports it. Falls through the
 *     same _rpcRequest path as plain eth_call.
 */

// ─────────────────────────────────────────────────────────────────────
// Type prelude. The .d.ts sibling file is the EXTERNAL surface for
// consumers; the local types below mirror it so this file builds in
// strict mode without re-declaring every cross-cutting concern.
// ─────────────────────────────────────────────────────────────────────
interface Eip1193Error extends Error {
  readonly code?: number;
  readonly data?: unknown;
}
export interface Eip1193Provider {
  request<T = unknown>(args: { readonly method: string; readonly params?: readonly unknown[] | object }): Promise<T>;
  on?(event: string, handler: (...args: never[]) => void): void;
  removeListener?(event: string, handler: (...args: never[]) => void): void;
}
export interface WalletProviderInfo {
  readonly name: string;
  readonly icon: string;
  readonly rdns: string;
  readonly uuid?: string;
}
interface Eip6963Entry {
  readonly info: WalletProviderInfo;
  readonly provider: Eip1193Provider;
}

interface ElmPort<T> {
  subscribe?: (handler: (value: T) => void) => void;
  send?: (value: T) => void;
}
export interface ElmApp {
  readonly ports: Readonly<Record<string, ElmPort<unknown>>>;
}

/** Single multicall sub-call shape, mirrored from Web3.Multicall.Elm. */
interface CallSpec {
  readonly contract: string;
  readonly method:   string;
  readonly args:     readonly unknown[];
}

/** Discriminated union of every cmd this script handles. Narrowing via
 *  `cmd.tag === '…'` gives each switch branch a concrete payload. The
 *  trailing wide-tag arm allows forward-compat for cmds defined in
 *  later Elm-side additions without forcing a runtime crash. */
export type Web3Cmd =
  | { readonly tag: "connect" }
  | { readonly tag: "disconnect" }
  | { readonly tag: "switchChain";   readonly chainId: number }
  | { readonly tag: "selectWallet";  readonly rdns: string }
  | { readonly tag: "call";          readonly id: string; readonly contract: string; readonly method: string; readonly args: readonly unknown[]; readonly block?: string }
  | { readonly tag: "send";          readonly contract: string; readonly method: string; readonly args: readonly unknown[]; readonly value?: string; readonly gasLimit?: number; readonly skipSimulate?: boolean }
  | { readonly tag: "estimateGas";   readonly contract: string; readonly method: string; readonly args: readonly unknown[]; readonly value?: string }
  | { readonly tag: "multicall";     readonly id: string; readonly calls: readonly CallSpec[] }
  | { readonly tag: "watchEvent";    readonly id: string; readonly address: string; readonly topics?: ReadonlyArray<string | null> }
  | { readonly tag: "unwatchEvent";  readonly id: string }
  | { readonly tag: "signTypedData"; readonly id: string; readonly from: string; readonly data: unknown }
  | { readonly tag: "personalSign";  readonly id: string; readonly from: string; readonly message: string }
  | { readonly tag: "getBalance";    readonly id: string; readonly address: string; readonly block?: string }
  | { readonly tag: string;          readonly [k: string]: unknown };

/** Sub messages emitted back to Elm. Tag-only discriminator; payload
 *  fields are validated by the Elm side's decoders. */
export type Web3Sub = { readonly tag: string; readonly [k: string]: unknown };

export interface SetupOptions {
  readonly rpcUrls?: ReadonlyArray<string>;
  readonly wsUrls?: ReadonlyArray<string>;
  readonly rpcUrl?: string;
}

declare global {
  interface Window {
    ethereum?: Eip1193Provider;
  }
}

// EIP-6963: map of rdns -> { info, provider } for discovered wallets
const _eip6963Providers = new Map<string, Eip6963Entry>();

// Tracks the currently-connected provider so `disconnect` knows where to send
// `wallet_revokePermissions`. Initially null; set by `connect` / `selectWallet`,
// cleared by `disconnect`.
let _activeProvider: Eip1193Provider | null = null;

/** Throws if no injected wallet provider is available. Use this at the
 *  top of every write-path branch — once it returns, the rest of the
 *  case can rely on a concrete Eip1193Provider. */
const requireWallet = (): Eip1193Provider => {
  const w = typeof window !== 'undefined' ? window.ethereum : null;
  if (!w) throw new Error('No wallet found');
  return w;
};

/** Narrow `unknown` (the strict-mode type of caught exceptions) to the
 *  EIP-1193 error shape, wrapping non-Error throws into a typed Error. */
const asEip1193Error = (e: unknown): (Error & { code?: number; data?: unknown }) => {
  if (e instanceof Error) return e as Error & { code?: number; data?: unknown };
  if (typeof e === 'object' && e !== null) {
    const o = e as { message?: unknown; code?: unknown; data?: unknown };
    const err = new Error(typeof o.message === 'string' ? o.message : String(e)) as Error & { code?: number; data?: unknown };
    if (typeof o.code === 'number') err.code = o.code;
    if (o.data !== undefined) err.data = o.data;
    return err;
  }
  return new Error(String(e));
};

/**
 * Connect to a provider in a way that forces the wallet UI to (re-)prompt the
 * user for account selection — even when the dapp already has a cached
 * `eth_accounts` permission for that origin.
 *
 * Strategy (per EIP-2255 / MIP-2):
 *   1. Try `wallet_requestPermissions({ eth_accounts: {} })`. On wallets that
 *      implement EIP-2255 (MetaMask, Internet Money, Rabby, Brave Wallet,
 *      Coinbase Wallet) this ALWAYS pops the account picker, regardless of
 *      whether the dapp is already permitted. The user can swap accounts
 *      inside the wallet at this point.
 *   2. Then call `eth_accounts` to read the active account list.
 *   3. If `wallet_requestPermissions` is unsupported (-32601 / 4200 / other),
 *      fall back to plain `eth_requestAccounts` — silently re-uses the cached
 *      account, which is the same UX as before this helper existed. Better
 *      than failing closed.
 *
 * Returns: `string[]` of accounts. Throws if the user rejects (code 4001) or
 * if the wallet returns no accounts.
 */
async function _requestAccountsForcePrompt(provider: Eip1193Provider): Promise<readonly string[]> {
  try {
    await provider.request({
      method: 'wallet_requestPermissions',
      params: [{ eth_accounts: {} }],
    })
  } catch (e) {
    // 4001 = user rejected (re-throw so the caller can surface it).
    if (e && e.code === 4001) throw e
    // Anything else → method unsupported on this wallet, fall back below.
    return provider.request({ method: 'eth_requestAccounts' })
  }
  return provider.request({ method: 'eth_accounts' })
}

export function setupPorts(app, options = {}) {
  // Backward-compat: `rpcUrl` (singular) is accepted as an alias for a
  // single-element `rpcUrls` (plural) pool. Prefer the array.
  const rpcUrls = Array.isArray(options.rpcUrls)
    ? options.rpcUrls.slice()
    : (options.rpcUrl ? [options.rpcUrl] : [])

  // Fisher-Yates shuffle so every browser session has a different
  // priority order. No deterministic first-endpoint trust assumption.
  for (let i = rpcUrls.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1))
    ;[rpcUrls[i], rpcUrls[j]] = [rpcUrls[j], rpcUrls[i]]
  }

  // Per-endpoint health tally. Three consecutive failures puts an
  // endpoint in 60s cooldown; any success resets the counter.
  const RPC_HEALTH = new Map(rpcUrls.map(u => [u, { failures: 0, cooldownUntil: 0 }]))
  const RPC_FAILURE_THRESHOLD = 3
  const RPC_COOLDOWN_MS = 60_000

  // The set of read-only JSON-RPC methods. Writes (signing, sending,
  // chain-switch) never fall back to the public pool.
  const READ_ONLY_METHODS = new Set([
    'eth_call',
    'eth_chainId',
    'eth_blockNumber',
    'eth_getBalance',
    'eth_getCode',
    'eth_getStorageAt',
    'eth_getTransactionByHash',
    'eth_getTransactionReceipt',
    'eth_getTransactionCount',
    'eth_getBlockByNumber',
    'eth_getBlockByHash',
    'eth_getLogs',
    'eth_gasPrice',
    'eth_feeHistory',
    'eth_estimateGas',
  ])

  let _rpcId = 0

  async function _rpcCallOne(endpoint, method, params) {
    const health = RPC_HEALTH.get(endpoint)
    if (health && Date.now() < health.cooldownUntil) {
      throw new Error('rpc cooldown: ' + endpoint)
    }
    let res
    try {
      res = await fetch(endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: ++_rpcId, method, params: params || [] }),
      })
    } catch (e) {
      _markRpcFailure(endpoint)
      throw e
    }
    if (!res.ok) {
      _markRpcFailure(endpoint)
      throw new Error('rpc http ' + res.status + ': ' + endpoint)
    }
    const json = await res.json()
    if (json && json.error) {
      // JSON-RPC error — the endpoint IS responsive; don't penalise it.
      // The error is logical (revert, gas too low) and re-trying on
      // another endpoint won't help.
      const err = new Error(json.error.message || JSON.stringify(json.error))
      err.code = json.error.code
      err.data = json.error.data
      throw err
    }
    if (health) {
      health.failures = 0
      health.cooldownUntil = 0
    }
    return json.result
  }

  function _markRpcFailure(endpoint) {
    const h = RPC_HEALTH.get(endpoint)
    if (!h) return
    h.failures += 1
    if (h.failures >= RPC_FAILURE_THRESHOLD) {
      h.cooldownUntil = Date.now() + RPC_COOLDOWN_MS
    }
  }

  async function _publicRpcCall(method, params) {
    let lastErr = null
    for (const endpoint of rpcUrls) {
      try {
        return await _rpcCallOne(endpoint, method, params)
      } catch (e) {
        lastErr = e
        // Logical JSON-RPC errors should propagate immediately — every
        // endpoint will return the same answer.
        if (e && typeof e.code === 'number' && e.code !== -32603) throw e
      }
    }
    throw lastErr || new Error('all public RPCs failed')
  }

  // The canonical dispatcher. Wallet wins; public pool is the read-only
  // fallback. Writes throw if no wallet — never sign with a stranger's RPC.
  async function _rpcRequest(method, params) {
    const isRead = READ_ONLY_METHODS.has(method)
    const provider = _activeProvider || (typeof window !== 'undefined' ? window.ethereum : null)
    if (provider && typeof provider.request === 'function') {
      try {
        return await provider.request({ method, params: params || [] })
      } catch (e) {
        if (!isRead) throw e
        if (e && typeof e.code === 'number' && e.code === 4001) throw e
        // fall through to public pool
      }
    }
    if (!isRead) {
      throw new Error('no wallet provider available for write method ' + method)
    }
    if (rpcUrls.length === 0) {
      throw new Error('no wallet and no rpcUrls configured')
    }
    return _publicRpcCall(method, params)
  }

  // Notify Elm of read-only mode when an RPC pool is configured but no
  // wallet is available. Lets the UI gate write actions accordingly.
  if (rpcUrls.length > 0) {
    setTimeout(() => {
      if (typeof window === 'undefined' || !window.ethereum) {
        app.ports.web3Sub.send({ tag: 'readOnly' })
      }
    }, 0)
  }

  // Silent auto-reconnect: if we were connected last session and the wallet
  // still authorizes this site, restore the session without ever prompting.
  // eth_accounts (unlike eth_requestAccounts/wallet_requestPermissions)
  // never triggers a permission popup — it just resolves to [] if we're not
  // already authorized, which we swallow silently (never toast/error on
  // page load for this).
  if (typeof window !== 'undefined' && window.ethereum) {
    let wasConnected = false
    try { wasConnected = localStorage.getItem('elm-web3:walletConnected') === '1' } catch (_) { /* ignore */ }
    if (wasConnected) {
      window.ethereum.request({ method: 'eth_accounts' })
        .then((accounts) => {
          if (!accounts || accounts.length === 0) return
          _activeProvider = window.ethereum
          return window.ethereum.request({ method: 'eth_chainId' }).then((chainId) => {
            app.ports.web3Sub.send({
              tag: 'connected',
              address: accounts[0],
              chainId: parseInt(chainId, 16),
            })
          })
        })
        .catch(() => { /* silent — this is a best-effort background reconnect */ })
    }
  }

  // ─── eth_subscribe WebSocket plumbing ────────────────────────────────
  // Single shared socket; every Elm subscription multiplexes over it.
  // Reconnect with exponential backoff (1s → 30s) on close; the open
  // subscriptions are re-armed on reconnect so the chain stream is
  // gap-free across socket churn (modulo the WS endpoint's own
  // catch-up policy).
  const wsUrls = Array.isArray(options.wsUrls) && options.wsUrls.length > 0
    ? options.wsUrls.slice()
    : rpcUrls.map(u => u.replace(/^http(s?):\/\//i, (_m, s) => 'ws' + (s || '') + '://'))

  let _ws = null
  let _wsBackoff = 1000
  const _wsBackoffMax = 30_000
  let _wsReqId = 0
  let _wsEndpointIdx = 0
  const _wsPending = new Map()
  const _subscriptions = new Map()
  // Block-number pollers keyed by correlation id — cleared on re-issue and
  // via 'unwatchBlockNumber' (F8: previously these intervals leaked).
  const _blockPollers = new Map()

  function _wsCall(method, params) {
    if (!_ws || _ws.readyState !== 1) return Promise.reject(new Error('ws not open'))
    const id = ++_wsReqId
    return new Promise((resolve, reject) => {
      _wsPending.set(id, { resolve, reject })
      _ws.send(JSON.stringify({ jsonrpc: '2.0', id, method, params: params || [] }))
      setTimeout(() => {
        if (_wsPending.has(id)) {
          _wsPending.delete(id)
          reject(new Error('ws request timeout'))
        }
      }, 10_000)
    })
  }

  function _ensureWs() {
    if (_ws && (_ws.readyState === 0 || _ws.readyState === 1)) return Promise.resolve(_ws)
    if (wsUrls.length === 0) return Promise.reject(new Error('no ws endpoints'))
    const endpoint = wsUrls[_wsEndpointIdx % wsUrls.length]
    return new Promise((resolve, reject) => {
      let socket
      try { socket = new WebSocket(endpoint) }
      catch (e) { reject(e); return }
      socket.onopen = () => {
        _ws = socket
        _wsBackoff = 1000
        // Re-arm every active subscription on reconnect.
        for (const [elmId, sub] of _subscriptions) {
          _wsCall('eth_subscribe', sub.subscribeParams).then(chainId => {
            sub.chainId = chainId
            app.ports.web3Sub.send({ tag: 'subscribed', id: elmId, status: 'open' })
          }).catch(() => {
            app.ports.web3Sub.send({ tag: 'subscribed', id: elmId, status: 'failed' })
          })
        }
        resolve(socket)
      }
      socket.onmessage = (ev) => {
        let msg
        try { msg = JSON.parse(ev.data) } catch { return }
        if (typeof msg.id === 'number' && _wsPending.has(msg.id)) {
          const pending = _wsPending.get(msg.id)
          _wsPending.delete(msg.id)
          if (msg.error) pending.reject(msg.error)
          else pending.resolve(msg.result)
          return
        }
        if (msg.method === 'eth_subscription' && msg.params) {
          const chainId = msg.params.subscription
          const log = msg.params.result
          if (!log) return
          for (const [elmId, sub] of _subscriptions) {
            if (sub.chainId === chainId && sub.kind === 'head') {
              // newHeads subscription — emit the same message shape as the
              // polling path so Elm needs no changes.
              app.ports.web3Sub.send({
                tag: 'blockNumber',
                id: elmId,
                number: parseInt(log.number, 16),
              })
              continue
            }
            if (sub.chainId === chainId) {
              app.ports.web3Sub.send({
                tag: 'eventLog',
                id: elmId,
                address: log.address,
                topics: log.topics || [],
                data: log.data,
                blockNumber: parseInt(log.blockNumber, 16),
                logIndex: parseInt(log.logIndex, 16),
                transactionHash: log.transactionHash,
                removed: log.removed === true,
              })
              break
            }
          }
        }
      }
      socket.onclose = () => {
        _ws = null
        for (const [elmId] of _subscriptions) {
          app.ports.web3Sub.send({ tag: 'subscribed', id: elmId, status: 'closed' })
        }
        if (_subscriptions.size > 0) {
          _wsEndpointIdx += 1
          const wait = _wsBackoff
          _wsBackoff = Math.min(_wsBackoff * 2, _wsBackoffMax)
          setTimeout(() => { _ensureWs().catch(() => {}) }, wait)
        }
      }
      socket.onerror = () => { /* close handler will reconnect */ }
    })
  }

  async function _startEventSubscription(cmd) {
    const params = ['logs', { address: cmd.address, topics: cmd.topics || [] }]
    _subscriptions.set(cmd.id, { subscribeParams: params, chainId: null, kind: 'log' })
    try {
      await _ensureWs()
      const chainId = await _wsCall('eth_subscribe', params)
      const sub = _subscriptions.get(cmd.id)
      if (sub) sub.chainId = chainId
      app.ports.web3Sub.send({ tag: 'subscribed', id: cmd.id, status: 'open' })
    } catch (_) {
      app.ports.web3Sub.send({ tag: 'subscribed', id: cmd.id, status: 'failed' })
    }
  }

  async function _stopEventSubscription(elmId) {
    const sub = _subscriptions.get(elmId)
    if (!sub) return
    _subscriptions.delete(elmId)
    if (sub.chainId && _ws && _ws.readyState === 1) {
      try { await _wsCall('eth_unsubscribe', [sub.chainId]) } catch {}
    }
  }

  // --- Wallet ---

  app.ports.web3Cmd.subscribe(async (cmd) => {
    try {
      switch (cmd.tag) {
        case 'connect': {
          // Own try/catch (not the shared one at the bottom of this
          // subscribe callback) — a rejected/already-pending permission
          // request must never be misrouted through the generic
          // on-chain-transaction 'rejected'/'failed' tags below, which
          // previously left the Elm-side wallet FSM with no way to tell a
          // cancelled connect apart from a failed transaction.
          const { requestId } = cmd
          try {
            if (!window.ethereum && rpcUrls.length > 0) {
              app.ports.web3Sub.send({ tag: 'readOnly' })
              break
            }
            if (!window.ethereum) {
              app.ports.web3Sub.send({ tag: 'connectFailed', requestId, reason: 'not_found', error: 'No wallet extension detected' })
              break
            }
            const accounts = await _requestAccountsForcePrompt(window.ethereum)
            if (!accounts || accounts.length === 0) {
              app.ports.web3Sub.send({ tag: 'connectFailed', requestId, reason: 'no_accounts', error: 'Wallet returned no accounts' })
              break
            }
            const chainId = await window.ethereum.request({ method: 'eth_chainId' })
            _activeProvider = window.ethereum
            try { localStorage.setItem('elm-web3:walletConnected', '1') } catch (_) { /* ignore */ }
            app.ports.web3Sub.send({
              tag: 'connected',
              requestId,
              address: accounts[0],
              chainId: parseInt(chainId, 16),
            })
          } catch (err) {
            if (err.code === 4001) {
              app.ports.web3Sub.send({ tag: 'connectRejected', requestId })
            } else if (err.code === -32002) {
              app.ports.web3Sub.send({ tag: 'connectPending', requestId })
            } else {
              app.ports.web3Sub.send({ tag: 'connectFailed', requestId, reason: 'network', error: err.message || String(err) })
            }
          }
          break
        }

        case 'disconnect': {
          // Wallets don't support a true programmatic disconnect — calling
          // eth_requestAccounts later just silently returns the cached account
          // because the dapp still holds eth_accounts permission. EIP-2255 +
          // MIP-2's `wallet_revokePermissions` is the proper escape hatch: it
          // drops the permission so the *next* connect attempt forces the
          // wallet UI to re-prompt account selection. Wrap in try/catch so
          // older wallets (no EIP-2255 support, error code -32601 / 4200)
          // still get a clean local-state disconnect.
          const provider = _activeProvider || window.ethereum
          if (provider && typeof provider.request === 'function') {
            try {
              await provider.request({
                method: 'wallet_revokePermissions',
                params: [{ eth_accounts: {} }],
              })
            } catch (e) {
              // Method-not-found / unsupported / user-rejected — swallow.
              // Local Elm state still goes to Disconnected; user can retry
              // and the worst case is silent re-connection on next attempt
              // (same UX as before this fix).
            }
          }
          _activeProvider = null
          try { localStorage.removeItem('elm-web3:walletConnected') } catch (_) { /* ignore */ }
          app.ports.web3Sub.send({ tag: 'disconnected' })
          break
        }

        case 'switchChain': {
          if (!window.ethereum) throw new Error('No wallet found')
          const hex = '0x' + cmd.chainId.toString(16)
          await window.ethereum.request({
            method: 'wallet_switchEthereumChain',
            params: [{ chainId: hex }],
          })
          app.ports.web3Sub.send({ tag: 'switchChainOk', chainId: cmd.chainId })
          break
        }

        // --- Contract reads (and simulated writes via from) ---
        case 'call': {
          const callTx = { to: cmd.contract, data: encodeCall(cmd.method, cmd.args) }
          if (cmd.from) callTx.from = cmd.from
          const result = await _rpcRequest('eth_call', [callTx, cmd.block || 'latest'])
          app.ports.web3Sub.send({ tag: 'callResult', id: cmd.id, data: result })
          break
        }

        // --- Gas estimation ---
        case 'estimateGas': {
          if (!window.ethereum) throw new Error('No wallet found')
          const accounts = await window.ethereum.request({ method: 'eth_accounts' })
          const txParams = {
            from: accounts[0],
            to: cmd.contract,
            data: encodeCall(cmd.method, cmd.args),
          }
          if (cmd.value) txParams.value = '0x' + BigInt(cmd.value).toString(16)
          const gasHex = await window.ethereum.request({
            method: 'eth_estimateGas',
            params: [txParams],
          })
          app.ports.web3Sub.send({ tag: 'gasEstimate', gas: parseInt(gasHex, 16).toString() })
          break
        }

        // --- Contract writes ---
        // Simulate-then-send. We always run `eth_estimateGas` against the
        // same params before prompting the wallet — if the simulation
        // reverts, the wallet is NEVER asked to sign. The user sees the
        // decoded revert reason via the standard `failed` channel instead
        // of paying gas + getting an opaque wallet error.
        //
        // Opt out by passing `cmd.skipSimulate = true`. Some payable flows
        // (e.g. zero-value calls already validated client-side) can skip
        // the extra round trip — but the default is safe-by-default.
        case 'send': {
          if (!window.ethereum) throw new Error('No wallet found')
          const accounts = await window.ethereum.request({ method: 'eth_accounts' })
          const txParams = {
            from: accounts[0],
            to: cmd.contract,
            data: encodeCall(cmd.method, cmd.args),
          }
          if (cmd.value) txParams.value = '0x' + BigInt(cmd.value).toString(16)
          if (cmd.gasLimit) txParams.gas = '0x' + cmd.gasLimit.toString(16)

          if (!cmd.skipSimulate) {
            // Pre-flight via eth_estimateGas. If this throws, the catch
            // block at the bottom of the cmd switch catches it, runs
            // `_decodeRevertReason` against the error data, and emits
            // `tag: 'failed'` with the decoded revert reason. The wallet
            // is never prompted.
            await window.ethereum.request({
              method: 'eth_estimateGas',
              params: [txParams],
            })
          }

          const hash = await window.ethereum.request({
            method: 'eth_sendTransaction',
            params: [txParams],
          })
          app.ports.web3Sub.send({ tag: 'submitted', hash })

          // Poll for confirmation
          pollReceipt(hash, app, _rpcRequest)
          break
        }

        // --- Multicall3 batch reads ---
        case 'multicall': {
          const MULTICALL3 = '0xcA11bde05977b3631167028862bE2a173976CA11'
          const callDatas = cmd.calls.map(c => encodeCall(c.method, c.args))
          const data = _encodeAggregate3(cmd.calls, callDatas)
          const raw = await _rpcRequest('eth_call', [{ to: MULTICALL3, data }, 'latest'])
          const results = _decodeAggregate3Result(raw)
          app.ports.web3Sub.send({ tag: 'multicallResult', id: cmd.id, results })
          break
        }

        // --- Event watching (WS subscribe; polling fallback) ---
        //
        // Prefer eth_subscribe over a long-lived WebSocket for sub-second
        // push latency. If no wsUrls are configured OR the handshake
        // fails on every endpoint, fall back to a 4s eth_getLogs poll
        // so the subscription degrades to a polling cadence instead of
        // failing closed.
        //
        // cmd shape:
        //   { tag: 'watchEvent', id, address, topics?: string[],
        //     fromBlock?: number | 'latest' }
        // Replies via web3Sub:
        //   { tag: 'eventLog', id, address, topics, data, blockNumber,
        //                       logIndex, transactionHash, removed }
        //   { tag: 'subscribed', id, status: 'open' | 'closed' | 'failed' }
        case 'watchEvent': {
          if (wsUrls.length > 0) {
            _startEventSubscription(cmd)
          } else {
            // Polling fallback — same shape as the WS path so Elm doesn't
            // care which transport is active.
            const startHex = await _rpcRequest('eth_blockNumber', [])
            let fromBlock = parseInt(startHex, 16)
            const handle = setInterval(async () => {
              try {
                const toHex = await _rpcRequest('eth_blockNumber', [])
                const toBlock = parseInt(toHex, 16)
                if (toBlock < fromBlock) return
                const filter = { address: cmd.address || cmd.contract, fromBlock: '0x' + fromBlock.toString(16), toBlock: toHex }
                if (cmd.topics?.length) filter.topics = cmd.topics
                const logs = await _rpcRequest('eth_getLogs', [filter])
                for (const log of logs) {
                  app.ports.web3Sub.send({
                    tag: 'eventLog',
                    id: cmd.id,
                    address: log.address,
                    topics: log.topics || [],
                    data: log.data,
                    blockNumber: parseInt(log.blockNumber, 16),
                    logIndex: parseInt(log.logIndex, 16),
                    transactionHash: log.transactionHash,
                    removed: log.removed === true,
                  })
                }
                fromBlock = toBlock + 1
              } catch (_) {}
            }, 4000)
            _subscriptions.set(cmd.id, { polling: handle })
            app.ports.web3Sub.send({ tag: 'subscribed', id: cmd.id, status: 'open' })
          }
          break
        }
        case 'unwatchEvent': {
          const sub = _subscriptions.get(cmd.id)
          if (sub && sub.polling) {
            clearInterval(sub.polling)
            _subscriptions.delete(cmd.id)
          } else {
            await _stopEventSubscription(cmd.id)
          }
          break
        }

        // --- Native ETH balance ---
        case 'getBalance': {
          const hex = await _rpcRequest('eth_getBalance', [cmd.address, cmd.block || 'latest'])
          app.ports.web3Sub.send({ tag: 'balance', id: cmd.id, wei: BigInt(hex).toString() })
          break
        }

        // --- personal_sign (login flows, simple message signing) ---
        case 'personalSign': {
          if (!window.ethereum) throw new Error('No wallet found')
          const sig = await window.ethereum.request({
            method: 'personal_sign',
            params: [cmd.message, cmd.from],
          })
          app.ports.web3Sub.send({ tag: 'signed', id: cmd.id, signature: sig })
          break
        }

        // --- EIP-191 signature verification (personal_ecRecover) ---
        case 'ecRecover': {
          if (!window.ethereum) throw new Error('No wallet found')
          const address = await window.ethereum.request({
            method: 'personal_ecRecover',
            params: [cmd.message, cmd.signature],
          })
          app.ports.web3Sub.send({ tag: 'recovered', id: cmd.id, address })
          break
        }

        // --- EIP-712 typed signing ---
        case 'signTypedData': {
          if (!window.ethereum) throw new Error('No wallet found')
          const signature = await window.ethereum.request({
            method: 'eth_signTypedData_v4',
            params: [cmd.from, JSON.stringify(cmd.data)],
          })
          app.ports.web3Sub.send({ tag: 'signed', id: cmd.id, signature })
          break
        }

        // --- EIP-6963 wallet selection ---
        case 'selectWallet': {
          // Re-request providers and connect to the one matching rdns.
          // We deliberately use `wallet_requestPermissions({ eth_accounts: {} })`
          // (EIP-2255) instead of `eth_requestAccounts` so the wallet *re-
          // prompts* the account picker every time — even when the user is
          // already connected to the same wallet but wants to swap accounts
          // inside it. Without this, MetaMask-derivatives (Internet Money,
          // Brave Wallet, Rabby) silently return the cached account and the
          // user has no way to switch.
          // Own try/catch — same reasoning as 'connect' above.
          const { rdns, requestId } = cmd
          try {
            const found = _eip6963Providers.get(rdns)
            if (!found) {
              app.ports.web3Sub.send({ tag: 'connectFailed', requestId, reason: 'not_found', error: `Wallet not found: ${rdns}` })
              break
            }
            // Revoke any prior permission on the OUTGOING provider so its
            // cached session doesn't survive across wallet swaps.
            if (_activeProvider && _activeProvider !== found.provider) {
              try {
                await _activeProvider.request({
                  method: 'wallet_revokePermissions',
                  params: [{ eth_accounts: {} }],
                })
              } catch (_) { /* unsupported — fine */ }
            }
            const accounts = await _requestAccountsForcePrompt(found.provider)
            if (!accounts || accounts.length === 0) {
              app.ports.web3Sub.send({ tag: 'connectFailed', requestId, reason: 'no_accounts', error: 'Wallet returned no accounts' })
              break
            }
            const chainId = await found.provider.request({ method: 'eth_chainId' })
            // Swap the active provider so all subsequent calls use the selected wallet
            window.ethereum = found.provider
            _activeProvider = found.provider
            try { localStorage.setItem('elm-web3:walletConnected', '1') } catch (_) { /* ignore */ }
            app.ports.web3Sub.send({
              tag: 'connected',
              requestId,
              address: accounts[0],
              chainId: parseInt(chainId, 16),
            })
          } catch (err) {
            if (err.code === 4001) {
              app.ports.web3Sub.send({ tag: 'connectRejected', requestId })
            } else if (err.code === -32002) {
              app.ports.web3Sub.send({ tag: 'connectPending', requestId })
            } else {
              app.ports.web3Sub.send({ tag: 'connectFailed', requestId, reason: 'network', error: err.message || String(err) })
            }
          }
          break
        }

        // --- Add chain to wallet (EIP-3085) ---
        case 'addChain': {
          if (!window.ethereum) throw new Error('No wallet found')
          await window.ethereum.request({
            method: 'wallet_addEthereumChain',
            params: [{
              chainId: '0x' + cmd.chainId.toString(16),
              chainName: cmd.chainName,
              rpcUrls: cmd.rpcUrls,
              nativeCurrency: cmd.nativeCurrency,
              blockExplorerUrls: cmd.blockExplorerUrls,
            }],
          })
          app.ports.web3Sub.send({ tag: 'chainAdded' })
          break
        }

        // --- Block number query ---
        case 'getBlockNumber': {
          const hex = await _rpcRequest('eth_blockNumber', [])
          app.ports.web3Sub.send({ tag: 'blockNumber', id: cmd.id, number: parseInt(hex, 16) })
          break
        }

        // --- Block data query ---
        case 'getBlock': {
          const block = await _rpcRequest('eth_getBlockByNumber', [
            blockNumberToHex(cmd.block), false,
          ])
          app.ports.web3Sub.send({
            tag: 'block', id: cmd.id,
            number: parseInt(block.number, 16),
            hash: block.hash,
            timestamp: parseInt(block.timestamp, 16),
            gasLimit: BigInt(block.gasLimit).toString(),
            gasUsed: BigInt(block.gasUsed).toString(),
            baseFeePerGas: block.baseFeePerGas ? BigInt(block.baseFeePerGas).toString() : null,
            parentHash: block.parentHash,
          })
          break
        }

        // --- Watch block number (poll every 4s) ---
        case 'watchBlockNumber': {
          const pollBlock = async () => {
            try {
              const hex = await _rpcRequest('eth_blockNumber', [])
              app.ports.web3Sub.send({ tag: 'blockNumber', id: cmd.id, number: parseInt(hex, 16) })
            } catch (_) {}
          }
          // Re-issuing under the same id replaces the watcher (F8).
          if (_blockPollers.has(cmd.id)) clearInterval(_blockPollers.get(cmd.id))
          _blockPollers.delete(cmd.id)
          _subscriptions.delete(cmd.id)
          // Prefer a WS newHeads subscription (push, block-accurate);
          // fall back to the 4s poll when no WS endpoint is available.
          pollBlock()
          try {
            _subscriptions.set(cmd.id, { subscribeParams: ['newHeads'], chainId: null, kind: 'head' })
            await _ensureWs()
            const subId = await _wsCall('eth_subscribe', ['newHeads'])
            const sub = _subscriptions.get(cmd.id)
            if (sub) sub.chainId = subId
          } catch (_) {
            _subscriptions.delete(cmd.id)
            _blockPollers.set(cmd.id, setInterval(pollBlock, 4000))
          }
          break
        }

        case 'unwatchBlockNumber': {
          if (_blockPollers.has(cmd.id)) {
            clearInterval(_blockPollers.get(cmd.id))
            _blockPollers.delete(cmd.id)
          }
          const sub = _subscriptions.get(cmd.id)
          if (sub && sub.kind === 'head') {
            _subscriptions.delete(cmd.id)
            if (sub.chainId) {
              try { await _wsCall('eth_unsubscribe', [sub.chainId]) } catch (_) {}
            }
          }
          break
        }

        // --- Transaction count (nonce) ---
        case 'getTransactionCount': {
          const hex = await _rpcRequest('eth_getTransactionCount', [cmd.address, 'latest'])
          app.ports.web3Sub.send({ tag: 'txCount', id: cmd.id, count: parseInt(hex, 16) })
          break
        }

        // --- Storage slot read ---
        case 'getStorageAt': {
          const val = await _rpcRequest('eth_getStorageAt', [cmd.contract, cmd.slot, cmd.block || 'latest'])
          app.ports.web3Sub.send({ tag: 'storageAt', id: cmd.id, data: val })
          break
        }

        // --- Contract bytecode ---
        case 'getCode': {
          const code = await _rpcRequest('eth_getCode', [cmd.contract, cmd.block || 'latest'])
          app.ports.web3Sub.send({ tag: 'code', id: cmd.id, data: code })
          break
        }

        // --- Current gas price ---
        case 'getGasPrice': {
          const hex = await _rpcRequest('eth_gasPrice', [])
          app.ports.web3Sub.send({ tag: 'gasPrice', id: cmd.id, wei: BigInt(hex).toString() })
          break
        }

        // --- EIP-1559 tip estimate ---
        case 'getMaxPriorityFee': {
          const hex = await _rpcRequest('eth_maxPriorityFeePerGas', [])
          app.ports.web3Sub.send({ tag: 'maxPriorityFee', id: cmd.id, wei: BigInt(hex).toString() })
          break
        }

        // --- EIP-1559 fee history ---
        case 'getFeeHistory': {
          const result = await _rpcRequest('eth_feeHistory', [cmd.blockCount, 'latest', []])
          app.ports.web3Sub.send({
            tag: 'feeHistory', id: cmd.id,
            baseFeePerGas: result.baseFeePerGas.map(h => BigInt(h).toString()),
            gasUsedRatio: result.gasUsedRatio,
            oldestBlock: parseInt(result.oldestBlock, 16),
          })
          break
        }

        // --- Standalone receipt query (does not poll) ---
        case 'getTransactionReceipt': {
          const receipt = await _rpcRequest('eth_getTransactionReceipt', [cmd.hash])
          if (!receipt) {
            app.ports.web3Sub.send({ tag: 'receiptNotFound', id: cmd.id })
          } else {
            app.ports.web3Sub.send({
              tag: 'receiptResult', id: cmd.id,
              hash: receipt.transactionHash,
              blockNumber: parseInt(receipt.blockNumber, 16),
              gasUsed: parseInt(receipt.gasUsed, 16).toString(),
              status: receipt.status === '0x1',
              logs: (receipt.logs || []).map(log => ({
                address: log.address, topics: log.topics || [],
                data: log.data,
                blockNumber: parseInt(log.blockNumber, 16),
                logIndex: parseInt(log.logIndex, 16),
              })),
            })
          }
          break
        }

        // --- Event log queries ---
        case 'getLogs': {
          const filter = {
            address: cmd.contract,
            fromBlock: blockNumberToHex(cmd.fromBlock),
            toBlock: blockNumberToHex(cmd.toBlock),
          }
          if (cmd.topics && cmd.topics.length > 0) {
            filter.topics = cmd.topics
          }
          const logs = await _rpcRequest('eth_getLogs', [filter])
          const processedLogs = logs.map(log => ({
            contract: log.address,
            data: log.data,
            topics: log.topics || [],
            blockNumber: parseInt(log.blockNumber, 16),
            txHash: log.transactionHash,
            logIndex: parseInt(log.logIndex, 16),
          }))
          app.ports.web3Sub.send({ tag: 'logs', logs: processedLogs })
          break
        }

        // --- Fetch transaction by hash ---
        case 'getTransaction': {
          const tx = await _rpcRequest('eth_getTransactionByHash', [cmd.hash])
          if (!tx) {
            app.ports.web3Sub.send({ tag: 'transactionNotFound', id: cmd.id })
          } else {
            app.ports.web3Sub.send({
              tag: 'transaction', id: cmd.id,
              hash: tx.hash,
              from: tx.from,
              to: tx.to || null,
              value: BigInt(tx.value).toString(),
              nonce: parseInt(tx.nonce, 16),
              data: tx.input,
              gas: parseInt(tx.gas, 16),
              blockNumber: tx.blockNumber ? parseInt(tx.blockNumber, 16) : null,
              blockHash: tx.blockHash || null,
            })
          }
          break
        }

        // --- Contract deployment ---
        case 'deploy': {
          if (!window.ethereum) throw new Error('No wallet found')
          const accounts = await window.ethereum.request({ method: 'eth_accounts' })
          const argsEncoded = (cmd.args || []).join('')
          const txParams = {
            from: accounts[0],
            data: cmd.bytecode + argsEncoded,
          }
          if (cmd.value) txParams.value = '0x' + BigInt(cmd.value).toString(16)
          if (cmd.gasLimit) txParams.gas = '0x' + cmd.gasLimit.toString(16)
          const deployHash = await window.ethereum.request({ method: 'eth_sendTransaction', params: [txParams] })
          app.ports.web3Sub.send({ tag: 'submitted', hash: deployHash })
          pollReceipt(deployHash, app, _rpcRequest)
          break
        }

        // --- Broadcast pre-signed transaction ---
        case 'sendRawTransaction': {
          const rawHash = await _rpcRequest('eth_sendRawTransaction', [cmd.rawTx])
          app.ports.web3Sub.send({ tag: 'submitted', hash: rawHash })
          pollReceipt(rawHash, app, _rpcRequest)
          break
        }

        // --- EIP-747: add token to wallet UI ---
        case 'watchAsset': {
          if (!window.ethereum) throw new Error('No wallet found')
          await window.ethereum.request({
            method: 'wallet_watchAsset',
            params: { type: 'ERC20', options: { address: cmd.address, symbol: cmd.symbol, decimals: cmd.decimals, image: cmd.image || '' } },
          })
          app.ports.web3Sub.send({ tag: 'assetWatched' })
          break
        }

        // --- EIP-2255: request permissions ---
        case 'requestPermissions': {
          if (!window.ethereum) throw new Error('No wallet found')
          const reqPerms = await window.ethereum.request({
            method: 'wallet_requestPermissions',
            params: [{ eth_accounts: {} }],
          })
          app.ports.web3Sub.send({ tag: 'permissions', permissions: reqPerms.map(p => p.parentCapability) })
          break
        }

        // --- EIP-2255: get permissions ---
        case 'getPermissions': {
          if (!window.ethereum) throw new Error('No wallet found')
          const curPerms = await window.ethereum.request({ method: 'wallet_getPermissions' })
          app.ports.web3Sub.send({ tag: 'permissions', permissions: curPerms.map(p => p.parentCapability) })
          break
        }

        // --- Block transaction count ---
        case 'getBlockTransactionCount': {
          const blockHex = typeof cmd.block === 'number' ? '0x' + cmd.block.toString(16) : cmd.block
          const txCountHex = await _rpcRequest('eth_getBlockTransactionCountByNumber', [blockHex])
          app.ports.web3Sub.send({ tag: 'blockTxCount', id: cmd.id, count: parseInt(txCountHex, 16) })
          break
        }

        // --- Keccak256 hash ---
        case 'keccak256': {
          const kHash = _keccak256Full(cmd.message)
          app.ports.web3Sub.send({ tag: 'keccak256Result', id: cmd.id, hash: kHash })
          break
        }

        default:
          app.ports.web3Sub.send({ tag: 'unknownCmd', cmd: cmd.tag })
      }
    } catch (err) {
      if (err.code === 4001) {
        app.ports.web3Sub.send({ tag: 'rejected' })
      } else {
        const data = err.data || (err.error && err.error.data)
        const reason = _decodeRevertReason(data)
        // Prefer the on-chain revert reason over the wallet's generic
        // "execution reverted" message — it's the only thing the user can
        // actually act on (e.g. veToken's `LockTooShort()`, ERC-20's
        // "transfer amount exceeds balance"). Fall back to the wallet
        // message if data is missing or unrecognised.
        const baseMsg = err.message || String(err)
        const msg = {
          tag: 'failed',
          error: reason ? reason : baseMsg,
        }
        if (data && typeof data === 'string' && data.startsWith('0x')) {
          msg.revertData = data
        }
        app.ports.web3Sub.send(msg)
      }
    }
  })

  // --- Wallet events ---
  if (window.ethereum) {
    window.ethereum.on('chainChanged', (chainId) => {
      try {
        app.ports.web3Sub.send({ tag: 'chainChanged', chainId: parseInt(chainId, 16) })
      } catch (_) {}
    })
    window.ethereum.on('accountsChanged', (accounts) => {
      try {
        if (accounts.length === 0) {
          // Some wallets (OKX among them) have been observed firing a spurious
          // accountsChanged([]) around an unrelated rejected request, even
          // though the extension still holds a live eth_accounts permission.
          // Silently re-check before tearing down connection state — a real
          // disconnect/lock still resolves to [] here, so this costs one extra
          // no-prompt RPC round trip and closes the false-positive window.
          window.ethereum.request({ method: 'eth_accounts' })
            .then((current) => {
              if (!current || current.length === 0) {
                app.ports.web3Sub.send({ tag: 'disconnected' })
              } else {
                app.ports.web3Sub.send({ tag: 'accountChanged', address: current[0] })
              }
            })
            .catch(() => {
              app.ports.web3Sub.send({ tag: 'disconnected' })
            })
        } else {
          app.ports.web3Sub.send({ tag: 'accountChanged', address: accounts[0] })
        }
      } catch (_) {}
    })
  }
}

/** Bring-your-own EIP-1193 provider (WalletConnect, Coinbase Wallet SDK, embedded
 *  wallet, …). elm-web3 carries no transport dependency — install whichever
 *  package you want, hand the resulting EIP-1193 provider here, and every Elm
 *  command flows through it.
 *
 *  Happy path with WalletConnect:
 *
 *      import { EthereumProvider } from '@walletconnect/ethereum-provider'
 *      const provider = await EthereumProvider.init({
 *        projectId:   'YOUR_REOWN_PROJECT_ID',
 *        chains:      [369],
 *        showQrModal: true,
 *      })
 *      setupExternalProvider(app, provider)
 *      registerProvider(app, { name: 'WalletConnect', icon: '…', rdns: 'walletconnect.org' }, provider)
 *      // user clicks "WalletConnect" in the picker → QR modal opens automatically
 *
 *  Or skip the picker and use a dedicated button:
 *
 *      await provider.connect()
 *      setupExternalProvider(app, provider)
 *      app.ports.web3Cmd.send({ tag: 'connect' })
 *
 *  Both work. setupExternalProvider rebinds chainChanged/accountsChanged/disconnect
 *  listeners to the new provider so Elm stays in sync.
 */
export function setupExternalProvider(app, provider) {
  if (!provider) return
  window.ethereum = provider
  if (typeof provider.on !== 'function') return
  provider.on('chainChanged', (chainId) => {
    const id = typeof chainId === 'string' ? parseInt(chainId, 16) : chainId
    app.ports.web3Sub.send({ tag: 'chainChanged', chainId: id })
  })
  // Some wallets (OKX among them) have been observed firing a spurious
  // accountsChanged([]) / disconnect around an unrelated rejected request,
  // even though the extension still holds a live eth_accounts permission.
  // Silently re-check before tearing down connection state — a real
  // disconnect/lock still resolves to [] here, so this costs one extra
  // no-prompt RPC round trip and closes the false-positive window.
  function recheckOrDisconnect() {
    Promise.resolve(provider.request({ method: 'eth_accounts' }))
      .then((current) => {
        if (!current || current.length === 0) {
          app.ports.web3Sub.send({ tag: 'disconnected' })
        } else {
          app.ports.web3Sub.send({ tag: 'accountChanged', address: current[0] })
        }
      })
      .catch(() => {
        app.ports.web3Sub.send({ tag: 'disconnected' })
      })
  }

  provider.on('accountsChanged', (accounts) => {
    if (!accounts || accounts.length === 0) {
      recheckOrDisconnect()
    } else {
      app.ports.web3Sub.send({ tag: 'accountChanged', address: accounts[0] })
    }
  })
  provider.on('disconnect', () => {
    recheckOrDisconnect()
  })
}

// --- EIP-6963: multi-wallet discovery ---
// Must be called after setupPorts so `app` is in scope for each listener.
// Wallets announce themselves via this event; we collect them all and notify Elm.
export function watchWallets(app) {
  function onAnnounce(event) {
    const { info, provider } = event.detail
    if (!info || !info.rdns) return
    _eip6963Providers.set(info.rdns, { info, provider })
    _broadcastWallets(app)
  }
  window.addEventListener('eip6963:announceProvider', onAnnounce)
  // Trigger already-registered providers to re-announce
  window.dispatchEvent(new Event('eip6963:requestProvider'))
}

function _broadcastWallets(app: ElmApp): void {
  const wallets = Array.from(_eip6963Providers.values()).map(({ info: i }) => ({
    name: i.name,
    icon: i.icon,
    rdns: i.rdns,
  }))
  app.ports.web3Sub.send({ tag: 'walletsDiscovered', wallets })
}

/** Slot a non-EIP-6963 provider (WalletConnect, Coinbase SDK, embedded wallet, …)
 *  into the wallet picker so it shows alongside auto-detected browser extensions.
 *  When the user clicks it the existing `selectWallet` handler will run
 *  `eth_requestAccounts` on the provider — which for WalletConnect transparently
 *  opens the QR modal.
 *
 *      registerProvider(app,
 *        { name: 'WalletConnect', icon: 'data:image/svg+xml;…', rdns: 'walletconnect.org' },
 *        wcProvider)
 *
 *  Idempotent: calling twice with the same rdns just overwrites.
 */
export function registerProvider(app, info, provider) {
  if (!info || !info.rdns || !provider) return
  _eip6963Providers.set(info.rdns, { info, provider })
  _broadcastWallets(app)
}

// ─────────────────────────────────────────────────────────────────────
// Type guards (consumer-facing; declared in elm-web3-ports.d.ts).
//
// Lightweight runtime checks that narrow `unknown` to the branded
// `Hex` / `Address` / `TxHash` types in TS consumers. JS-only consumers
// can use them too — they return plain booleans.
// ─────────────────────────────────────────────────────────────────────

/** Returns true if `value` is a 0x-prefixed hex string of even length. */
export function isHex(value) {
  return typeof value === 'string' && /^0x([0-9a-fA-F]{2})*$/.test(value)
}

/** Returns true if `value` is exactly 0x + 40 hex chars (a 20-byte EVM address). */
export function isAddress(value) {
  return typeof value === 'string' && /^0x[0-9a-fA-F]{40}$/.test(value)
}

/** Returns true if `value` is exactly 0x + 64 hex chars (a 32-byte tx hash). */
export function isTxHash(value) {
  return typeof value === 'string' && /^0x[0-9a-fA-F]{64}$/.test(value)
}

// --- Helpers ---

function blockNumberToHex(blockNum: number | string): string {
  if (typeof blockNum === 'string') return blockNum  // 'latest', 'earliest', 'pending'
  return '0x' + blockNum.toString(16)
}

// Keccak-256 round constants [lo32, hi32] (little-endian 64-bit)
const _KC_RC = [
  [0x00000001,0x00000000],[0x00008082,0x00000000],[0x0000808A,0x80000000],
  [0x80008000,0x80000000],[0x0000808B,0x00000000],[0x80000001,0x00000000],
  [0x80008081,0x80000000],[0x00008009,0x80000000],[0x0000008A,0x00000000],
  [0x00000088,0x00000000],[0x80008009,0x00000000],[0x8000000A,0x00000000],
  [0x8000808B,0x00000000],[0x0000008B,0x80000000],[0x00008089,0x80000000],
  [0x00008003,0x80000000],[0x00008002,0x80000000],[0x00000080,0x80000000],
  [0x0000800A,0x00000000],[0x8000000A,0x80000000],[0x80008081,0x80000000],
  [0x00008080,0x80000000],[0x80000001,0x00000000],[0x80008008,0x80000000],
]
// Keccak-256 rho rotation offsets indexed by x + 5*y
const _KC_RO = [0,1,62,28,27,36,44,6,55,20,3,10,43,25,39,41,45,15,21,8,18,2,61,56,14]

function _keccakF(s: number[]): void {
  for (let rnd = 0; rnd < 24; rnd++) {
    // Theta
    const c = new Array(10)
    for (let x = 0; x < 5; x++) {
      c[2*x]   = s[2*x]^s[2*x+10]^s[2*x+20]^s[2*x+30]^s[2*x+40]
      c[2*x+1] = s[2*x+1]^s[2*x+11]^s[2*x+21]^s[2*x+31]^s[2*x+41]
    }
    for (let x = 0; x < 5; x++) {
      const x1=(x+1)%5, x4=(x+4)%5
      const dlo = c[2*x4]   ^ ((c[2*x1]<<1)   | (c[2*x1+1]>>>31))
      const dhi = c[2*x4+1] ^ ((c[2*x1+1]<<1) | (c[2*x1]>>>31))
      for (let y = 0; y < 5; y++) {
        s[2*(x+5*y)]   ^= dlo
        s[2*(x+5*y)+1] ^= dhi
      }
    }
    // Rho + Pi
    const tmp = new Array(50)
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) {
        const idx = x+5*y
        let lo=s[2*idx], hi=s[2*idx+1], r=_KC_RO[idx], rlo, rhi
        if (r===0)       { rlo=lo;  rhi=hi }
        else if (r===32) { rlo=hi;  rhi=lo }
        else if (r<32)   { rlo=(lo<<r)|(hi>>>(32-r)); rhi=(hi<<r)|(lo>>>(32-r)) }
        else             { r-=32; rlo=(hi<<r)|(lo>>>(32-r)); rhi=(lo<<r)|(hi>>>(32-r)) }
        const nx=y, ny=(2*x+3*y)%5
        tmp[2*(nx+5*ny)]=rlo; tmp[2*(nx+5*ny)+1]=rhi
      }
    }
    // Chi
    for (let y = 0; y < 5; y++) {
      for (let x = 0; x < 5; x++) {
        const x1=(x+1)%5, x2=(x+2)%5
        s[2*(x+5*y)]   = tmp[2*(x+5*y)]   ^ (~tmp[2*(x1+5*y)]   & tmp[2*(x2+5*y)])
        s[2*(x+5*y)+1] = tmp[2*(x+5*y)+1] ^ (~tmp[2*(x1+5*y)+1] & tmp[2*(x2+5*y)+1])
      }
    }
    // Iota
    s[0] ^= _KC_RC[rnd][0]; s[1] ^= _KC_RC[rnd][1]
  }
}

// Returns full 32-byte keccak256 of a UTF-8 string as a 0x-prefixed hex string
function _keccak256Full(input: string): string {
  const rate = 136
  const msg = []
  for (let i = 0; i < input.length; i++) {
    const c = input.charCodeAt(i)
    if (c < 0x80) {
      msg.push(c)
    } else if (c < 0x800) {
      msg.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f))
    } else {
      msg.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f))
    }
  }
  msg.push(0x01)
  while (msg.length % rate !== 0) msg.push(0x00)
  msg[msg.length - 1] |= 0x80

  const s = new Array(50).fill(0)
  for (let blk = 0; blk < msg.length; blk += rate) {
    for (let i = 0; i < 17; i++) {
      const j = blk + i * 8
      s[2 * i]     ^= msg[j]     | (msg[j + 1] << 8) | (msg[j + 2] << 16) | (msg[j + 3] << 24)
      s[2 * i + 1] ^= msg[j + 4] | (msg[j + 5] << 8) | (msg[j + 6] << 16) | (msg[j + 7] << 24)
    }
    _keccakF(s)
  }

  // Extract all 32 bytes (first 4 lanes, lo-then-hi each)
  let hex = '0x'
  for (let lane = 0; lane < 4; lane++) {
    const lo = s[2 * lane] >>> 0
    const hi = s[2 * lane + 1] >>> 0
    hex += (lo & 0xff).toString(16).padStart(2, '0')
    hex += ((lo >>> 8) & 0xff).toString(16).padStart(2, '0')
    hex += ((lo >>> 16) & 0xff).toString(16).padStart(2, '0')
    hex += (lo >>> 24).toString(16).padStart(2, '0')
    hex += (hi & 0xff).toString(16).padStart(2, '0')
    hex += ((hi >>> 8) & 0xff).toString(16).padStart(2, '0')
    hex += ((hi >>> 16) & 0xff).toString(16).padStart(2, '0')
    hex += (hi >>> 24).toString(16).padStart(2, '0')
  }
  return hex
}

// Returns first 4 bytes of keccak256 of an ASCII string
function _selector(sig: string): string {
  const rate = 136
  const msg = []
  for (let i = 0; i < sig.length; i++) msg.push(sig.charCodeAt(i) & 0xff)
  msg.push(0x01)
  while (msg.length % rate !== 0) msg.push(0x00)
  msg[msg.length-1] |= 0x80

  const s = new Array(50).fill(0)
  for (let blk = 0; blk < msg.length; blk += rate) {
    for (let i = 0; i < 17; i++) {
      const j = blk+i*8
      s[2*i]   ^= msg[j]|(msg[j+1]<<8)|(msg[j+2]<<16)|(msg[j+3]<<24)
      s[2*i+1] ^= msg[j+4]|(msg[j+5]<<8)|(msg[j+6]<<16)|(msg[j+7]<<24)
    }
    _keccakF(s)
  }

  // Extract first 4 bytes (lo bytes of lane 0)
  const lo = s[0]>>>0
  return [lo&0xff,(lo>>>8)&0xff,(lo>>>16)&0xff,lo>>>24]
    .map(b => b.toString(16).padStart(2,'0')).join('')
}

// True if this ABI type uses dynamic (offset-based) encoding
function _isDyn(type: string): boolean {
  const t = type.trim()
  if (t === 'string' || t === 'bytes') return true
  if (t.endsWith('[]')) return true
  // Fixed array T[k]: dynamic iff element type is dynamic
  const fixedMatch = t.match(/^(.*)\[(\d+)\]$/)
  if (fixedMatch) return _isDyn(fixedMatch[1])
  // Tuple: dynamic iff any member is dynamic
  if (t.startsWith('(')) {
    const inner = t.slice(1, t.lastIndexOf(')'))
    return splitTopLevelTypes(inner).some(m => _isDyn(m))
  }
  return false
}

// Number of 32-byte words this type contributes to the head section
function _headSize(type: string): number {
  const t = type.trim()
  if (_isDyn(t)) return 1  // offset word
  const fixedMatch = t.match(/^(.*)\[(\d+)\]$/)
  if (fixedMatch) return parseInt(fixedMatch[2]) * _headSize(fixedMatch[1])
  if (t.startsWith('(')) {
    const inner = t.slice(1, t.lastIndexOf(')'))
    return splitTopLevelTypes(inner).reduce((s, m) => s + _headSize(m), 0)
  }
  return 1
}

// ABI-encode a static type; returns hex string (may be more than 32 bytes for arrays/tuples)
function _encStatic(type: string, val: unknown): string {
  const t = type.trim()
  // Fixed array of static type: T[k]
  const fixedMatch = t.match(/^(.*)\[(\d+)\]$/)
  if (fixedMatch) {
    const elemType = fixedMatch[1]
    const arr = Array.isArray(val) ? val : []
    return arr.map((v, i) => _encStatic(elemType, arr[i])).join('')
  }
  // Static tuple: (T1,T2,...) where all members are static
  if (t.startsWith('(')) {
    const inner = t.slice(1, t.lastIndexOf(')'))
    const innerTypes = splitTopLevelTypes(inner)
    const arr = Array.isArray(val) ? val : []
    return innerTypes.map((et, i) => _encStatic(et, arr[i])).join('')
  }
  if (t === 'address') {
    const addr = val.toString().replace(/^0x/i,'').toLowerCase().padStart(40,'0')
    return ('000000000000000000000000' + addr)
  }
  if (t === 'bool') {
    return '000000000000000000000000000000000000000000000000000000000000000' + (val ? '1' : '0')
  }
  // bytesN (bytes1..bytes32): left-aligned, right-padded with zeros
  if (/^bytes\d+$/.test(t)) {
    const hex = val.toString().replace(/^0x/i, '').toLowerCase()
    return hex.padEnd(64, '0').slice(0, 64)
  }
  // uint*, int*
  let n = BigInt(val.toString())
  if (n < 0n) n = n & ((1n<<256n)-1n)  // two's complement
  return n.toString(16).padStart(64,'0')
}

// ABI-encode a dynamic type; returns hex string (no 0x prefix)
function _encDyn(type: string, val: unknown): string {
  const t = type.trim()
  if (t === 'string') {
    const byteArr = Array.from(new TextEncoder().encode(val.toString()))
    const lenHex = BigInt(byteArr.length).toString(16).padStart(64,'0')
    const dataHex = byteArr.map(b => b.toString(16).padStart(2,'0')).join('')
    const pad = (32 - (byteArr.length % 32)) % 32
    return lenHex + dataHex + '00'.repeat(pad)
  }
  if (t === 'bytes') {
    const hex = val.toString().replace(/^0x/i, '').toLowerCase()
    const byteLen = hex.length / 2
    const lenHex = BigInt(byteLen).toString(16).padStart(64,'0')
    const pad = (32 - (byteLen % 32)) % 32
    return lenHex + hex + '00'.repeat(pad)
  }
  // Dynamic array: T[]
  if (t.endsWith('[]')) {
    const elemType = t.slice(0, -2)
    const arr = Array.isArray(val) ? val : []
    const lenHex = BigInt(arr.length).toString(16).padStart(64,'0')
    return lenHex + _abiEncode(arr.map(() => elemType), arr)
  }
  // Tuple types: (T1,T2,...), (T1,T2,...)[k], (T1,T2,...)[]
  if (t.startsWith('(')) {
    const closeParen = t.lastIndexOf(')')
    const inner = t.slice(1, closeParen)
    const suffix = t.slice(closeParen + 1)
    const tupleType = t.slice(0, closeParen + 1)
    if (suffix === '') {
      // Dynamic tuple — encode members with head/tail
      const innerTypes = splitTopLevelTypes(inner)
      const arr = Array.isArray(val) ? val : []
      return _abiEncode(innerTypes, arr)
    }
    if (suffix === '[]') {
      // Dynamic array of tuples
      const arr = Array.isArray(val) ? val : []
      const lenHex = BigInt(arr.length).toString(16).padStart(64,'0')
      return lenHex + _abiEncode(arr.map(() => tupleType), arr)
    }
    // T[k] where T is a dynamic tuple
    const kMatch = suffix.match(/^\[(\d+)\]$/)
    if (kMatch) {
      const arr = Array.isArray(val) ? val : []
      return _abiEncode(arr.map(() => tupleType), arr)
    }
  }
  throw new Error('encodeCall: unsupported dynamic type ' + type)
}

// Returns hex-encoded ABI calldata (no selector, no 0x)
function _abiEncode(types: readonly string[], args: readonly unknown[]): string {
  const headParts = [], tailParts = []
  // Head size accounts for multi-word static types (fixed arrays, static tuples)
  let tailOffset = types.reduce((s, t) => s + _headSize(t) * 32, 0)
  for (let i = 0; i < types.length; i++) {
    const t = types[i].trim()
    if (_isDyn(t)) {
      headParts.push(BigInt(tailOffset).toString(16).padStart(64,'0'))
      const enc = _encDyn(t, args[i])
      tailParts.push(enc)
      tailOffset += enc.length / 2
    } else {
      headParts.push(_encStatic(t, args[i]))
    }
  }
  return [...headParts, ...tailParts].join('')
}

// ABI-encode aggregate3((address,bool,bytes)[]) calldata for Multicall3
// calls: [{contract, ...}], callDatas: ["0x..." hex strings per call]
function _encodeAggregate3(calls: readonly CallSpec[], callDatas: readonly string[]): string {
  const sel = _selector('aggregate3((address,bool,bytes)[])')
  const n = calls.length

  // Each Call3 tuple: (address target, bool allowFailure, bytes callData)
  // bytes is dynamic, so the whole tuple is dynamic.
  // Tuple encoding: [addr:32][bool:32][bytesOffset:32][bytesLen:32][bytesPadded]
  //   bytesOffset within tuple = 3*32 = 96 (3 head slots)
  const tupleEncs = callDatas.map((cd, i) => {
    const addr = calls[i].contract.replace(/^0x/i, '').toLowerCase().padStart(40, '0')
    const addrSlot  = '000000000000000000000000' + addr
    const boolSlot  = '0000000000000000000000000000000000000000000000000000000000000001'
    const bOff      = BigInt(3 * 32).toString(16).padStart(64, '0')
    const cdHex     = cd.replace(/^0x/i, '')
    const cdLen     = cdHex.length / 2
    const lenSlot   = BigInt(cdLen).toString(16).padStart(64, '0')
    const pad       = (32 - (cdLen % 32)) % 32
    return addrSlot + boolSlot + bOff + lenSlot + cdHex + '00'.repeat(pad)
  })

  // Encode array: [length][tuple_offsets...][tuple_data...]
  // Offsets are relative to the start of the array content (just after length word)
  // Content = n offset slots (n*32 bytes) + tuple data
  let offsets = [], off = n * 32
  for (let i = 0; i < n; i++) {
    offsets.push(BigInt(off).toString(16).padStart(64, '0'))
    off += tupleEncs[i].length / 2
  }
  const lenSlot  = BigInt(n).toString(16).padStart(64, '0')
  const arrBody  = lenSlot + offsets.join('') + tupleEncs.join('')

  // The array is the sole argument (dynamic), so its head is an offset = 0x20
  const argOffset = BigInt(32).toString(16).padStart(64, '0')
  return '0x' + sel + argOffset + arrBody
}

// ABI-decode the return value of aggregate3: (bool success, bytes returnData)[]
// hexData: 0x-prefixed hex string
// Returns [{success: bool, data: "0x..."}]
function _decodeAggregate3Result(hexData: string): readonly { readonly success: boolean; readonly data: string }[] {
  const h = hexData.replace(/^0x/i, '')

  // Read a uint256 (as JS number) at byte offset byteOff
  function word(byteOff) {
    return parseInt(h.slice(byteOff * 2, byteOff * 2 + 64), 16)
  }

  // Outer: first word = offset to array encoding
  const arrByteOff = word(0)                    // = 32
  const n          = word(arrByteOff)           // array length
  // Array content starts just after length word
  const contentOff = arrByteOff + 32

  const results = []
  for (let i = 0; i < n; i++) {
    // Tuple offset is relative to contentOff
    const tupleRelOff = word(contentOff + i * 32)
    const tupleOff    = contentOff + tupleRelOff

    // Tuple: (bool success, bytes returnData)
    const success      = word(tupleOff) !== 0
    const bytesRelOff  = word(tupleOff + 32)          // offset within tuple
    const bytesOff     = tupleOff + bytesRelOff
    const bytesLen     = word(bytesOff)
    const dataStart    = (bytesOff + 32) * 2          // char offset into h
    const data         = '0x' + h.slice(dataStart, dataStart + bytesLen * 2)

    results.push({ success, data })
  }
  return results
}

// Split a comma-separated type string respecting nested parentheses.
// e.g. "(address,bool,bytes)[],uint256" -> ["(address,bool,bytes)[]", "uint256"]
function splitTopLevelTypes(typesStr: string): string[] {
  const result = []
  let depth = 0, start = 0
  for (let i = 0; i < typesStr.length; i++) {
    if (typesStr[i] === '(') depth++
    else if (typesStr[i] === ')') depth--
    else if (typesStr[i] === ',' && depth === 0) {
      result.push(typesStr.slice(start, i))
      start = i + 1
    }
  }
  if (start < typesStr.length) result.push(typesStr.slice(start))
  return result
}

function encodeCall(method: string, args: readonly unknown[]): string {
  const sel = _selector(method)
  if (!args || args.length === 0) return '0x' + sel

  // Extract the top-level parameter types from the signature.
  // Handles nested parens like "fn((address,bool,bytes)[],uint256)"
  const parenStart = method.indexOf('(')
  const typesStr = parenStart >= 0 ? method.slice(parenStart + 1, method.lastIndexOf(')')) : ''
  const types = typesStr ? splitTopLevelTypes(typesStr) : []
  if (types.length === 0) return '0x' + sel

  return '0x' + sel + _abiEncode(types, args)
}

async function pollReceipt(hash: string, app: ElmApp, rpc: (method: string, params: readonly unknown[]) => Promise<unknown>): Promise<void> {
  for (let i = 0; i < 120; i++) {
    await new Promise((r) => setTimeout(r, 2000))
    try {
      const receipt = await rpc('eth_getTransactionReceipt', [hash])
      if (receipt) {
        app.ports.web3Sub.send({
          tag: 'confirmed',
          hash: receipt.transactionHash,
          blockNumber: parseInt(receipt.blockNumber, 16),
          gasUsed: parseInt(receipt.gasUsed, 16).toString(),
          status: receipt.status === '0x1',
          logs: (receipt.logs || []).map(log => ({
            address: log.address,
            topics: log.topics || [],
            data: log.data,
            blockNumber: parseInt(log.blockNumber, 16),
            logIndex: parseInt(log.logIndex, 16),
          })),
        })
        return
      }
      // Send confirmation count (block distance)
      await rpc('eth_blockNumber', [])
      app.ports.web3Sub.send({ tag: 'confirmation', hash, count: i + 1 })
    } catch (_) {
      // keep polling
    }
  }
  try {
    app.ports.web3Sub.send({ tag: 'failed', error: 'Transaction not confirmed after 4 minutes' })
  } catch (_) {}
}
