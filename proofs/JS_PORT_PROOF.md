# JS port layer safety audit - `js/elm-web3-ports.ts`

**File under audit:** `js/elm-web3-ports.ts` - **1,688 lines of TypeScript**
**Revision audited:** blob `8fb1b2ab`, tree `87d686b` (`git show 87d686b:js/elm-web3-ports.ts`)
**Date:** 2026-07-27
**Supersedes:** the 2026-03-26 audit of `js/elm-web3-ports.js` (509 lines), which
described a file that no longer exists. Its findings F1-F8 are re-checked below.

**Concurrency note.** The bridge was being edited while this audit ran
(the Elm-JS boundary work: `cmd.data` passthrough, a single error taxonomy,
correlation ids on the write path). This document is pinned to the blob named
above so it can be reproduced exactly; every finding tagged **[superseded by
boundary work]** is expected to be fixed by that change and must be re-checked
against the new blob before the next release. Nothing here was written from
memory of a file version that was not read.

**Also note:** the *shipped* artifact `js/elm-web3-ports.js` is a `bun build`
of this source. At the revision above it predated the 2.0.0 wallet rewrite and
could not emit `connectRejected` / `connectPending` / `connectFailed` at all,
so an adopter loading the built artifact had a wallet that could never report
rejection, pending, or failure. That is an artifact-freshness defect, not a
source defect, and it is not what this document audits - it audits the
TypeScript.

---

## What is claimed, and what is actually true

| # | Claim | Verdict |
|---|---|---|
| 1 | No exception escapes to the caller uncaught | **Proven for the command dispatch. NOT true of the file as a whole** - eleven listener/subscription send sites sit outside every `try` (F11). |
| 2 | Every success path sends a tagged response | **True for 34 of 36 switch arms.** `unwatchEvent` and `unwatchBlockNumber` acknowledge nothing (F10). |
| 3 | Every failure path sends a tagged failure response | **True.** But "unified on one tag" is false: there are five distinct failure tags plus two not-found tags (F7). |

Claims 1 and 3 are the safety claims and they hold where it matters - the
command dispatch cannot leave Elm hanging. Claim 2's exceptions are teardown
commands with no observable result. The corrections are in the findings.

---

## Architecture

The whole command dispatch is one `async` callback on `web3Cmd.subscribe`
(lines 491-1113): a 36-arm `switch` (493-1090) inside a single top-level
`try`, with one `catch` (1091-1112).

```
web3Cmd.subscribe(async (cmd) => {
  try {
    switch (cmd.tag) {
      case 'connect':      { try { ... } catch (err) { connectRejected | connectPending | connectFailed } }
      case 'selectWallet': { try { ... } catch (err) { connectRejected | connectPending | connectFailed } }
      ...33 more arms...
      default:             unknownCmd
    }
  } catch (err) {                                        // 1091
    if (err.code === 4001) send({ tag: 'rejected' })     // 1093
    else send({ tag: 'failed', error: <revert reason or err.message>, revertData? })
  }
})
```

Two structural changes since the 2026-03-26 audit:

1. **`connect` and `selectWallet` catch first, on purpose** (502-533, 774-814).
   A dismissed *connection* prompt must not arrive at Elm as the same
   `rejected` a dismissed *transaction* produces - the wallet FSM has no way
   to tell those apart. These two arms therefore translate `4001` ->
   `connectRejected`, `-32002` -> `connectPending`, anything else ->
   `connectFailed`, each carrying the caller's `requestId`. This is what
   `Web3.Wallet`'s `RequestId` machinery decodes.
2. **Reads route through a dispatcher** (`_rpcRequest`, 293-312): wallet
   provider first, public RPC pool as a read-only fallback with per-endpoint
   cooldown; writes (`eth_sendTransaction`, chain switch, signing) throw
   rather than touch a public endpoint.

### The global catch, exactly (1091-1112)

- `err.code === 4001` -> `{ tag: 'rejected' }` (no id, no code).
- otherwise -> `{ tag: 'failed', error: <string> }`, where `<string>` is the
  decoded on-chain revert reason when `err.data` (or `err.error.data`) yields
  one, else `err.message || String(err)`; plus `revertData: <0x...>` when the
  error data is a hex string.
- `err.code` itself never crosses the boundary. Neither does any correlation
  id. See F9.
- The catch can only throw if `web3Sub.send` throws - an Elm runtime failure,
  out of scope, and the same assumption the previous audit made.

**Conclusion:** every synchronous throw and every awaited rejection inside any
of the 36 arms produces exactly one tagged response. That part of the original
proof survives the rewrite intact.

---

## Command dispatch, arm by arm

36 arms (35 tags + `default`). "Success" = the tag sent when the arm completes
normally; every arm's failure path is the global catch unless stated.

| Line | Command | Success response | Notes |
|---|---|---|---|
| 494 | `connect` | `connected` | own catch: `connectRejected` / `connectPending` / `connectFailed`; `readOnly` when there is no wallet but an RPC pool (F12) |
| 537 | `disconnect` | `disconnected` | `wallet_revokePermissions` best-effort, failure swallowed by design |
| 566 | `switchChain` | `switchChainOk` | F1 fixed |
| 578 | `call` | `callResult` | |
| 587 | `estimateGas` | `gasEstimate` | |
| 614 | `send` | `submitted` | simulates via `eth_estimateGas` first unless `skipSimulate`; then `pollReceipt` -> `confirmation*` / `confirmed` / `failed` |
| 649 | `multicall` | `multicallResult` | |
| 674 | `watchEvent` | `subscribed` | then an `eventLog` stream; WS `eth_subscribe`, else 4s `eth_getLogs` poll. F2 fixed |
| 711 | `unwatchEvent` | **none** | F10 |
| 723 | `getBalance` | `balance` | |
| 730 | `personalSign` | `signed` | |
| 741 | `ecRecover` | `recovered` | |
| 752 | `signTypedData` | `signed` | |
| 763 | `selectWallet` | `connected` | own catch, as `connect` |
| 819 | `addChain` | `chainAdded` | |
| 836 | `getBlockNumber` | `blockNumber` | |
| 843 | `getBlock` | `block` | |
| 861 | `watchBlockNumber` | `blockNumber` (stream) | WS `newHeads`, else 4s poll. F8 fixed |
| 888 | `unwatchBlockNumber` | **none** | F10 |
| 904 | `getTransactionCount` | `txCount` | |
| 911 | `getStorageAt` | `storageAt` | |
| 918 | `getCode` | `code` | |
| 925 | `getGasPrice` | `gasPrice` | |
| 932 | `getMaxPriorityFee` | `maxPriorityFee` | |
| 939 | `getFeeHistory` | `feeHistory` | |
| 951 | `getTransactionReceipt` | `receiptResult` / `receiptNotFound` | |
| 974 | `getLogs` | `logs` | |
| 997 | `getTransaction` | `transaction` / `transactionNotFound` | |
| 1019 | `deploy` | `submitted` | + `pollReceipt` |
| 1036 | `sendRawTransaction` | `submitted` | + `pollReceipt` |
| 1044 | `watchAsset` | `assetWatched` | |
| 1055 | `requestPermissions` | `permissions` | |
| 1066 | `getPermissions` | `permissions` | |
| 1074 | `getBlockTransactionCount` | `blockTxCount` | |
| 1082 | `keccak256` | `keccak256Result` | pure computation, cannot throw for any string |
| 1088 | `default` | `unknownCmd` | F3 fixed at the port layer; nothing in Elm decodes it |

---

## Exception containment outside the dispatch

`web3Sub.send` is called from 73 sites. The ones NOT inside the command
`try` are:

| Line | Site | Guarded? |
|---|---|---|
| 319 | `readOnly` announcement on a `setTimeout(..., 0)` | **no** |
| 339 | silent reconnect, inside `.then` | yes - trailing `.catch` (346) |
| 401, 403 | WS re-arm on reconnect, inside `.then` / `.catch` | `.then` yes, **`.catch` no** |
| 426, 434 | `socket.onmessage` -> `blockNumber` / `eventLog` | **no** |
| 453 | `socket.onclose` -> `subscribed status:'closed'` | **no** |
| 474, 476 | `_startEventSubscription`, fire-and-forget at 676 | `try` yes, **catch's send no** |
| 691 | `watchEvent` poll interval | yes (704) |
| 865 | `watchBlockNumber` poll | yes (866) |
| 1119, 1143 | injected-provider listeners, synchronous | yes - the listener's own `try` (1118/1145) |
| 1134, 1136 | same listener, inside `.then` | yes - the trailing `.catch` (1139), which runs after the `try` has returned |
| 1140 | same listener, inside that `.catch` | **no** |
| 1182, 1208 | `setupExternalProvider` listeners, synchronous | **no - no try/catch anywhere in this function** |
| 1194, 1196 | `recheckOrDisconnect`, inside `.then` | yes - trailing `.catch` (1199) |
| 1200 | `recheckOrDisconnect`, inside that `.catch` | **no** |
| 1237 | `_broadcastWallets` from `watchWallets` / `registerProvider` | **no** |
| 1663, 1680 | `pollReceipt` loop | yes (1681) |
| 1686 | `pollReceipt` timeout | yes (1685) |

Every one of these requires `web3Sub.send` to throw, which requires an Elm
runtime failure - the same caveat the original audit accepted. The honest
statement is therefore: **the command dispatch is exception-tight; the
listener surface is not, and one whole function (`setupExternalProvider`, the
bring-your-own-transport seam) has no exception handling at all.** The
previous audit's F6 verdict of "Fixed - listeners wrapped" was true only of
the two listeners registered inside `setupPorts`.

---

## F1-F8, re-checked against this blob

| # | Original finding (2026-03-26) | Verdict now | Evidence |
|---|---|---|---|
| F1 | `switchChain` sends no success response | **Fixed** | `switchChainOk` at 573 |
| F2 | `watchEvent` is an empty stub | **Fixed** | 674-710 + `_startEventSubscription` 466-478; WS subscribe with re-arm (398-405) and a 4s `eth_getLogs` fallback (682-705) |
| F3 | Unknown tags silently ignored | **Fixed at the port layer** | `unknownCmd` at 1089. No Elm module decodes that tag, so the message is dropped by the Elm runtime instead - the port is no longer silent, the library still is |
| F4 | `connect` may send `address: undefined` | **Fixed** | accounts-array guards at 512-515 and 791-794 |
| F5 | `pollReceipt` unhandled rejection | **Fixed** | loop `try/catch` 1659-1683 and the terminal send wrapped at 1685-1687 |
| F6 | Wallet event listeners lack try/catch | **Partially fixed - RESTATED** | 1118-1145 wrapped; `setupExternalProvider` (1176-1214), `watchWallets`/`_broadcastWallets` (1219-1238), and the WS handlers (394-463) are not. See the table above |
| F7 | Error tag inconsistency | **The 2026-07-02 verdict was FALSE - RETRACTED. See below** | |
| F8 | `watchBlockNumber` interval leak | **Fixed** | pollers keyed by id (369), cleared on re-issue (869-871), cleared by `unwatchBlockNumber` (888-901) |

### F7 - retraction

The 2026-07-02 re-audit recorded:

> **Resolved by convention** - failures unified on the switch-level catch
> emitting `failed` with a context field; per-module decoders document their
> tags.

Both halves are false, and this document asserted them without checking.

1. **There is no context field.** The global catch (1103-1109) builds
   `{ tag, error }` and conditionally adds `revertData`. That is the entire
   message. No context, no command name, no `err.code`, no id.
2. **Failures are not unified on that catch.** They are more spread out than
   when the finding was written. A failure reaches Elm as one of:
   `failed` (global catch, and again from `pollReceipt`'s 4-minute timeout
   with a hardcoded message), `rejected` (global catch, `4001` only),
   `connectFailed`, `connectRejected`, `connectPending` (the two connect
   arms), or `subscribed status:'failed'` (subscription setup). `unknownCmd`,
   `receiptNotFound` and `transactionNotFound` are further non-success
   outcomes with their own tags.

What *is* true, and is the defensible version of the finding: the `{tag:
'error'}` shape the original F7 complained about is gone - `grep -c "tag:
'error'"` returns 0 - and the connect-specific tags that replaced it are a
deliberate improvement, because a dismissed connect prompt and a failed
transaction genuinely are different events. The problem is not that there are
several tags. It is that **the tags carry no code and no id** (F9), so the app
cannot act on the distinction anyway.

**Status: open.** The correct fix is one error type carrying `err.code` plus a
correlation id, not fewer tags.

---

## Open findings

**F9 - failures carry neither `err.code` nor a correlation id (HIGH).**
Lines 1091-1112. `err.code` is consumed to pick a tag and then discarded, so
`4902` ("chain not added") is invisible to Elm and the standard
switchChain-then-addChain retry cannot be written. `failed` and `submitted`
carry no id, so with two writes in flight an app cannot tell which one failed.
*[superseded by boundary work: a single error type forwarding `code`, plus
write-path correlation ids.]*

**F10 - teardown commands acknowledge nothing (LOW).**
`unwatchEvent` (711-720) and `unwatchBlockNumber` (888-901) complete silently.
An app cannot distinguish "torn down" from "command never arrived". Both are
idempotent and neither can strand Elm state, hence LOW.

**F11 - the listener surface has no exception containment (LOW).**
The table above. `setupExternalProvider` is the worst case: it is the
documented BYO-transport seam, so a third-party provider's malformed event
reaches an unguarded handler.

**F12 - `readOnly` answers a connect request without its id (MEDIUM).**
Lines 503-506: when there is no injected wallet but an RPC pool is configured,
a `connect` command is answered with `{ tag: 'readOnly' }`, dropping
`requestId`. `Wallet.update` moves `Connecting _` to `ReadOnly` on that
message regardless of which attempt is in flight - the one connect-resolution
path that is not id-tracked, so a stale `readOnly` cannot be filtered. Logged
as D-W5 in `TLA_CONFORMANCE.md`. Low impact today (the message is only emitted
when no wallet exists at all, so a superseding attempt cannot succeed either),
but it is a hole in an otherwise total scheme.

**F13 - malformed hex decodes to plausible garbage, not to an error (LOW).**
`_decodeAggregate3Result`'s `word()` (1596-1598) is `parseInt`, which yields
`NaN` on bad input; `h.slice(NaN, ...)` yields `''`, so a corrupted multicall
return decodes to empty `data` with a `success` flag rather than throwing.
Same class as the Elm-side slot decoders. No exception escapes - this is a
correctness note, not a safety one.

---

## Verdict

**Safety: PASS for the command dispatch.** No exception from any of the 36
switch arms can escape uncaught; every arm that produces a result reports it;
every failure produces exactly one tagged message.

**Not proven:** exception containment on the listener/subscription surface
(F11), and the whole of `setupExternalProvider`.

**Not fixed:** the error channel is tag-rich and information-poor (F7/F9).
That is the finding that matters most here, because it is the one an app
cannot work around from Elm.

Re-run this audit against a new blob whenever `js/elm-web3-ports.ts` changes.
`scripts/check-port-parity.ts` mechanises the wire-tag half of the boundary
(plus payload-field collisions); the exception-containment and
response-completeness analysis above is still hand work, and is graded
**Manual** in `COVERAGE.md` for that reason. `proofs/EVM_API_COVERAGE.md`
records exactly how far the mechanical check reaches.
