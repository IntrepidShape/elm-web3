# Changelog

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
