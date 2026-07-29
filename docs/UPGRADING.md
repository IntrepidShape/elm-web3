# Upgrading

## 2.x to 3.0.0

Six breaking changes. Five are mechanical; the `Contract.Event` one is not.

### 1. `Status` gained `RevertedOnChain Receipt`

A mined-but-reverted transaction used to arrive as `Confirmed`, so every
consumer had to remember to check `receipt.status`. Add a branch:

```elm
Tx.Confirmed receipt ->
    viewSuccess receipt

Tx.RevertedOnChain receipt ->
    viewReverted receipt          -- on chain, gas spent, state unchanged
```

**`Confirmed` now means succeeded.** If you had an `if receipt.status then ...
else ...` *inside* your `Confirmed` branch, delete it.

But if your `receipt.status` check lives in a **port handler that constructs
the Status** rather than in a view that consumes it, do NOT delete it --
re-route its else-branch from `Tx.Failed` to `Tx.RevertedOnChain`. Deleting it
there would remove revert detection entirely. (Found the hard way migrating a
real app.)

**Watch for catch-alls.** `case status of ... _ -> ...` still compiles, and
your reverted transaction lands silently in whatever the fallback does. Grep
for `_ ->` on any `Status` match and decide deliberately. This bit the ui
package itself: a reverted transaction rendered as "Confirmed" in a package
whose tests were all green.

**Any new status string you branch on probably needs CSS.** A `statusClass`
gaining `"reverted"` is a compile-clean change that renders unstyled.

### 2. `Wallet.State.Error` carries a typed `Failure`

```elm
-- before
Wallet.Error err -> text ("Error: " ++ err)
-- after
Wallet.Error err -> text ("Error: " ++ Wallet.failureMessage err)
```

If you were substring-matching that string to make a decision, pattern-match
`Failure` instead -- that is why it is typed now.

### 3. Write-path replies carry `Maybe TxId`

`TxSubmitted`, `TxConfirmation`, `TxConfirmed`, `TxFailed` and `TxRejected`
all lead with `Maybe TxId`. If you track one transaction at a time, `Nothing`
is correct and honest.

Mind the parentheses: a bare constructor passed as an argument now needs
wrapping -- `Fuzz.constant (Tx.TxRejected Nothing)`, not
`Fuzz.constant Tx.TxRejected Nothing`.

### 4. `Receipt` and `ReceiptJson` gained `contractAddress`

`Receipt.contractAddress : Maybe Address`, `ReceiptJson.contractAddress :
Maybe String`. Update record literals **and** any hand-written structural type
annotations. Note `ReceiptJson` is not exposed, so if you annotated it
structurally that annotation will drift on every future field -- this is a
known rough edge.

### 5. `Contract.Event`'s subscribe half is gone -- and your shim may need work

`EventFilter`, `watchEvent`, `encode` and `decoder` are removed. Use
`Web3.Subscription` (`open`/`close` with a `LogFilter` builder).

**If you maintain your own `ports.js` fork, porting the Elm is not enough.**
The old module sent the address under `contract` and had no subscription id;
`Subscription` sends `id` and `address` and expects `eventLog` replies with
`id`/`address`/`transactionHash`/`removed`. A fork still speaking the old
shape will compile fine and then subscribe to the wrong thing and fail every
decode. Update the shim in the same change, exactly as the 2.0.0 upgrade
required.

The old API also had an inert `event : String` field -- nothing ever hashed it
into topic 0. If you relied on it to filter, you were not filtering. Compute
topic 0 at build time and pass it via `LogFilter`'s topics.

### 6. Every `elm-web3-ui` view takes attributes first (ui 4.0.0)

Insert `[]` as the first argument at every call site. Also
`ChainGate.chainGate` is now `ChainGate.view` taking a `Config` with named
`wrongChain`/`content` fields, and `BondingCurve.sparkline` is now
`BondingCurve.view`.

### Compatibility

| elm-web3 | elm-web3-ui | shim |
|---|---|---|
| 3.0.0 | 4.0.0 | ships in the elm-web3 3.0.0 tag |
| 2.1.0 | 3.0.0 | elm-web3 2.1.0 tag |

### Checklist

- [ ] `RevertedOnChain` branch everywhere you match `Status`, catch-alls audited
- [ ] CSS for any new status class
- [ ] `Wallet.failureMessage` at display sites
- [ ] `Nothing` threaded into the five `Tx.Msg` constructors, parens checked
- [ ] `contractAddress` in receipt literals and annotations
- [ ] `Contract.Event` ported to `Subscription`, **and the shim updated to match**
- [ ] `[]` inserted at every elm-web3-ui view call site
- [ ] If your build ships a checked-in `elm.js`, rebuild it -- a source-only
      change does not deploy


## 1.x to 2.0.0

2.0.0 has exactly one breaking theme: **a wallet connect attempt now has an
identity.** Everything else in this document follows from that.

The CHANGELOG describes the change; this document is the migration. It covers
two things the CHANGELOG does not:

1. **You must replace the JS shim as well as the Elm package.** Upgrading only
   the Elm side leaves you with a wallet that can never report a rejected,
   pending, or failed connect.
2. **`intrepidshape/elm-web3-ui` below 2.4.0 is incompatible.** Every published
   ui release up to and including 2.3.1 declares `1.2.2 <= v < 2.0.0`, so
   elm's constraint solver will refuse the pair outright.

---

## 1. Why `RequestId` exists

A user clicks Connect, the wallet prompt opens, they get bored, they pick a
different wallet, they click again. Now two connect attempts are in flight and
the first one is still capable of resolving. Without an identity on the
attempt, the stale answer wins whenever it happens to land second, and there is
no way for the library to tell the difference.

So `Connecting` carries the id of the attempt in flight, `connect` and
`selectWallet` tag their port command with it, the JS shim echoes it back, and
`update` drops any response whose id is not the current one.

**Your app owns the counter.** The library only ever compares ids -- it never
generates them. An `Int` you increment on every attempt is the whole
implementation.

The payoff: you can delete your "already connecting, ignore this click" guard.
`startConnect` is deliberately allowed to supersede an attempt already in
flight, and the superseded response is a safe no-op.

---

## 2. Code changes

### Model: add a counter

```elm
-- 1.x
type alias Model =
    { wallet : Wallet.State
    }


-- 2.0
type alias Model =
    { wallet : Wallet.State
    , nextRequestId : Wallet.RequestId  -- Int; yours to increment
    }
```

### `startConnect` and `connect`

```elm
-- 1.x
ConnectWallet ->
    ( { model | wallet = Wallet.startConnect model.wallet }
    , web3Cmd (Wallet.encode Wallet.connect)
    )


-- 2.0
ConnectWallet ->
    ( { model
        | wallet = Wallet.startConnect model.nextRequestId model.wallet
        , nextRequestId = model.nextRequestId + 1
      }
    , web3Cmd (Wallet.encode (Wallet.connect model.nextRequestId))
    )
```

Pass the **same** id to `startConnect` and to `connect`. Different ids means
every response you get back is treated as stale, and the wallet never connects.

### `selectWallet`

```elm
-- 1.x
Wallet.encode (Wallet.selectWallet rdns)


-- 2.0
Wallet.encode (Wallet.selectWallet model.nextRequestId rdns)
```

`selectWallet` is a connect attempt like any other, so pair it with a
`startConnect` on the same id exactly as above.

### Pattern matches on `Connecting`

```elm
-- 1.x
case model.wallet of
    Wallet.Connecting ->
        text "Connecting..."


-- 2.0
case model.wallet of
    Wallet.Connecting _ ->
        text "Connecting..."
```

If you would rather not match at all, `Wallet.isConnecting : State -> Bool`
drives a spinner without naming the variant. Do not use it to gate the click
handler -- call `startConnect` unconditionally and let supersession do its job.

### Pattern matches on `Msg.WalletConnected`

```elm
-- 1.x
Wallet.WalletConnected address chainId ->


-- 2.0
Wallet.WalletConnected maybeRequestId address chainId ->
```

`maybeRequestId` is `Nothing` only for a silent, non-prompting reconnect on
page load -- no attempt was ever in flight to match against. Every
user-initiated connect carries `Just` the id you passed to
`connect` / `selectWallet`.

### New `Msg` variants -- your `case` will not compile until you handle them

```elm
Wallet.WalletConnectRejected requestId
Wallet.WalletConnectPending  requestId
Wallet.WalletConnectFailed   requestId reason errorString
```

with

```elm
type ConnectFailureReason
    = NotFound      -- no injected provider
    | NoAccounts    -- provider present, returned an empty account list
    | NetworkError  -- everything else
```

In 1.x all three of these arrived as an untyped `WalletError String` (or, in
the rejection case, as nothing at all -- the shim had no way to say it). If
you are routing wallet messages through `Wallet.update`, the state transitions
are already handled for you and you only need these variants if you want to
show a different message per outcome.

### Optional but recommended: `timeoutConnect`

A wallet prompt the user never touches leaves you in `Connecting` forever.

```elm
-- alongside startConnect
, Process.sleep 60000 |> Task.perform (\_ -> ConnectTimedOut requestId)

-- in update
ConnectTimedOut rid ->
    ( { model | wallet = Wallet.timeoutConnect rid model.wallet }, Cmd.none )
```

`timeoutConnect` is a no-op if the attempt already resolved or was superseded,
so it is safe to fire unconditionally.

---

## 3. Replace the JS shim -- this step is not optional

The Elm side of 2.0.0 decodes three port messages that the 1.x shim cannot
emit: `connectRejected`, `connectPending`, and `connectFailed`. It also
expects `requestId` to be echoed on `connected`.

Ship the Elm upgrade with a 1.x `elm-web3-ports.js` and you get a wallet that
appears to work until something goes wrong, at which point it reports nothing
at all -- the exact silent-wrongness this library exists to eliminate.

**Copy `js/elm-web3-ports.js` from the same tag as the Elm package you
installed.** Then confirm it is the new one:

```sh
# all three must be non-zero
grep -c connectRejected elm-web3-ports.js
grep -c connectPending  elm-web3-ports.js
grep -c connectFailed   elm-web3-ports.js
```

If any of those is `0`, you are still on the 1.x shim.

While you are there: the shipped `.js` is an **ES module bundle**. If your
`index.html` loads it with a classic `<script src="elm-web3-ports.js">`, that
throws `SyntaxError: Unexpected token 'export'` and always has. Use:

```html
<script src="elm.js"></script>
<script type="module">
  import { setupPorts } from './elm-web3-ports.js'
  const app = Elm.Main.init({ node: document.getElementById('app') })
  setupPorts(app, { rpcUrls: ['https://rpc.example.org'] })
</script>
```

See `SECURITY.md` for how to verify the shim bytes against the source.

---

## 4. Compatibility matrix

| elm-web3 | elm-web3-ui | JS shim | Notes |
|---|---|---|---|
| 2.0.0 | **2.4.0 or later** | the `js/elm-web3-ports.js` committed at the elm-web3 2.0.0 tag or later | Current. ui 2.4.0 declares `intrepidshape/elm-web3` `2.0.0 <= v < 3.0.0`. |
| 1.2.2 - 1.4.4 | 2.0.0 - 2.3.1 | the shim committed at the matching 1.x tag | Legacy. Those ui releases declare `1.2.2 <= v < 2.0.0`, so they cannot resolve against elm-web3 2.x. |
| 1.2.0 - 1.2.1 | 1.10.1 and earlier | ditto | Historical. |

Rules of thumb:

- **The shim is versioned by the elm-web3 tag it ships in, not by a number of
  its own.** Always take it from the same tag as the Elm package. There is no
  independent shim version to reason about, and mixing generations is the most
  common way to get a wallet that half-works.
- **elm-web3-ui pins a MAJOR range of elm-web3.** A MAJOR bump in elm-web3
  therefore requires a matching elm-web3-ui release before the pair can
  resolve; upgrading elm-web3 alone will fail at `elm install` time rather
  than at runtime, which is the intended behaviour.
- **elm-web3-ui 2.3.0's published `docs.json` is permanently undecodable**
  (an elm 0.19.1 parser bug with multi-byte characters -- see the elm-web3
  2.0.0 CHANGELOG entry on ASCII-only doc comments). Registry bytes are
  immutable, so that release cannot be repaired; it is superseded by 2.4.0.
  Both packages now enforce ASCII-only doc comments in CI.

---

## 5. Checklist

- [ ] `elm.json` requires `intrepidshape/elm-web3` `2.0.0 <= v < 3.0.0`
- [ ] If you use elm-web3-ui, it is 2.4.0 or later
- [ ] `elm-web3-ports.js` replaced, and `grep -c connectRejected` is non-zero
- [ ] The shim is loaded with `type="module"` and an `import`
- [ ] A `RequestId` counter lives in your model and is incremented per attempt
- [ ] `startConnect` and `connect` / `selectWallet` are given the *same* id
- [ ] Every `Connecting` pattern takes its argument
- [ ] `WalletConnected` takes its leading `Maybe RequestId`
- [ ] The three new `Msg` variants are handled (the compiler will insist)
- [ ] Your "already connecting, ignore this click" guard has been deleted
