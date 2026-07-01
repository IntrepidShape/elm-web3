# Formal Verification Coverage

What is proved, what is not, and why.

---

## What is fully proved

### Lean 4 — type soundness

| Property | File | Theorems |
|----------|------|----------|
| `Address` constructor never wraps invalid strings | `lean/Address.lean` | `mkAddress_sound`, `mkAddress_none_iff_invalid` |
| `Address` string representation is injective | `lean/Address.lean` | `addressToString_injective` |
| `Address` roundtrip: re-validation of a valid address always succeeds | `lean/Address.lean` | `mkAddress_addressToString_roundtrip` |
| `Address` structural invariants: length=42, starts "0x", lowercase hex body | `lean/Address.lean` | `address_length`, `address_startsWith0x`, `address_hex_body` |
| Same four properties for `TxHash` (length=66, body=64) | `lean/TxHash.lean` | parallel theorems |
| `HexString` soundness, completeness, injectivity, roundtrip | `lean/HexString.lean` | `mkHexString_sound`, `mkHexString_none_iff_invalid`, `mkHexString_some_iff`, `hexStringToString_injective`, `mkHexString_hexStringToString_roundtrip` |
| `HexString` structural invariants: starts "0x", hex body, non-empty, length ≥ 2 | `lean/HexString.lean` | `hexString_startsWith0x`, `hexString_hex_body`, `hexString_nonempty`, `hexString_length_ge_2` |
| `bytes32` decoder: soundness, completeness, injectivity, roundtrip | `lean/AbiCodec.lean` | `mkBytes32_sound`, `mkBytes32_none_iff`, `mkBytes32_some_iff`, `bytes32_injective`, `mkBytes32_roundtrip` |
| `address` ABI codec roundtrip | `lean/AbiCodec.lean` | `address_codec_roundtrip` |
| `WalletCmd` encode/decode is an isomorphism | `lean/WalletCodec.lean` | `decode_encode_roundtrip`, `encode_injective`, `encode_decode_partial_inverse` |
| `natNormalize` preserves value | `lean/BigInt.lean` | `natNormalize_val` |
| `natAddCarry` is correct | `lean/BigInt.lean` | `natAddCarry_val` |
| `natAdd`, `natMulSmall`, `natAddSmall` are correct | `lean/BigInt.lean` | `natAdd_val`, `natMulSmall_val`, `natAddSmall_val` |
| `shiftLeft` multiplies by base^n | `lean/BigInt.lean` | `shiftLeft_val` |
| `natSub` is correct under ≥ precondition | `lean/BigInt.lean` | `natSubBorrow_val`, `natSub_val` |
| `parseUnsigned` accumulation step is correct | `lean/BigInt.lean` | `parseUnsigned_step` |
| `hexDigitVal` produces values in [0, 15] | `lean/RevertReason.lean` | `hexDigitVal_range` |
| `hexToInt` is definitionally correct | `lean/RevertReason.lean` | `hexToInt_correct` |
| `hexToBytes` decoded bytes are in [0, 255] | `lean/RevertReason.lean` | `hexToBytes_range`, `hexBytePair_val` |
| UTF-8 ASCII decoding is correct | `lean/RevertReason.lean` | `utf8_ascii_correct` |
| `decodeRevertReason` wrong selector → Nothing | `lean/RevertReason.lean` | `decodeRevertReason_wrong_selector` |
| `decodeRevertReason` short payload → Nothing | `lean/RevertReason.lean` | `decodeRevertReason_too_short` |

### TLA+ — state machine invariants (model-checked by TLC)

Verified with TLC (tla2tools 1.7.4 / TLC 2.19, Java 21). Reproduce with
`proofs/tla/check-tla.sh` (or `java -jar tla2tools.jar -deadlock -config
<spec>.cfg <spec>.tla`). `-deadlock` is intentional — these machines have
genuine terminal sink states (`Confirmed`, `Signed`, …).

| Property | File |
|----------|------|
| Wallet: `Connected`/`WrongChain` always carry address+chain | `tla/WalletSpec.tla` |
| Wallet: `Disconnected`/`Error` never carry address | `tla/WalletSpec.tla` |
| Wallet: `Disconnected` is always eventually reachable (no deadlock) — under weak fairness on `UserDisconnect` | `tla/WalletSpec.tla` |
| Wallet: `Connected` only transitions through the expected set of states | `tla/WalletSpec.tla` |
| Transaction: no **port message** transitions a terminal state; the only exit is an explicit user retry to `Idle` | `tla/TransactionSpec.tla` |
| Transaction: `Submitted` only reachable from `AwaitingSignature` | `tla/TransactionSpec.tla` |
| Transaction: `Confirming` always carries a valid hash | `tla/TransactionSpec.tla` |
| Transaction: confirmation count is monotonically non-decreasing | `tla/TransactionSpec.tla` |
| Transaction: every pending transaction eventually reaches a terminal state | `tla/TransactionSpec.tla` |
| Sign: terminal states are absorbing (`TerminalAbsorbing`) | `tla/SignSpec.tla` |
| Sign: every terminal state was entered from `SignPending` (`TerminalFromPending`) | `tla/SignSpec.tla` |
| Sign: a message for a different correlation id never completes the pending sign (`NoCrossRequestConfusion`) | `tla/SignSpec.tla` |
| Sign: `SignPending ⇒ ◇` terminal (liveness, under fairness) | `tla/SignSpec.tla` |

> **Correction (this pass).** These specs were previously listed as
> model-checked but had **never actually been run through TLC** — they did not
> parse (a `----` divider before `EXTENDS`; and `[]`-of-bare-action temporal
> properties). Fixing the syntax and running TLC surfaced three real defects,
> now fixed and re-verified:
> 1. `TerminalIsTerminal` was stated as "terminal states *never* transition
>    out", but the spec's own `UserRetry` resets `Failed`/`Rejected → Idle`.
>    Corrected to "no port message moves a terminal state; only a user retry to
>    `Idle` does."
> 2. `WalletSpec` mixed integer chain ids with the string `NONE` sentinel, so
>    TLC aborted comparing `"NONE"` with `369`. Modelled chain ids as strings
>    (only equality is ever used).
> 3. `NoDeadlock` (always-eventually-`Disconnected`) did **not** hold under
>    `WF(Next)` alone — the wallet could churn in `Connected` forever. It holds
>    once `UserDisconnect` is given weak fairness (its intended meaning).
>
> The `SignSpec` safety properties are *also* **Property-tested** in
> `tests/SignFuzzTest.elm`.

### Manual — JS port layer

- `JS_PORT_PROOF.md`: exhaustive case analysis of all 11 command handlers showing no exception escapes the boundary and every failure path sends a typed response.

### Elm fuzz — property-tested runtime behaviour

These are `elm-explorations/test` fuzz properties that the Elm test runner
actually checks on every run (100 cases each by default). They verify runtime
behaviour, not type soundness, so they are graded **Property-tested**, not
Proved.

| Property | File | Test |
|----------|------|------|
| `Multicall.encode` preserves the batch id and every call (contract, method, args) in order | `tests/MulticallTest.elm` | "envelope preserves id and every call in order" |
| `Multicall.responseDecoder` preserves every result — order, `success`, and `data` intact (aggregation preserves per-call decode correctness) | `tests/MulticallTest.elm` | "decodes every result, in order, success+data intact", "result count is preserved" |
| `BigInt` `add`/`mul` commutative & associative; `mul` distributes over `add` (multi-limb values) | `tests/BigIntLawsTest.elm` | "commutativity", "associativity", "distributivity" |
| `BigInt.compare` agrees with integer order and is monotone under addition | `tests/BigIntLawsTest.elm` | "compare" |
| `BigInt` division algorithm: `a = (a/b)*b + (a mod b)`, `0 ≤ a mod b < b`, div/mod by zero → `Nothing` | `tests/BigIntLawsTest.elm` | "division algorithm" |
| `Abi.Calldata` output shape: `0x` + selector + lowercase-hex body that is always 32-byte-word aligned | `tests/CalldataFuzzTest.elm` | "universal shape" |
| `Abi.Calldata` static `uint256` round-trip: each head word decodes back to its input (`decode ∘ encode = id`, multi-limb) | `tests/CalldataFuzzTest.elm` | "static uint256 round-trip" |
| `Abi.Calldata` dynamic head/tail offset correctness: offsets 32-aligned, start at head size, strictly increasing, in bounds; length word + content intact | `tests/CalldataFuzzTest.elm` | "dynamic string head/tail offsets" |
| `Units` general round-trip: `parseUnits d (formatUnits d n) = Just n` for any decimals `d∈[0,30]` and multi-limb `n` (exact, no precision loss) | `tests/UnitsFuzzTest.elm` | "parseUnits d (formatUnits d n) == Just n" |
| `Units` ether/general agreement: `formatEther = formatUnits 18`; `parseEther` round-trips at ether scale; digits past `d` truncated | `tests/UnitsFuzzTest.elm` | "ether functions == decimals=18 general functions", "…ether scale (multi-limb)", "digits past d are ignored" |
| `Sign` EIP-191 vs EIP-712 non-confusion: `encode`→`signTypedData`, `personalSign`→`personalSign` — distinct tags, exact id/from/message | `tests/SignFuzzTest.elm` | "EIP-191 vs EIP-712 non-confusion" |
| `Sign` state machine safety: terminal states absorbing under any message stream; a response for a different id never transitions a pending sign; `SignIdle` never becomes pending/signed from messages alone | `tests/SignFuzzTest.elm` | "state machine safety" |

> The `tests/` suite also carries additional fuzz modules (`AbiFuzzTest`,
> `BigIntFuzzTest`, `TransactionFuzzTest`, `WalletFuzzTest`, plus the fuzz
> sections of `TypesTest` and `UnitsTest`). They are exercised by the runner but
> are not yet individually catalogued here; this table grows one verified entry
> at a time.

---

## Remaining proof obligations (with sorry, proof sketches provided)

These theorems are stated with correct types and documented proof strategies.
The sorry markers are temporary scaffolding — each has a complete proof sketch.
They are **not** counted as Proved. Several of them (`natMul_val`,
`natCompare_spec`, `natDivMod_spec`) now have a **Property-tested** backstop in
`tests/BigIntLawsTest.elm` — fuzzed on multi-limb values — which is machine-
verified evidence, though weaker than a proof.

| Property | File | Proof strategy | Est. lines |
|----------|------|---------------|------------|
| `natMul_val`: `natVal (natMul a b) = natVal a * natVal b` | `lean/BigInt.lean` | Induction on `a`; head term + shifted tail; indexedMap/foldl coordination | ~40 |
| `natCompare_spec`: compare reflects numeric order | `lean/BigInt.lean` | Length → value range lemmas + big-endian lexicographic induction | ~80 |
| `natDivMod_spec`: satisfies division algorithm property | `lean/BigInt.lean` | `findQd_spec` (binary search) + step invariant + termination | ~150 |
| `fromString_toString_roundtrip`: round-trip isomorphism | `lean/BigInt.lean` | Decimal string encoding/decoding correspondence via `parseUnsigned_step` | ~200 |
| `uint256_codec_roundtrip` | `lean/AbiCodec.lean` | Delegates to `fromString_toString_roundtrip` | ~5 |
| `decodeRevertReason_correct`: full correctness for well-formed payload | `lean/RevertReason.lean` | String take/drop arithmetic + chain hexToInt + hexToBytes + utf8 lemmas | ~100 |
| `BigInt` overflow safety invariant | `lean/BigInt.lean` | Propagate range bounds through mulSmallCarry; `digit * k + carry ≤ (10^7-1)^2 + (10^7-1) < 2^53` | ~100 |

---

## Known limitations of existing proofs

1. **TLA+ is finite-model checked, not proof-verified.** The model checker explores all reachable states within the given constants (2 addresses, 2 chains, 3 confirmation depth). Properties hold for those parameters; they hold generally by the construction of the state machine, but this is not mechanically proved.

2. **Lean proofs model a simplified `toLowerHex`** that only maps `A–F → a–f`. The Elm runtime's `String.toLower` is broader (full Unicode case folding). In practice all addresses are ASCII hex, so this does not matter, but it is a gap between the model and the implementation.

3. **JS port findings (F1–F7) from `JS_PORT_PROOF.md` are not fixed.** `watchEvent` is a stub; `switchChain` sends no success response; error tag naming is inconsistent. These are documented, not remediated.

4. **JSON layer axiomatized.** The `jsonString_roundtrip` axiom in `AbiCodec.lean` asserts that Elm's `E.string`/`D.string` round-trips. This is a contractual property of the Elm JSON library that cannot be verified in Lean without embedding Elm's semantics.

5. **UTF-8 multi-byte sequences.** `utf8_ascii_correct` proves the ASCII case. The 2-, 3-, and 4-byte UTF-8 sequences follow the same structural pattern but are not separately stated as theorems in `RevertReason.lean`.

---

## How to check the proofs

```bash
# Lean 4
cd proofs/lean
lean Address.lean        # no output = clean
lean TxHash.lean
lean HexString.lean
lean WalletCodec.lean
lean BigInt.lean
lean AbiCodec.lean
lean RevertReason.lean

# TLA+ (requires Java + tla2tools.jar; JDK 11+, verified on corretto-21)
cd proofs/tla
./check-tla.sh                 # model-checks every *.tla with its *.cfg
# or individually (note -deadlock: terminal sink states are intended):
java -jar tla2tools.jar -deadlock -config WalletSpec.cfg      WalletSpec.tla
java -jar tla2tools.jar -deadlock -config TransactionSpec.cfg TransactionSpec.tla
java -jar tla2tools.jar -deadlock -config SignSpec.cfg        SignSpec.tla
```
