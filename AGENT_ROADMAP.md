# Agent Task — Drive the elm-web3 stack to full verification & primitive completeness

**Scope: `elm-web3` + `elm-web3-ui`** (both repos, sibling dirs under
`/mnt/pulsechain-sata/Projects/abraxas/`). The downstream dapp (`pulsechain/app-elm`)
is referenced only where noted. Keep this file **untracked** — it is an agent brief,
not repo content.

Run the **iteration loop**: pick the highest-value open item below (they are
ranked within each track; Track A outranks everything until done), do ONE
verified increment, update the truth docs, commit, repeat. Every pass leaves
both repos green and published claims exactly true.

---

## Prime directive (unchanged, twice-vindicated)

Grade precisely; never inflate: **Proved** (Lean actually checks) ·
**Model-checked** (TLC actually ran) · **Property-tested** (fuzz actually runs)
· **Unit-tested** · **Unverified**. History in this stack: the TLA+ specs
"were model-checked" but had never parsed; the Lean proofs "verified"
RevertReason against a typo'd selector (`08c379a2` vs real `08c379a0`) — no
real revert ever decoded. Both found only when a machine (TLC / a rendered
gallery) touched reality. Therefore: **a claim is what a machine did, not what
a file says**; external constants need oracle tests against reality
(`COVERAGE.md` §Known limitations 0). If an invariant is false, that is a
finding — record it, fix code or claim, never paper over.

---

## Environment (verified working — do not rediscover)

- **Elm 0.19.1**: `~/.local/bin/elm`. Tests: `export PATH="$HOME/.local/bin:$PATH" && npx --yes elm-test --compiler "$(which elm)"`
  (elm-test is a Node CLI; **bunx cannot drive it** — this is the one sanctioned npx exception to the Bun-only rule).
- **TLC**: `~/.local/share/tla/tla2tools.jar` + Java `~/.local/share/mise/installs/java/corretto-21/bin/java`.
  Run `proofs/tla/check-tla.sh` in each repo (elm-web3: `-deadlock` only for SignSpec; elm-web3-ui: full check).
- **Lean**: NOT INSTALLED. Install via `curl https://elan.lean-lang.org/elan-init.sh -sSf | sh -s -- -y`
  (user-local, no sudo). `/tmp` is noexec — set `TMPDIR=~/.cache/...` if anything extracts+execs.
- **Gallery screenshot rig**: `~/.cache/pw-venv/bin/python ~/.cache/shot.py <out.png>` (Playwright venv +
  chromium-headless-shell installed); split tall shots with system python3+PIL. Gallery build:
  `cd elm-web3-ui/examples/gallery && elm make Main.elm --output=elm.js`, open `index.html` via file://.
- **Publish flow** (per repo): `elm bump` (elm.json must hold the last *published* version — check
  `https://package.elm-lang.org/packages/intrepidshape/<pkg>/releases.json`; **git tag ≠ published**),
  CHANGELOG dated, docs build (`elm make --docs=...`), commit `release: X.Y.Z — ...`, `git tag -a X.Y.Z`,
  push master+tag, `yes | elm publish`. Registry accepts **exactly-next** versions only.
- **Registry state**: elm-web3 **1.2.2** · elm-web3-ui **2.1.1**. Gallery live at
  https://intrepidshape.github.io/elm-web3-ui/ (Pages, rebuilds each master push).
- **CI**: both repos run elm build+test+docs and TLC on every push/PR; ui also deploys Pages. Keep green.
- **Guardrails**: no exposed-signature breaks without MAJOR agreed first (`elm bump` is the arbiter) ·
  no AI attribution in commits (hook rejects) · **never write the stealth launchpad project's name into
  these public repos — not even inside a CI grep pattern** (local pre-commit blocks it; the public repo
  calls it "a production dapp") · elm.json `summary` ≤ 80 BYTES (non-ASCII counts double; python
  json.dumps must use `ensure_ascii=False`) · Elm has no cyclic values — unreachable-fallback parsers
  must be functions · `Html.Attributes.class` crashes on SVG nodes — wrap SVG in a span for user attrs.

---

## TRACK A — Lean: make "Proved" true (DO THIS FIRST)

The last leg of the coverage doc that no machine in this environment has ever
checked. Expect findings (see prime directive).

- [ ] A1. Install elan/lake; determine what toolchain the proofs assume (no
      lakefile exists — try `lean <file>` with a pinned stable, e.g. 4.x; add a
      `lean-toolchain` + minimal lakefile so checking is reproducible).
- [ ] A2. Run ALL ten files: Address, TxHash, HexString, WalletCodec, AbiCodec,
      SignState, TxCmd, Units, BigInt, RevertReason. Record per-file verdict.
- [ ] A3. Triage failures honestly: syntax rot vs false statements vs axioms.
      Downgrade any non-checking "Proved" row in `proofs/COVERAGE.md`
      immediately; fix and re-promote only when `lean` exits 0.
- [ ] A4. RevertReason.lean: re-verify post-selector-fix (constant changed to
      08c379a0 by sed — the proofs were never re-checked after).
- [ ] A5. Discharge the seven `sorry` obligations (COVERAGE §Remaining), in
      value order: `natMul_val` → `natCompare_spec` → `uint256_codec_roundtrip`
      → `natDivMod_spec` → `fromString_toString_roundtrip` →
      `decodeRevertReason_correct` → BigInt overflow-safety. The Elm fuzz
      backstops say the statements are true; the proofs are unfinished, not wrong.
- [ ] A6. Add a `lean` job to elm-web3 CI (elan setup + check all files), same
      pattern as the tlc job. Then COVERAGE's Proved table is CI-enforced.
- [ ] A7. Model-fidelity pass: Lean `toLowerHex` models only A–F→a–f (known
      limitation 2); either strengthen or keep documented — decide explicitly.

## TRACK B — elm-web3: EVM API gaps (ranked in EVM_API_COVERAGE.md)

- [ ] B1. `eth_maxPriorityFeePerGas` — completes the 1559 fee-read triad.
      Port case + `Fee.getMaxPriorityFee` variant + decoder + tests + coverage row.
- [ ] B2. **Custom-error revert decoding** — typed solc errors
      (`error Foo(uint256)`) currently surface as raw selectors. Design: app/codegen
      supplies `{ selector → (name, arg decoders) }` fragments (same bake-at-codegen
      philosophy as calldata selectors); `Abi.Decode.decodeCustomError` +
      `Revert` (ui) renders named errors with args. Pairs with the Revert atom.
- [ ] B3. `personal_ecRecover` — client-side signature verification for login
      flows (port case + `Sign.verify`).
- [ ] B4. WS `newHeads` subscription for `watchBlockNumber` (replace the 4s
      HTTP poll; keep poll as fallback like logs subs do).
- [ ] B5. **Port F8**: `watchBlockNumber`'s `setInterval` never cleared →
      poller leak on re-issue. Fix in `js/elm-web3-ports.ts`; add
      `unwatchBlockNumber`. While in there: re-audit JS_PORT_PROOF.md F1–F7
      (documented, never remediated: watchEvent stub claims, switchChain
      response, error-tag naming) — fix or re-document each.
- [ ] B6. Watch EIP-5792 (`wallet_sendCalls`) adoption; build only when ≥2
      major wallets ship it.
- [ ] B7. Wire-protocol note: consider a library-level total inbound decoder
      (tag-dispatched `Web3.Incoming` union) so apps stop hand-matching tags —
      API-additive, big ergonomics win; needs design (MINOR).

## TRACK C — elm-web3-ui: remaining primitives (PRIMITIVES.md, post-2.1.1)

- [ ] C1. **Token-amount pair** — token selector + amount input + balance +
      presets as one compound (the swap/deposit workhorse). Compose
      TokenSearch/Amount/presetRow/Balance; house Config style.
- [ ] C2. **`EventFeed`** — bind `Web3.Subscription` log streams to
      `ActivityRow`: subscription lifecycle chip (open/failed), prepend list,
      cap + "load more" via `getLogs`. Uses B7 if it lands first.
- [ ] C3. **Block-refresh policy + balance watcher** — `Refresh = EveryBlock |
      EveryNBlocks Int | Manual` driving `RemoteCall` re-fires off
      `watchBlockNumber`.
- [ ] C4. Simulate-first write — `readCall withFrom` preview wrapped around
      ContractWrite (elm-web3 already has the capability).
- [ ] C5. Token logo/symbol atom (list-driven, TokenSearch has the shape).
- [ ] C6. `Address.copyable` — copy-to-clipboard affordance (needs a port hook
      or `navigator.clipboard` via the bridge — decide the seam honestly).
- [ ] C7. `Amount` dust convention (`<0.0001`) + locale-grouping seam
      documented (formatting itself stays out of scope).
- [ ] C8. Paginated logs loader (block-range windows, "load more").
- [ ] C9. **a11y sweep** of pre-2.1.0 modules (`aria-busy`/`aria-live`/roles)
      — the 2.1.0 modules ship with it; the older ones don't. One audit pass,
      one PR.
- [ ] C10. Sign UI: gallery shows signButton but `signatureView`/`stateView`
      display states were never screenshot-iterated — add signed/failed/
      rejected scenes to the gallery Sign section and polish.
- [ ] C11. Optimistic update generic — PARKED (dishonest-UX risk); revisit
      only with a concrete consumer demand.

## TRACK D — Gallery & theme (the oracle — keep it sharp)

- [ ] D1. Add every new primitive to the gallery **in the same PR that builds
      it** (make this a CONTRIBUTING rule) — the gallery caught 2 shipped bugs
      in one load; its coverage IS regression surface.
- [ ] D2. Screenshot-iteration pass on the domain compounds (StakeCard,
      BondCard, VeLock, GaugeRow, FundingPool, SecurityCard, NFTStakeCard,
      BondingCurve, VeBalanceChart, HoldClock, FeeFlowDiagram, LockPeriod,
      HoldClock) — none are in the gallery yet; add a "Layer 4" section with
      plausible data, then rice their classes in gallery.css. This also makes
      the gallery truly exhaustive (currently 19 sections of ~46 modules).
- [ ] D3. Headless click-test script (`~/.cache/click.py` pattern) → commit as
      `examples/gallery/verify.py` + optional CI job (playwright in CI) so
      interaction regressions are caught, not just compile regressions.
- [ ] D4. Second theme (light) proving the rice contract — copy gallery.css,
      swap tokens, add a toggle. Cheap, high-credibility.
- [ ] D5. Link the gallery prominently from both READMEs + package docs
      header (elm-web3-ui README currently doesn't mention it).

## TRACK E — Downstream & leverage (not these repos, but the payoff)

- [ ] E1. The production dapp (`pulsechain/app-elm`) adopts `RemoteCall`,
      `ApprovalFlow`, `AccountPill`, `TxQueue`, `Revert` — deletes hand-rolled
      ladders; the primitives earn their keep. (Do in the dapp repo.)
- [ ] E2. Portfolio: add gallery URL + COVERAGE/TLA_CONFORMANCE/
      EVM_API_COVERAGE links to the intrepid-pipeline kit — "formally verified
      Elm web3 stack, live demo, public conformance audits" is a premium-work
      artifact. One paragraph, travels perfectly.
- [ ] E3. elm-web3-ui README refresh: 46 modules, taxonomy link, gallery link,
      the verification story (fuzz+TLC+gallery). It still reads pre-2.0.

## Definition of done (per pass)

One increment · machine-verified (lean/TLC/elm-test/gallery as appropriate) ·
`COVERAGE.md`/`PRIMITIVES.md`/`CHANGELOG.md` exactly true · both repos green
in CI · publish only complete releases (bump→tag→push→publish, never tag-only)
· commit messages honest about what was verified vs authored.

## Done so far (context for a fresh session)

2026-07-01/02: elm-web3 1.1.0→1.2.2 published (state-machine fixes; TLA specs
made real + conformance-audited — 9 divergences, 3 code bugs; selector typo
fix; 449 tests). elm-web3-ui 2.0.0→2.1.1 published (Maybe-unified links;
10 generic primitives; ApprovalSpec TLA+ green; gallery live on Pages;
93 tests). Full detail: both CHANGELOGs, `proofs/TLA_CONFORMANCE.md`,
`proofs/EVM_API_COVERAGE.md`, `PRIMITIVES.md`.
