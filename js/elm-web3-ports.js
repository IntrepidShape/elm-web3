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
 *   setupPorts(app)
 */

// EIP-6963: map of rdns -> { info, provider } for discovered wallets
const _eip6963Providers = new Map()

export function setupPorts(app) {
  // --- Wallet ---

  app.ports.web3Cmd.subscribe(async (cmd) => {
    try {
      switch (cmd.tag) {
        case 'connect': {
          if (!window.ethereum) {
            app.ports.web3Sub.send({ tag: 'error', message: 'No wallet found' })
            return
          }
          const accounts = await window.ethereum.request({ method: 'eth_requestAccounts' })
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
          const hex = '0x' + cmd.chainId.toString(16)
          await window.ethereum.request({
            method: 'wallet_switchEthereumChain',
            params: [{ chainId: hex }],
          })
          break
        }

        // --- Contract reads ---
        case 'call': {
          const result = await window.ethereum.request({
            method: 'eth_call',
            params: [
              {
                to: cmd.contract,
                data: encodeCall(cmd.method, cmd.args),
              },
              cmd.block || 'latest',
            ],
          })
          app.ports.web3Sub.send({ tag: 'callResult', id: cmd.id, data: result })
          break
        }

        // --- Gas estimation ---
        case 'estimateGas': {
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
          pollReceipt(hash, app)
          break
        }

        // --- Multicall3 batch reads ---
        case 'multicall': {
          const MULTICALL3 = '0xcA11bde05977b3631167028862bE2a173976CA11'
          const callDatas = cmd.calls.map(c => encodeCall(c.method, c.args))
          const data = _encodeAggregate3(cmd.calls, callDatas)
          const raw = await window.ethereum.request({
            method: 'eth_call',
            params: [{ to: MULTICALL3, data }, 'latest'],
          })
          const results = _decodeAggregate3Result(raw)
          app.ports.web3Sub.send({ tag: 'multicallResult', id: cmd.id, results })
          break
        }

        // --- Event watching ---
        case 'watchEvent': {
          // Use eth_subscribe if available, fall back to polling
          // For now: polling every 4s
          // Production: use websocket subscription
          break
        }

        // --- EIP-712 typed signing ---
        case 'signTypedData': {
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
          if (!found) {
            app.ports.web3Sub.send({ tag: 'error', message: `Wallet not found: ${rdns}` })
            return
          }
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
          const logs = await window.ethereum.request({
            method: 'eth_getLogs',
            params: [filter],
          })
          const processedLogs = logs.map(log => ({
            data: log.data,
            blockNumber: parseInt(log.blockNumber, 16),
            txHash: log.transactionHash,
            logIndex: parseInt(log.logIndex, 16),
          }))
          app.ports.web3Sub.send({ tag: 'logs', logs: processedLogs })
          break
        }
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
      app.ports.web3Sub.send({ tag: 'chainChanged', chainId: parseInt(chainId, 16) })
    })
    window.ethereum.on('accountsChanged', (accounts) => {
      if (accounts.length === 0) {
        app.ports.web3Sub.send({ tag: 'disconnected' })
      } else {
        app.ports.web3Sub.send({ tag: 'accountChanged', address: accounts[0] })
      }
    })
  }
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

// ABI-encode a static type to 32 bytes
function _encStatic(type, val) {
  if (type === 'address') {
    const addr = val.toString().replace(/^0x/i,'').toLowerCase().padStart(40,'0')
    return ('000000000000000000000000' + addr)
  }
  if (type === 'bool') {
    return '000000000000000000000000000000000000000000000000000000000000000' + (val ? '1' : '0')
  }
  // uint*, int*
  let n = BigInt(val.toString())
  if (n < 0n) n = n & ((1n<<256n)-1n)  // two's complement
  return n.toString(16).padStart(64,'0')
}

// ABI-encode a dynamic type; returns hex string (no 0x prefix)
function _encDyn(type, val) {
  if (type === 'string' || type === 'bytes') {
    const bytes = Array.from(new TextEncoder().encode(val.toString()))
    const lenHex = BigInt(bytes.length).toString(16).padStart(64,'0')
    const dataHex = bytes.map(b => b.toString(16).padStart(2,'0')).join('')
    const pad = (32 - (bytes.length % 32)) % 32
    return lenHex + dataHex + '00'.repeat(pad)
  }
  throw new Error('encodeCall: unsupported dynamic type ' + type)
}

function _isDyn(type) { return type==='string' || type==='bytes' || type.includes('[') }

// Returns hex-encoded ABI calldata (no selector, no 0x)
function _abiEncode(types, args) {
  const headParts = [], tailParts = []
  let tailOffset = types.length * 32
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

async function pollReceipt(hash, app) {
  for (let i = 0; i < 120; i++) {
    await new Promise((r) => setTimeout(r, 2000))
    try {
      const receipt = await window.ethereum.request({
        method: 'eth_getTransactionReceipt',
        params: [hash],
      })
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
      const block = await window.ethereum.request({ method: 'eth_blockNumber' })
      app.ports.web3Sub.send({ tag: 'confirmation', hash, count: i + 1 })
    } catch (_) {
      // keep polling
    }
  }
  app.ports.web3Sub.send({ tag: 'failed', error: 'Transaction not confirmed after 4 minutes' })
}
