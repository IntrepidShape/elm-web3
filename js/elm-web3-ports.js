/**
 * elm-web3-ports.js
 *
 * The entire JS layer. ~100 lines. Uses window.ethereum directly.
 * No viem, no wagmi, no ethers. Just raw JSON-RPC through the
 * wallet provider.
 *
 * Usage:
 *   import { setupPorts } from 'elm-web3/js/elm-web3-ports.js'
 *   const app = Elm.Main.init({ node: ... })
 *   setupPorts(app, { rpcUrl: 'https://rpc.example.com' })  // rpcUrl optional
 */

// EIP-6963: map of rdns -> { info, provider } for discovered wallets
const _eip6963Providers = new Map()

export function setupPorts(app, { rpcUrl } = {}) {
  // Route read-only JSON-RPC calls: prefer rpcUrl over window.ethereum
  let _rpcId = 0
  async function _rpcRequest(method, params) {
    if (rpcUrl) {
      const res = await fetch(rpcUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: ++_rpcId, method, params }),
      })
      const json = await res.json()
      if (json.error) throw new Error(json.error.message || JSON.stringify(json.error))
      return json.result
    }
    if (!window.ethereum) throw new Error('No wallet found')
    return window.ethereum.request({ method, params })
  }

  // Notify Elm of read-only mode when rpcUrl is present but no wallet is available
  if (rpcUrl) {
    setTimeout(() => {
      if (!window.ethereum) app.ports.web3Sub.send({ tag: 'readOnly' })
    }, 0)
  }

  // --- Wallet ---

  app.ports.web3Cmd.subscribe(async (cmd) => {
    try {
      switch (cmd.tag) {
        case 'connect': {
          if (!window.ethereum && rpcUrl) {
            app.ports.web3Sub.send({ tag: 'readOnly' })
            return
          }
          if (!window.ethereum) throw new Error('No wallet found')
          const accounts = await window.ethereum.request({ method: 'eth_requestAccounts' })
          if (!accounts || accounts.length === 0) throw new Error('Wallet returned no accounts')
          const chainId = await window.ethereum.request({ method: 'eth_chainId' })
          app.ports.web3Sub.send({
            tag: 'connected',
            address: accounts[0],
            chainId: parseInt(chainId, 16),
          })
          break
        }

        case 'disconnect':
          app.ports.web3Sub.send({ tag: 'disconnected' })
          break

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

        // --- Event watching (4s poll) ---
        case 'watchEvent': {
          const startHex = await _rpcRequest('eth_blockNumber', [])
          let fromBlock = parseInt(startHex, 16)
          setInterval(async () => {
            try {
              const toHex = await _rpcRequest('eth_blockNumber', [])
              const toBlock = parseInt(toHex, 16)
              if (toBlock < fromBlock) return
              const filter = { address: cmd.contract, fromBlock: '0x' + fromBlock.toString(16), toBlock: toHex }
              if (cmd.topics?.length) filter.topics = cmd.topics
              const logs = await _rpcRequest('eth_getLogs', [filter])
              for (const log of logs) {
                app.ports.web3Sub.send({
                  tag: 'eventLog',
                  contract: cmd.contract,
                  data: log.data,
                  topics: log.topics || [],
                  blockNumber: parseInt(log.blockNumber, 16),
                  txHash: log.transactionHash,
                  logIndex: parseInt(log.logIndex, 16),
                })
              }
              fromBlock = toBlock + 1
            } catch (_) {}
          }, 4000)
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
          // Re-request providers and connect to the one matching rdns
          const { rdns } = cmd
          const found = _eip6963Providers.get(rdns)
          if (!found) throw new Error(`Wallet not found: ${rdns}`)
          const accounts = await found.provider.request({ method: 'eth_requestAccounts' })
          const chainId = await found.provider.request({ method: 'eth_chainId' })
          // Swap the active provider so all subsequent calls use the selected wallet
          window.ethereum = found.provider
          app.ports.web3Sub.send({
            tag: 'connected',
            address: accounts[0],
            chainId: parseInt(chainId, 16),
          })
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
          pollBlock()
          setInterval(pollBlock, 4000)
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
        const msg = { tag: 'failed', error: err.message || String(err) }
        // EIP-3668 / execution revert: include raw revert data so Elm can decode it
        const data = err.data || (err.error && err.error.data)
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
          app.ports.web3Sub.send({ tag: 'disconnected' })
        } else {
          app.ports.web3Sub.send({ tag: 'accountChanged', address: accounts[0] })
        }
      } catch (_) {}
    })
  }
}

/** Swap in any EIP-1193 provider (e.g. WalletConnect) before calling connect.
 *  elm-web3 carries no WalletConnect dependency — you bring your own. */
export function setupExternalProvider(provider) {
  window.ethereum = provider
}

// --- EIP-6963: multi-wallet discovery ---
// Must be called after setupPorts so `app` is in scope for each listener.
// Wallets announce themselves via this event; we collect them all and notify Elm.
export function watchWallets(app) {
  function onAnnounce(event) {
    const { info, provider } = event.detail
    if (!info || !info.rdns) return
    _eip6963Providers.set(info.rdns, { info, provider })
    const wallets = Array.from(_eip6963Providers.values()).map(({ info: i }) => ({
      name: i.name,
      icon: i.icon,
      rdns: i.rdns,
    }))
    app.ports.web3Sub.send({ tag: 'walletsDiscovered', wallets })
  }
  window.addEventListener('eip6963:announceProvider', onAnnounce)
  // Trigger already-registered providers to re-announce
  window.dispatchEvent(new Event('eip6963:requestProvider'))
}

// --- Helpers ---

function blockNumberToHex(blockNum) {
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

function _keccakF(s) {
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
function _keccak256Full(input) {
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
function _selector(sig) {
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
function _isDyn(type) {
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
function _headSize(type) {
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
function _encStatic(type, val) {
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
function _encDyn(type, val) {
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
function _abiEncode(types, args) {
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
function _encodeAggregate3(calls, callDatas) {
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
function _decodeAggregate3Result(hexData) {
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
function splitTopLevelTypes(typesStr) {
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

function encodeCall(method, args) {
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

async function pollReceipt(hash, app, rpc) {
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
