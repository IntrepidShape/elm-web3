# Contributing to elm-web3

Thanks for your interest. This package has one differentiator: **applied
formal methods you can trust**. Contributions are judged first on whether
they keep that true.

## The prime directive — coverage honesty

`proofs/COVERAGE.md` grades every claim precisely:

- **Proved** — a Lean proof that actually machine-checks.
- **Model-checked** — a TLA+ property TLC actually verified (bounded).
- **Property-tested** — an Elm fuzz test the runner actually executes.
- **Unit-tested** — a concrete example test.
- **Unverified** — anything else, stated as such.

A proof authored but not machine-checked is **Unverified**. A proof of a
false statement is worse than no proof. If you find an invariant that does
not hold, that is a *valuable finding* — file it or fix it; never paper over
it. PRs that inflate a grade will be declined regardless of code quality.

## Development setup

```bash
# Elm 0.19.1 (the only compiler this supports)
elm make src/Web3.elm --output=/dev/null   # typecheck
elm make --docs=/tmp/docs.json             # docs must build (publish gate)
npx --yes elm-test                         # 445+ tests; elm-test is a Node CLI

# TLA+ model checking (Java 11+, tla2tools.jar)
curl -sSL -o ~/.local/share/tla/tla2tools.jar \
  https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar
./proofs/tla/check-tla.sh                  # all specs must pass

# Lean 4 proofs (optional locally; needed to touch proofs/lean/)
# lake/lean toolchain — see proofs/COVERAGE.md "How to check the proofs"
```

CI runs the elm job and the TLC job on every PR. Both must be green.

## Ground rules

1. **Never break the published API** without an explicit MAJOR bump
   discussion in an issue first. `elm bump` is the arbiter, not opinion.
2. **State machines change in lockstep.** If you touch
   `Wallet.update` / `Transaction.update` / `Sign.signUpdate`, update the
   matching spec in `proofs/tla/`, re-run `check-tla.sh`, and update the
   action mapping in `proofs/TLA_CONFORMANCE.md`. A spec that models a
   machine the code no longer implements is a bug.
3. **New codecs/invariants ship with evidence** — a fuzz property at
   minimum; a Lean proof where the codec algebra allows it.
4. **Update `proofs/COVERAGE.md` and `CHANGELOG.md`** in the same PR as the
   change they describe.
5. **Scope:** dapp-relevant EVM surface. Check
   `proofs/EVM_API_COVERAGE.md` before proposing an addition — the gaps
   list there is the wanted-features list; the "skip" list has reasoning
   that a PR must rebut to overturn.

## Good first contributions

The ranked gap lists are the roadmap:

- `proofs/EVM_API_COVERAGE.md` → e.g. `eth_maxPriorityFeePerGas`,
  custom-error revert decoding, `personal_ecRecover`.
- `proofs/COVERAGE.md` "Remaining proof obligations" → discharge a `sorry`
  (e.g. `natMul_val`) and promote its grade — the fuzz backstops tell you
  the statements are true; the proofs are waiting to be finished.

## Commit style

Imperative subject with an area prefix (`fix:`, `proofs:`, `docs:`,
`release:`), body explains *why*. No AI attribution footers.
