# Agent Task — Iteratively harden elm-web3's formal-methods coverage & library quality

**Scope: the `elm-web3` stack only** (this repo — `intrepidshape/elm-web3`, published v1.2.0 on the
official Elm registry). Do **not** touch `elm-web3-ui` (early-stage; out of scope).

You are an autonomous engineering agent. Run the **iteration loop** below N times (default 5). Each
pass must leave the repo strictly better *and* still green. Small, verified, committed increments.

---

## Why this matters (read first)

elm-web3's entire differentiation is **applied formal methods you can trust**: Lean 4 proofs
(`proofs/lean/`) + TLC-model-checked TLA+ state machines (`proofs/tla/`), with a published,
honest coverage doc (`proofs/COVERAGE.md`). The value is not "we have proofs" — it's that the
coverage doc is **exactly true**.

### PRIME DIRECTIVE — honesty of the coverage claim
Grade every invariant precisely and never inflate it:
- **Proved** — a Lean proof that actually checks.
- **Model-checked** — a TLA+ property TLC actually verified (bounded).
- **Property-tested** — an Elm fuzz test (`elm-explorations/test`).
- **Unit-tested** — a concrete example test.
- **Unverified** — a claim with none of the above.

A proof authored but not yet machine-checked is **Unverified** until it checks. **A proof of a false
statement is worse than no proof** — if an invariant doesn't hold, that is a valuable finding: record
it, fix the code or the claim, do not paper over it. `COVERAGE.md` must match reality after every pass.

---

## Repo map
- `src/Web3.elm`, `src/Web3/*.elm` (24 modules): Types, Wallet, Transaction, Sign, BigInt, Units,
  Chain, Balance, Fee, Query, Block, Subscription, Multicall, Crypto, `Abi/{Encode,Decode,Calldata}`,
  `Contract/{Call,Send,Event}`.
- `proofs/lean/*.lean` — Address, TxHash, HexString, WalletCodec, AbiCodec, SignState, TxCmd, Units,
  BigInt, RevertReason.
- `proofs/tla/*.tla` + `*.cfg` — `WalletSpec`, `TransactionSpec`.
- `proofs/COVERAGE.md` — the source-of-truth coverage doc. `proofs/JS_PORT_PROOF.md` — port boundary.
- `tests/*.elm` — 14 test modules (Abi, BigInt, Wallet, Sign, Units, Crypto, Calldata, …).
- `CHANGELOG.md`, `elm.json`, `codegen/`, `ralph-wiggum.sh` (inspect — likely the existing check runner).

---

## The iteration loop (repeat N times)

1. **Assess.** Read `proofs/COVERAGE.md` and diff it against `proofs/lean/`, `proofs/tla/`, `tests/`,
   and `src/`. Find the single **highest-value gap**: a core safety invariant that's claimed-but-not-
   proved, an important module with no formal/property coverage, or a coverage-doc line that overstates
   reality.
2. **Pick ONE gap** (smallest change with the biggest correctness payoff).
3. **Do the work:**
   - Codec / opaque-type invariant (Address, TxHash, HexString, BigInt, Abi, Units) → add/extend a
     **Lean proof**: round-trip (`parse ∘ render = id` on valid; `render ∘ parse = Some` shapes),
     injectivity, and impossibility-of-invalid-construction.
   - State machine (Wallet, Transaction, Sign) → extend the **TLA+ spec + `.cfg`** with a new safety
     invariant or temporal/liveness property and model-check it.
   - Runtime behavior → add an **Elm fuzz/property test**.
4. **Verify it actually checks** (see Verification). If it doesn't check, it does not count as Proved/
   Model-checked — mark it Unverified/pending.
5. **Update `COVERAGE.md` precisely** + add a `CHANGELOG.md` entry.
6. **Confirm the library still builds and all tests pass**, and that the **public API is unchanged**
   (v1.2.0 is live — additive/internal/proof/test/doc changes only; never break exposed signatures
   without an explicit version bump).
7. **Commit** with a clear message (`proofs: prove Address round-trip in Lean` etc.). Return to step 1.

---

## Verification (discover the toolchain, then run)
- **Elm typecheck:** `elm make src/Web3.elm --output=/dev/null` (Bun-only environment — no npm).
- **Elm tests:** discover how they run (check `elm.json`, `package.json`, `ralph-wiggum.sh`); typically
  `elm-test` / `elm-explorations/test`.
- **Lean:** detect a `lakefile`/`lean`/`lake` toolchain. If present, `lake build` (or `lean <file>`).
  **If Lean is not installed here, still author correct proofs but mark them "authored, pending check"
  — do NOT promote them to Proved in `COVERAGE.md` until a machine actually checks them.**
- **TLA+:** TLC via `java -jar tla2tools.jar -config <X>.cfg <X>.tla`. If TLC/Java is unavailable,
  extend the spec and mark the new property **pending** (not Model-checked).
- Environment notes: `/tmp` is `noexec` (set `TMPDIR=~/.cache/...` for anything that extracts+execs);
  no GHC assumed. Detect, don't assume.

---

## Starting backlog (prioritised — pick from the top)
1. **Address / TxHash / HexString:** `parse ∘ render = id`; `render` always yields a re-parseable
   string; no construction of an invalid address (0x + exact hex length). *(Lean)*
2. **BigInt:** hex round-trip; arithmetic correctness (assoc/comm/identity); no float, no silent
   overflow. *(Lean + Elm fuzz)*
3. **Abi Encode/Decode:** `decode ∘ encode = id` per solidity type; head/tail offset correctness for
   dynamic types; static vs dynamic boundary. *(Lean for the codec algebra + Elm fuzz for round-trip)*
4. **Units:** wei/gwei/ether conversions are exact (no precision loss) and round-trip. *(Lean)*
5. **Wallet state machine:** cannot send a tx from `Disconnected`; `WrongChain` is handled; cannot read
   balance on the wrong chain; liveness `Connecting ⇒ ◇(Connected ∨ Error)`. *(TLA+)*
6. **Transaction state machine:** transitions only `Idle→Pending→(Confirmed|Failed)`; terminal states
   absorbing; no double-submit. *(TLA+)*
7. **Sign state:** an EIP signature type is never confused (191 vs 712 vs raw). *(TLA+ / Lean)*
8. **Multicall / Calldata:** aggregation preserves per-call decode correctness. *(Elm fuzz)*

---

## Guardrails
- **Honesty over impressiveness** — the coverage doc is the product. Downgrade any claim you can't
  machine-verify. (This is the whole brand.)
- **Do not break the published API.** Proof/test/doc/internal changes only unless explicitly bumping.
- **Elm-first, Bun-only.** No npm, no reaching for non-Elm solutions where Elm reaches.
- **One small verified increment per pass**, each committed. No giant unreviewable diffs.
- **elm-web3-ui is out of scope.**

## Definition of done (per pass)
One new or strengthened, **actually-verified** coverage item · `COVERAGE.md` + `CHANGELOG.md` updated
truthfully · Elm build + tests green · public API intact · committed.

## Final output (after N passes)
Summarise: what was added, before/after coverage counts by grade (Proved / Model-checked / Tested),
any invariants found **not** to hold (with the fix), and the next-highest-value gaps remaining.
