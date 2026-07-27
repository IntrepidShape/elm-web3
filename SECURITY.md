# Security Policy

This library signs and broadcasts transactions. Treat a bug here the way you
would treat a bug in a contract.

## Reporting a vulnerability

Email **[Jake@intrepiddev.com.au](mailto:Jake@intrepiddev.com.au)** with
`elm-web3 security` in the subject line.

Please include the affected version, the shortest reproduction you have, and
what an attacker gains. If a public RPC or a specific wallet is needed to
trigger it, say which.

Do **not** open a public GitHub issue for anything that lets an attacker move
funds, swap an address, forge a signature payload, or make the UI display a
transaction other than the one being signed.

What to expect:

| | |
|---|---|
| Acknowledgement | within 3 working days (Perth, AWST / UTC+8) |
| Initial assessment | within 10 working days |
| Fix or documented mitigation | as fast as the severity warrants; see [Publishing a security patch](#publishing-a-security-patch) for why "fast" has a hard floor here |
| Credit | offered by default, declined on request |

This is a small team. There is no bug bounty, and pretending otherwise would
be dishonest.

## Scope

In scope:

- `src/**` -- the Elm library.
- `js/elm-web3-ports.ts` and the built `js/elm-web3-ports.js` -- the JS bridge
  that talks to `window.ethereum` and to public RPC endpoints.
- `codegen/**` -- the ABI-to-Elm generator, where a bug could emit a wrong
  selector or a wrong decoder.
- The companion package `intrepidshape/elm-web3-ui`, which has its own
  `SECURITY.md` pointing at the same address.

Out of scope:

- Wallet extensions, RPC providers, and chains themselves.
- Applications built with the library, unless the root cause is in the library.
- The public RPC endpoints used in `examples/**`. They are illustrative, not
  endorsed, and they are not operated by us.

## What is verified, and what is not

**No external security audit has been performed on this package.** No third
party has reviewed it. If you are deciding whether to depend on it, that is
the first fact you should have.

What *is* machine-checked, on every push, with an exit code:

| Mechanism | What it covers | Where |
|---|---|---|
| Lean 4 proofs | Opaque-type soundness/injectivity/roundtrip (`Address`, `TxHash`, `HexString`), wallet-command codec roundtrip and tag separation, BigInt arithmetic, ABI codec, revert-reason decoding, sign-state and tx-command machines | `proofs/lean/`, CI job `lean` |
| TLA+ model checking (TLC) | Wallet, transaction, and signing state-machine invariants and no-deadlock liveness | `proofs/tla/`, CI job `tlc` |
| Property/fuzz and unit tests | ABI encode/decode, calldata, BigInt laws, units, wallet and transaction transitions, boundary regressions | `tests/`, CI job `elm` |
| Compiler | Elm's totality and exhaustiveness checks. There is no `any`, no cast, and no escape hatch in `src/**` | CI job `elm` |
| ASCII doc guard | Rejects non-ASCII in `docs.json`, which permanently bricks published docs for every consumer | CI job `elm` |

What is **not** verified -- stated plainly, because a verification claim that
overreaches is itself a security problem:

1. **The proofs are about models, not about the Elm source.** There is no
   extraction from Lean to Elm. Each proof restates the algorithm in Lean and
   proves properties of that restatement. A divergence between model and code
   is possible and has happened before; `proofs/COVERAGE.md` keeps the
   divergence log.
2. **TLA+ here is finite-model checked, not proof-verified.** Properties hold
   for the configured constants, not for all parameters.
3. **The JS bridge is not formally verified.** `proofs/JS_PORT_PROOF.md` is a
   manual audit with a findings log, not a machine check. Everything on the
   far side of a port -- the shim, the wallet, the RPC -- is outside Elm's
   no-runtime-exception guarantee. Elm's guarantee is that a malformed reply
   becomes a typed `Msg`, not that the reply is honest.
4. **Correctness of external constants is a test concern, not a proof
   concern.** A proof establishes internal consistency; a wrong selector or a
   wrong contract address is still wrong. Those are pinned by oracle tests
   against real-world vectors.
5. **`proofs/EVM_API_COVERAGE.md` and `proofs/TLA_CONFORMANCE.md` state
   exactly what was checked and when.** Read the claim, not the headline.

`proofs/COVERAGE.md` is the authoritative ledger of all of the above,
including the known gaps. If it and this file ever disagree, `COVERAGE.md`
wins and this file is the bug.

## Supply chain

**Zero runtime npm dependencies.** The JS bridge calls
`window.ethereum.request()` and `fetch` directly -- no viem, no wagmi, no
ethers, no polyfills. `bun` is a build-time tool for producing the bundled
shim, and `elm-test` is a dev dependency; neither ships to your users.

The Elm side depends only on `elm/core` and `elm/json`. Elm packages are pure
Elm by construction, so there is no install-time script execution anywhere in
the dependency tree.

Consequences worth stating: there is no transitive package that can be
hijacked, no postinstall hook, no `eval` and no template-string code
execution (Elm has neither primitive), and no mutable global surface for
prototype pollution.

### Verifying the shim bytes

`js/elm-web3-ports.js` is a build artifact. Do not trust it because it is in
the repo -- reproduce it:

```sh
bun js/build.ts
git diff --exit-code js/elm-web3-ports.js   # exit 0 = the committed artifact
                                            #          is exactly this source
```

That is the same check CI runs, so a committed artifact that does not match
`js/elm-web3-ports.ts` fails the build.

To pin the copy you vendored into your own app:

```sh
sha256sum js/elm-web3-ports.js               # record this in your repo
sha256sum path/to/your/app/elm-web3-ports.js # must match
```

The shim has **no version number of its own**. It is versioned by the elm-web3
git tag it ships in -- always take it from the same tag as the Elm package you
installed. Mixing generations is the most common way to get a wallet that
half-works; see `docs/UPGRADING.md` for the compatibility matrix and for the
`grep -c connectRejected` freshness check.

If you audit the bundle, audit `js/elm-web3-ports.ts` -- the `.js` is minified
output, and reading minified output is not auditing.

## Publishing a security patch

**The Elm package registry is append-only. Nothing can ever be unpublished or
overwritten.** Published bytes are immutable, forever. This shapes the entire
response procedure, and you should know it before you depend on any Elm
package, not just this one.

There is therefore no "yank the bad version" step. The procedure is
deprecate-and-supersede:

1. **Fix and publish forward, immediately.** A new version is the only
   mechanism that exists. Patch releases go out ahead of any coordinated
   announcement, because there is nothing to coordinate -- the vulnerable
   version stays installable no matter what we do.
2. **Mark the affected versions in `CHANGELOG.md`** with an explicit
   `SECURITY` heading naming every affected version range and the minimum
   fixed version. The changelog is the deprecation notice; the registry has
   no other one.
3. **Publish a GitHub Security Advisory** on the repository, with the affected
   ranges and the fixed version. This is what dependency scanners read.
4. **Note it at the top of `README.md`** for as long as a meaningful number of
   consumers are on an affected version. The README is what the registry page
   renders, so it is the highest-traffic surface available.
5. **If the JS shim is affected, say so loudly and separately.** Consumers
   vendor that file by copying it; `elm install` will not update it for them,
   and a patched Elm package alongside an unpatched shim is still vulnerable.
   Every shim-affecting advisory must carry the
   `grep`/`sha256sum` verification steps above.
6. **If a fix requires a breaking API change,** ship the MAJOR rather than
   contorting the API to dodge the bump. Semver honesty beats a quiet
   half-fix; `elm bump` is the arbiter and it is not negotiable with.

Consumers: pin an exact lower bound you have actually reviewed, re-verify the
shim hash after every upgrade, and watch this repository's advisories.

## Hardening notes for consumers

- **Writes never touch a public RPC.** Signing and `eth_sendTransaction`
  always go through the wallet provider. If you see a write on the RPC pool,
  that is a bug -- report it.
- **`rpcUrls` is a trust decision.** The pool is shuffled per page load
  specifically so no single endpoint is trusted by default, but every endpoint
  in it can lie to you about read results. Use endpoints you are willing to be
  lied to by, or run your own.
- **Simulate before you send.** `Contract.Call.withFrom` turns a write into an
  `eth_call` that reverts in the same conditions the real transaction would.
  This is the default posture the library is designed around.
- **Addresses are opaque by design.** `Web3.Types.address` is the only
  constructor. Do not route user-supplied strings around it.

## License

Reports and fixes are handled under the same MIT license as the rest of the
project.
