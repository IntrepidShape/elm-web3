# Discourse Post — Show and Tell

**Category:** Show and Tell
**Title:** intrepidshape/elm-web3 — type-safe EVM interaction for Elm

---

I've published `intrepidshape/elm-web3`, a package for interacting with EVM blockchains from Elm.

The core idea: wallet connection, transaction lifecycle, and contract calls are all modelled as explicit state machines. The `Wallet.State` and `Transaction.Status` types make invalid states unrepresentable, so the compiler enforces that your UI handles every case — no silent failures, no blank screens from an unhandled null.

**What's included:**
- Opaque validated types (`Address`, `TxHash`, `ChainId`, `BigInt`) — you can't accidentally pass a `TxHash` where an `Address` is expected
- Wallet state machine with EIP-6963 multi-wallet discovery
- Transaction lifecycle from `AwaitingSignature` through `Confirmed` with revert reason decoding
- Typed contract reads/writes, gas estimation, multicall batching, EIP-712 signing
- ABI code generator from Foundry/Hardhat JSON

**Dependencies:** only `elm/core`, `elm/json`, `elm/http`, `elm/time`. The JS port bridge (~500 lines) has zero npm dependencies — no ethers, no viem, just `window.ethereum`.

I've also included Lean 4 proofs for core type invariants (soundness, injectivity, roundtrip) and TLA+ model-checked specs for the state machines. Some of the harder arithmetic proofs are stated with sketches rather than fully closed — honest about that.

`elm install intrepidshape/elm-web3`

Feedback welcome, especially from anyone who's worked with `cmditch/elm-ethereum`.
