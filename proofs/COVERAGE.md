# Formal Verification Coverage

What is proved, what is not, and why.

Companion documents:
- `TLA_CONFORMANCE.md` — action-by-action audit that the TLA+ specs model the
  actual Elm `update` functions (with divergence log).
- `EVM_API_COVERAGE.md` — which EIPs / JSON-RPC methods the library covers,
  which it deliberately does not, and the ranked remaining gaps.

---

## What is fully proved

### Lean 4 — machine-check status (Lean 4.31.0, pinned in `lean/lean-toolchain`)

> **Correction (2026-07-02).** The first local Lean run ever performed on this
> repo found that only THREE of the ten proof files actually check:
> `Address.lean`, `TxHash.lean`, `HexString.lean`. The other seven were
> authored but never machine-checked in any environment (86 errors under the
> pinned toolchain — stdlib drift and tactic-state mismatches). Their rows
> have been downgraded from **Proved** to **Authored — does not currently
> check (under repair)** below, exactly as the prime directive requires.
> Rows are promoted back one file at a time as `lean <file>` exits clean.

#### Proved — `lean` exits 0 on the pinned toolchain

| Property | File | Theorems |
|----------|------|----------|
| `Address` constructor never wraps invalid strings | `lean/Address.lean` | `mkAddress_sound`, `mkAddress_none_iff_invalid` |
| `Address` string representation is injective | `lean/Address.lean` | `addressToString_injective` |
| `Address` roundtrip: re-validation of a valid address always succeeds | `lean/Address.lean` | `mkAddress_addressToString_roundtrip` |
| `Address` structural invariants: length=42, starts "0x", lowercase hex body | `lean/Address.lean` | `address_length`, `address_startsWith0x`, `address_hex_body` |
| Same four properties for `TxHash` (length=66, body=64) | `lean/TxHash.lean` | parallel theorems |
| `HexString` soundness, completeness, injectivity, roundtrip | `lean/HexString.lean` | `mkHexString_sound`, `mkHexString_none_iff_invalid`, `mkHexString_some_iff`, `hexStringToString_injective`, `mkHexString_hexStringToString_roundtrip` |
| `HexString` structural invariants: starts "0x", hex body, non-empty, length ≥ 2 | `lean/HexString.lean` | `hexString_startsWith0x`, `hexString_hex_body`, `hexString_nonempty`, `hexString_length_ge_2` |


#### Verified 2026-07-02 — repaired to the pinned toolchain, `lean` exits 0

All ten files now machine-check (the seven broken ones were repaired without
weakening any surviving statement — fix classes in git history). The rows
below returned to **Proved** the moment the checker agreed:

| Property | File | Theorems |
|----------|------|----------|
| `bytes32` decoder: soundness, completeness, injectivity, roundtrip | `lean/AbiCodec.lean` | `mkBytes32_sound`, `mkBytes32_none_iff`, `mkBytes32_some_iff`, `bytes32_injective`, `mkBytes32_roundtrip` |
| `address` ABI codec roundtrip | `lean/AbiCodec.lean` | `address_codec_roundtrip` |
| `WalletCmd` encode/decode is an isomorphism | `lean/WalletCodec.lean` | `decode_encode_roundtrip`, `encode_injective`, `encode_decode_partial_inverse` |
| `natNormalize` preserves value | `lean/BigInt.lean` | `natNormalize_val` |
| `natAddCarry` is correct | `lean/BigInt.lean` | `natAddCarry_val` |
| `natAdd`, `natMulSmall`, `natAddSmall` are correct | `lean/BigInt.lean` | `natAdd_val`, `natMulSmall_val`, `natAddSmall_val` |
| `shiftLeft` multiplies by base^n | `lean/BigInt.lean` | `shiftLeft_val` |
| `parseUnsigned` accumulation step is correct | `lean/BigInt.lean` | `parseUnsigned_step` |
| `hexDigitVal` produces values in [0, 15] | `lean/RevertReason.lean` | `hexDigitVal_range` |
| `hexToInt` is definitionally correct | `lean/RevertReason.lean` | `hexToInt_correct` |
| `hexToBytes` decoded bytes are in [0, 255] | `lean/RevertReason.lean` | `hexToBytes_range`, `hexBytePair_val` |
| UTF-8 ASCII decoding is correct | `lean/RevertReason.lean` | `utf8_ascii_correct` |

| `natSubBorrow_val` / `natSub_val` — subtraction correct for valid digit lists under `≥` | `lean/BigInt.lean` | PROVED 2026-07-02 (restated with digit-validity; structural-induction proof) |
| `natMul_val` — multiplication correct (`zipIdx` formulation) | `lean/BigInt.lean` | PROVED 2026-07-02 (offset/accumulator-generalizing aux lemma) |

#### FALSE as originally stated — now RESTATED truthfully (2026-07-02)

All three false claims have been restated with faithful hypotheses. The two
revert-decoder guards are **proved** under the restatement (conditional-strip
hypotheses matching the model exactly — `decodeRevertReason_wrong_selector`,
`decodeRevertReason_too_short`, plus the new `natVal_nonneg`). The BigInt
subtraction pair is restated with digit-validity hypotheses (statement now
true) with the proof pending as a documented `sorry`. Original false forms
below, for the record:

The repair run proved three original claims **false as written** (a fourth,
`natSub_val`, only elaborated by citing one of them). They are quarantined in
comments inside the files pending faithful restatement — a false claim does
not get repaired into a different claim silently:

| Original claim | File | Why it is false |
|----------|------|----------|
| `natSubBorrow_val` / `natSub_val` — subtraction correct under `≥` | `lean/BigInt.lean` | The statement admits invalid digit lists: `a=[]`, `b=[-5]` satisfies `0 ≥ -5`, yet LHS `0` ≠ RHS `5`. Needs a digit-validity hypothesis. The Elm code never builds invalid digit lists — the *model's statement* was wrong, not the library. |
| `decodeRevertReason` wrong selector → Nothing | `lean/RevertReason.lean` | Hypothesis strips two chars unconditionally; the model (and the Elm) strip only when `0x`-prefixed. An unprefixed valid payload satisfies the hypothesis and still decodes. |
| `decodeRevertReason` short payload → Nothing | `lean/RevertReason.lean` | Same unconditional-strip mismatch, via the length check. |

Restating and reproving these with faithful hypotheses is tracked work.

### TLA+ — state machine invariants (model-checked by TLC)

Verified with TLC (tla2tools 1.7.4 / TLC 2.19, Java 21). Reproduce with
`proofs/tla/check-tla.sh`. TLC's deadlock check is ON for Wallet and
Transaction (no sink states); it is disabled only for Sign, whose terminal
states are genuine sinks (the Elm Sign machine has no reset).

**Spec ↔ code conformance is audited action-by-action in
`proofs/TLA_CONFORMANCE.md`** — every Elm `update` case arm is mapped to a TLA
action. The 2026-07-02 audit found and resolved 9 divergences, including 3
real Elm bugs (see the divergence log there and `CHANGELOG.md`).

| Property | File |
|----------|------|
| Wallet: `Connected`/`WrongChain` always carry address+chain | `tla/WalletSpec.tla` |
| Wallet: `Disconnected`/`Error`/`ReadOnly` never carry an address | `tla/WalletSpec.tla` |
| Wallet: every session eventually returns to a resting state (`Disconnected` or `ReadOnly`), under weak fairness on `UserDisconnect` (`EventuallyAtRest`) | `tla/WalletSpec.tla` |
| Wallet: `Connected` only exits to `WrongChain`/`Disconnected`/`Error` (`ConnectedStability`) | `tla/WalletSpec.tla` |
| Wallet: `ReadOnly` only exits via a `WalletConnected` announcement (`ReadOnlySticky`) | `tla/WalletSpec.tla` |
| Transaction: no **port message** transitions a terminal state; the only exit is the explicit `TxReset` to `Idle` (from any terminal, incl. `Confirmed`) | `tla/TransactionSpec.tla` |
| Transaction: `Submitted` only reachable from `AwaitingSignature` | `tla/TransactionSpec.tla` |
| Transaction: `Confirming` always carries a valid hash | `tla/TransactionSpec.tla` |
| Transaction: confirmation count strictly increases while `Confirming` (action property; also enforced in the Elm code) | `tla/TransactionSpec.tla` |
| Transaction: every pending transaction eventually reaches a terminal state | `tla/TransactionSpec.tla` |
| Sign: terminal states are absorbing (`TerminalAbsorbing`) | `tla/SignSpec.tla` |
| Sign: every terminal state was entered from `SignPending` (`TerminalFromPending`) | `tla/SignSpec.tla` |
| Sign: a message for a different correlation id never completes the pending sign (`NoCrossRequestConfusion`) | `tla/SignSpec.tla` |
| Sign: `SignPending ⇒ ◇` terminal (liveness, under fairness) | `tla/SignSpec.tla` |

Not checked, deliberately: `WrongChainCanResolve` (would require assuming the
user eventually fixes their chain — see the comment in `WalletSpec.tla`).

> **Corrections log.** (1) These specs were once listed as model-checked but
> had never parsed under TLC (fixed, then TLC surfaced real defects — see git
> history). (2) A prior claim `[]<>(state = "Disconnected")` was **false** for
> the real machine — `ReadOnly` has no disconnect path in the Elm code; the
> claim was weakened to `EventuallyAtRest`, which is true and checked.
> (3) `ConnectedStability` was previously listed here while absent from the
> `.cfg` — i.e., claimed but never evaluated. It is now checked (and only
> became true after the `ReadOnlyMode` session-teardown bug was fixed in the
> Elm). Full details: `proofs/TLA_CONFORMANCE.md`.
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

## Remaining proof obligations

| Item | Status |
|------|--------|
| `natCompare_spec` | Restated 2026-07-02 over valid **normalized** inputs (the checker refuted the original: `natCompare [5,0] [5] = .gt` with equal values — length-first comparison vs trailing zeros; Elm lists are canonical by construction). Proof pending (`sorry`). |
| `natDivMod_spec`, `fromString_toString_roundtrip` | **Not yet stated**: the model file carries `True := trivial` placeholders where these theorems belong. Stating them faithfully (then proving) is the work — previously this table implied they were stated-and-pending, which overstated. |
| `decodeRevertReason_correct` | Stated; proof pending. |
| `uint256_codec_roundtrip` | Blocked on a real (non-placeholder) BigInt string model inside AbiCodec. |
| BigInt overflow-safety | Never stated in the model (previously listed here as pending — corrected). |

Every entry above has an Elm fuzz backstop in `tests/` — the statements hold
under machine-checked property testing; the Lean proofs are the outstanding
stronger evidence.

## Known limitations of existing proofs

0. **A machine-checked proof is only as good as its constants (1.2.2
   lesson).** `decodeRevertReason` shipped comparing against selector
   `08c379a2` — a typo; the real `Error(string)` selector is `08c379a0`
   (keccak256-derived). The Lean theorems in `RevertReason.lean` were
   *correct proofs about the wrong constant*: every guard property held,
   relative to a selector that never occurs on chain, so no real revert
   reason ever decoded. Caught by rendering a canonical solc payload in the
   elm-web3-ui gallery; fixed in code + proofs, and pinned by real-world
   vectors in `tests/AbiDecodeHexTest.elm`. Moral: proofs verify internal
   consistency — external constants need oracle tests against reality.

1. **TLA+ is finite-model checked, not proof-verified.** The model checker explores all reachable states within the given constants (2 addresses, 2 chains, 3 confirmation depth). Properties hold for those parameters; they hold generally by the construction of the state machine, but this is not mechanically proved.

2. **Lean proofs model a simplified `toLowerHex`** that only maps `A–F → a–f`,
   while Elm's `String.toLower` performs full Unicode folding. **Decision
   (2026-07-02, explicit):** keep the simplified model, documented. The two
   functions agree on every string the validators accept (`0x` + hex digits —
   pure ASCII), and the validator runs *before* lowering, so no input on which
   they differ can reach the modeled code path. Strengthening the model to
   full Unicode folding would add large modeling surface to protect against
   inputs that are already rejected. Revisit only if validation order ever
   changes.

3. **JS port findings (F1–F7) from `JS_PORT_PROOF.md` are not fixed.** `watchEvent` is a stub; `switchChain` sends no success response; error tag naming is inconsistent. These are documented, not remediated.

4. **JSON layer axiomatized.** The `jsonString_roundtrip` axiom in `AbiCodec.lean` asserts that Elm's `E.string`/`D.string` round-trips. This is a contractual property of the Elm JSON library that cannot be verified in Lean without embedding Elm's semantics.

5. **UTF-8 multi-byte sequences.** `utf8_ascii_correct` proves the ASCII case. The 2-, 3-, and 4-byte UTF-8 sequences follow the same structural pattern but are not separately stated as theorems in `RevertReason.lean`.

---

## How to check the proofs

```bash
# Lean 4 (toolchain pinned in proofs/lean/lean-toolchain; install via elan)
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
# or individually (-deadlock ONLY for SignSpec — its terminal states are
# genuine sinks; Wallet/Transaction get the full deadlock check):
java -jar tla2tools.jar           -config WalletSpec.cfg      WalletSpec.tla
java -jar tla2tools.jar           -config TransactionSpec.cfg TransactionSpec.tla
java -jar tla2tools.jar -deadlock -config SignSpec.cfg        SignSpec.tla
```
