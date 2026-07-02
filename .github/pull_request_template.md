## What & why

<!-- One paragraph. Link the issue if there is one. -->

## Verification checklist

- [ ] `elm make src/Web3.elm` clean; `elm make --docs=/tmp/docs.json` clean
- [ ] `elm-test` green (all suites, including any new fuzz properties)
- [ ] Touched a state machine (`Wallet`/`Transaction`/`Sign`)? → matching
      TLA+ spec updated, `./proofs/tla/check-tla.sh` green, and
      `proofs/TLA_CONFORMANCE.md` mapping updated
- [ ] `proofs/COVERAGE.md` still exactly true (no grade inflated — a proof
      that doesn't machine-check is **Unverified**)
- [ ] `CHANGELOG.md` entry added
- [ ] Public API unchanged — or the MAJOR/MINOR bump was agreed in an issue
      first (`elm bump` is the arbiter)
