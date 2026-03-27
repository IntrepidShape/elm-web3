# Changelog

## 2.0.1 — 2026-03-27

### Changes

- Removed unused `elm/http` and `elm/time` from `dependencies`. Neither was imported
  by any of the 19 source modules; their presence was carry-over from an earlier draft.
  No API changes — this is a pure dependency cleanup.

---

## 2.0.0 — 2026-03-27

### New modules

- `Web3.Balance` — native ETH/PLS balance queries with correlation IDs (`getBalance`, `encode`, `decoder`)
- `Web3.Block` — block number queries, block data fetching, block number watching, transaction count per block (`getBlockNumber`, `getBlock`, `watchBlockNumber`, `getBlockTransactionCount`)
- `Web3.Fee` — gas price (eth_gasPrice) and EIP-1559 fee history queries (`getGasPrice`, `getFeeHistory`, `FeeHistory`)
- `Web3.Query` — on-chain read queries: nonce, storage slot, contract bytecode, transaction lookup (`getTxCount`, `getStorageAt`, `getCode`, `getTransaction`, `TransactionInfo`)
- `Web3.Units` — pure-Elm ETH/ERC-20 unit conversion, no port required (`formatEther`, `parseEther`, `formatUnits`, `parseUnits`)
- `Web3.Crypto` — keccak256 hashing via port (`keccak256`, `encode`, `decoder`)

### New in existing modules

- `Web3.Types.encodeBlockNumber` — shared `BlockNumber -> E.Value` encoder used by Block, Fee, and Call modules
- `Web3.BigInt.decoder` — JSON decoder for BigInt from a decimal string
- `Web3.BigInt.fromHexString` — parse a 0x-prefixed hex string as a non-negative BigInt
- `Web3.BigInt.fromIntString` — alias for `fromString` (API symmetry with `fromHexString`)
- `Web3.BigInt.mod` — remainder operation returning `Maybe BigInt`
- `Web3.Transaction.TxCmd` — command type for requesting receipts (`RequestReceipt TxHash String`)
- `Web3.Transaction.encodeCmd` — encode a `TxCmd` for the JS port
- `Web3.Transaction.transactionConfirmations` — compute confirmation count given current block number
- `Web3.Transaction.Msg.TxReset` — reset a terminal transaction back to `Idle`
- `Web3.Transaction.Msg.TxReceiptNotFound` — receipt polling no-op (schedule retry in app)
- `Web3.Contract.Call.withFrom` — set a `from` address on a read call (simulates a write without broadcasting)
- `Web3.Contract.Send.deployCall` — encode a contract deployment for the port
- `Web3.Contract.Send.encodeRawSend` — broadcast a pre-signed raw transaction
- `Web3.Contract.Send.WriteCall` — the write call type is now exported
- `Web3.Contract.Send.payableCall`, `writeCall`, `withGasLimit`, `encode`, `estimateGas` — all now fully documented
- `Web3.Contract.Event.EventLog` — now includes `contract`, `topics` fields (breaking change; see below)
- `Web3.Wallet.ChainConfig` — configuration record for EIP-3085 `wallet_addEthereumChain`
- `Web3.Wallet.startConnect` — transition wallet state to `Connecting` before sending the connect port command
- `Web3.Wallet.watchAsset` — EIP-747: add a token to the wallet UI
- `Web3.Wallet.requestPermissions` / `getPermissions` — EIP-2255 wallet permissions
- `Web3.Wallet.isReadOnly` — true when in `ReadOnly` mode (rpcUrl set, no wallet)
- `Web3.Wallet.addChain` — EIP-3085: add a new chain to the wallet
- `Web3.Wallet.State.ReadOnly` — new wallet state for rpcUrl-only connections
- `Web3.Sign.SignState` / `SignMsg` — signing state machine types are now exposed
- `Web3.Sign.startSign`, `signUpdate`, `isSignTerminal` — signing lifecycle helpers
- `Web3.Sign.personalSign` — personal_sign (EIP-191)
- `Web3.Chain` — added: `arbitrum`, `avalanche`, `base`, `bsc`, `fantom`, `gnosis`, `linea`, `optimism`, `polygon`, `scroll`, `zksync`
- `Web3.Abi.Decode` — added: `uint8`, `uint16`, `uint32`, `uint64`, `uint128`, `hexSlot`, `uint256Slot`, `addressSlot`, `boolSlot`, `stringSlot`, `listSlot`, `tuple2Hex`, `tuple3Hex`
- `Web3.Abi.Encode` — added: `bytesN`, `list`, `tuple2`, `tuple3`
- `Web3` (top-level) — added `encodeTxCmd`; `Msg` now includes `TxCmdMsg`

### Breaking changes

- `Web3.Contract.Event.EventLog` — added `contract : Address` and `topics : List String` fields. Update all patterns matching this record.
- `Web3.Transaction.Msg` — added `TxReset` and `TxReceiptNotFound` variants. Update all `case` expressions on `Msg`.
- `Web3.Wallet.Msg` — added `ReadOnlyMode`, `ChainAdded`, `SwitchChainOk`, `AssetWatched`, `GotPermissions` variants. Update all `case` expressions on `Msg`.
- `Web3.Wallet.State` — added `ReadOnly` variant. Update all `case` expressions on `State`.
- `Web3.Wallet.WalletCmd` — added `RequestAddChain`, `RequestWatchAsset`, `RequestPermissions`, `GetPermissions` variants. Update all `case` expressions on `WalletCmd`.
- `Web3.Wallet.getBalance` removed — use `Web3.Balance.getBalance` instead.
- `Web3.Wallet.balanceDecoder` removed — use `Web3.Balance.decoder` instead.
- `Web3.Msg` — added `TxCmdMsg` variant. Update all `case` expressions on `Web3.Msg`.

---

## 1.0.0 — 2026-03-26

Initial release.

- `Web3.Types` — opaque Address, TxHash, ChainId, Wei types with validation
- `Web3.Wallet` — EIP-6963 multi-wallet discovery, connection state machine
- `Web3.Transaction` — transaction lifecycle state machine with revert reason decoding
- `Web3.Contract.Call` — typed read-only contract calls
- `Web3.Contract.Send` — typed write calls, payable calls, gas estimation
- `Web3.Contract.Event` — event subscriptions and historical log queries
- `Web3.Multicall` — batch reads via Multicall3
- `Web3.Sign` — EIP-712 typed data signing
- `Web3.Chain` — Ethereum, PulseChain, Sepolia, and custom chain definitions
- `Web3.BigInt` — arbitrary-precision integers, zero dependencies, base-10^7 digit representation
- `Web3.Abi.Encode` / `Web3.Abi.Decode` — ABI parameter helpers
- JS port bridge (`js/elm-web3-ports.js`) — ~500 lines, zero dependencies
- ABI-to-Elm code generator (`codegen/`)
- Formal verification: TLA+ state machine specs, Lean 4 type soundness proofs
