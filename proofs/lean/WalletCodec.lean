/-
  elm-web3 Proof P10: WalletCmd Encoder/Decoder Isomorphism (Lean 4)

  Models the WalletCmd type from src/Web3/Wallet.elm (v2) and proves:
    1. Roundtrip: for all cmd, decode(encode(cmd)) = some cmd
    2. Injectivity: encode is injective (different commands → different JSON)
    3. Tag distinctness: each constructor maps to a unique JSON tag

  v2 WalletCmd constructors:
    RequestConnect
    RequestDisconnect
    RequestSwitchChain Int
    RequestSelectWallet String
    RequestAddChain ChainConfig        -- NEW in v2 (replaces RequestBalance)
    RequestWatchAsset WatchAssetOpts   -- NEW in v2
    RequestPermissions                 -- NEW in v2
    GetPermissions                     -- NEW in v2

  (RequestBalance was removed in v2; use Web3.Balance.getBalance instead.)

  To check:
    $ lean proofs/lean/WalletCodec.lean
-/

-- ============================================================================
-- 1. JSON Value Model
-- ============================================================================

inductive JsonValue where
  | str    : String → JsonValue
  | int    : Int → JsonValue
  | list   : List JsonValue → JsonValue
  | object : List (String × JsonValue) → JsonValue
  deriving Repr, BEq

-- ============================================================================
-- 2. Supporting record types (mirrors Elm)
-- ============================================================================

structure ChainConfig where
  chainId                  : Int
  chainName                : String
  rpcUrls                  : List String
  nativeCurrencyName       : String
  nativeCurrencySymbol     : String
  nativeCurrencyDecimals   : Int
  blockExplorerUrls        : List String
  deriving Repr, BEq, DecidableEq

structure WatchAssetOpts where
  address  : String  -- address as plain string at this level (already validated at type level)
  symbol   : String
  decimals : Int
  image    : String
  deriving Repr, BEq, DecidableEq

-- ============================================================================
-- 3. WalletCmd Inductive Type (mirrors v2 Elm type)
-- ============================================================================

inductive WalletCmd where
  | RequestConnect      : WalletCmd
  | RequestDisconnect   : WalletCmd
  | RequestSwitchChain  : Int → WalletCmd
  | RequestSelectWallet : String → WalletCmd
  | RequestAddChain     : ChainConfig → WalletCmd
  | RequestWatchAsset   : WatchAssetOpts → WalletCmd
  | RequestPermissions  : WalletCmd
  | GetPermissions      : WalletCmd
  deriving Repr, BEq, DecidableEq

-- ============================================================================
-- 4. Encoder (mirrors Wallet.encode)
-- ============================================================================

def encodeStringList (xs : List String) : JsonValue :=
  JsonValue.list (xs.map JsonValue.str)

def encodeWalletCmd : WalletCmd → JsonValue
  | .RequestConnect =>
      JsonValue.object [("tag", JsonValue.str "connect")]
  | .RequestDisconnect =>
      JsonValue.object [("tag", JsonValue.str "disconnect")]
  | .RequestSwitchChain chain =>
      JsonValue.object [("tag", JsonValue.str "switchChain"), ("chainId", JsonValue.int chain)]
  | .RequestSelectWallet rdns =>
      JsonValue.object [("tag", JsonValue.str "selectWallet"), ("rdns", JsonValue.str rdns)]
  | .RequestAddChain cfg =>
      JsonValue.object
        [ ("tag",        JsonValue.str "addChain")
        , ("chainId",    JsonValue.int cfg.chainId)
        , ("chainName",  JsonValue.str cfg.chainName)
        , ("rpcUrls",    encodeStringList cfg.rpcUrls)
        , ("nativeCurrency", JsonValue.object
            [ ("name",     JsonValue.str cfg.nativeCurrencyName)
            , ("symbol",   JsonValue.str cfg.nativeCurrencySymbol)
            , ("decimals", JsonValue.int cfg.nativeCurrencyDecimals)
            ])
        , ("blockExplorerUrls", encodeStringList cfg.blockExplorerUrls)
        ]
  | .RequestWatchAsset opts =>
      JsonValue.object
        [ ("tag",      JsonValue.str "watchAsset")
        , ("address",  JsonValue.str opts.address)
        , ("symbol",   JsonValue.str opts.symbol)
        , ("decimals", JsonValue.int opts.decimals)
        , ("image",    JsonValue.str opts.image)
        ]
  | .RequestPermissions =>
      JsonValue.object [("tag", JsonValue.str "requestPermissions")]
  | .GetPermissions =>
      JsonValue.object [("tag", JsonValue.str "getPermissions")]

-- ============================================================================
-- 5. Helper: Field Lookup and Type Coercions
-- ============================================================================

def lookupField (key : String) : List (String × JsonValue) → Option JsonValue
  | [] => none
  | (k, v) :: rest => if k == key then some v else lookupField key rest

def asString : JsonValue → Option String
  | .str s => some s
  | _ => none

def asInt : JsonValue → Option Int
  | .int n => some n
  | _ => none

def asStringList : JsonValue → Option (List String)
  | .list xs => xs.mapM asString
  | _ => none

def asObject : JsonValue → Option (List (String × JsonValue))
  | .object fields => some fields
  | _ => none

-- ============================================================================
-- 6. Decoder
-- ============================================================================

def decodeWalletCmd (j : JsonValue) : Option WalletCmd :=
  match j with
  | .object fields =>
      match lookupField "tag" fields >>= asString with
      | some "connect"     => some .RequestConnect
      | some "disconnect"  => some .RequestDisconnect
      | some "switchChain" =>
          lookupField "chainId" fields >>= asInt >>= fun n => some (.RequestSwitchChain n)
      | some "selectWallet" =>
          lookupField "rdns" fields >>= asString >>= fun s => some (.RequestSelectWallet s)
      | some "addChain" =>
          match (lookupField "chainId"    fields >>= asInt,
                 lookupField "chainName"  fields >>= asString,
                 lookupField "rpcUrls"    fields >>= asStringList,
                 lookupField "blockExplorerUrls" fields >>= asStringList) with
          | (some cid, some cname, some rpcs, some beurls) =>
              match lookupField "nativeCurrency" fields >>= asObject with
              | some ncFields =>
                  match (lookupField "name"     ncFields >>= asString,
                         lookupField "symbol"   ncFields >>= asString,
                         lookupField "decimals" ncFields >>= asInt) with
                  | (some ncName, some ncSymbol, some ncDec) =>
                      some (.RequestAddChain
                        { chainId                = cid
                        , chainName              = cname
                        , rpcUrls                = rpcs
                        , nativeCurrencyName     = ncName
                        , nativeCurrencySymbol   = ncSymbol
                        , nativeCurrencyDecimals = ncDec
                        , blockExplorerUrls      = beurls
                        })
                  | _ => none
              | none => none
          | _ => none
      | some "watchAsset" =>
          match (lookupField "address"  fields >>= asString,
                 lookupField "symbol"   fields >>= asString,
                 lookupField "decimals" fields >>= asInt,
                 lookupField "image"    fields >>= asString) with
          | (some addr, some sym, some dec, some img) =>
              some (.RequestWatchAsset { address := addr, symbol := sym, decimals := dec, image := img })
          | _ => none
      | some "requestPermissions" => some .RequestPermissions
      | some "getPermissions"     => some .GetPermissions
      | _ => none
  | _ => none

-- ============================================================================
-- 7. Helper Lemmas for Lookup
-- ============================================================================

@[simp]
theorem lookupField_head (k : String) (v : JsonValue) (rest : List (String × JsonValue)) :
    lookupField k ((k, v) :: rest) = some v := by
  simp [lookupField]

@[simp]
theorem lookupField_skip (k₁ k₂ : String) (v : JsonValue)
    (rest : List (String × JsonValue)) (h : (k₂ == k₁) = false) :
    lookupField k₁ ((k₂, v) :: rest) = lookupField k₁ rest := by
  simp [lookupField, h]

/-- Encoding a list of strings and decoding it back gives the original list. -/
theorem asStringList_encodeStringList (xs : List String) :
    asStringList (encodeStringList xs) = some xs := by
  induction xs with
  | nil => simp [encodeStringList, asStringList, List.mapM]
  | cons h t ih =>
    simp [encodeStringList, asStringList, List.mapM, asString, List.map,
          List.mapM_cons, ih, Bind.bind, Option.bind]

-- ============================================================================
-- 8. PROOF: Roundtrip — decode(encode(cmd)) = some cmd
-- ============================================================================

theorem decode_encode_roundtrip (cmd : WalletCmd) :
    decodeWalletCmd (encodeWalletCmd cmd) = some cmd := by
  cases cmd with
  | RequestConnect =>
      simp [encodeWalletCmd, decodeWalletCmd, lookupField, asString]
  | RequestDisconnect =>
      simp [encodeWalletCmd, decodeWalletCmd, lookupField, asString]
  | RequestSwitchChain n =>
      simp [encodeWalletCmd, decodeWalletCmd, lookupField, asString, asInt,
            Bind.bind, Option.bind]
  | RequestSelectWallet s =>
      simp [encodeWalletCmd, decodeWalletCmd, lookupField, asString,
            Bind.bind, Option.bind]
  | RequestAddChain cfg =>
      simp only [encodeWalletCmd, decodeWalletCmd, lookupField_head]
      simp only [lookupField_skip (h := by decide), lookupField_head]
      simp [asString, asInt, asStringList_encodeStringList, asObject,
            Bind.bind, Option.bind]
  | RequestWatchAsset opts =>
      simp [encodeWalletCmd, decodeWalletCmd, lookupField, asString, asInt,
            Bind.bind, Option.bind]
  | RequestPermissions =>
      simp [encodeWalletCmd, decodeWalletCmd, lookupField, asString]
  | GetPermissions =>
      simp [encodeWalletCmd, decodeWalletCmd, lookupField, asString]

-- ============================================================================
-- 9. PROOF: Injectivity — encode is injective
-- ============================================================================

theorem encode_injective : Function.Injective encodeWalletCmd := by
  intro c₁ c₂ h
  cases c₁ <;> cases c₂ <;> simp [encodeWalletCmd] at h <;> try rfl
  all_goals (first | (obtain rfl := h; rfl) | (obtain ⟨_, rfl⟩ := h; rfl)
             | (obtain rfl := h.1; obtain rfl := h.2; rfl)
             | (rename_i cfg₁ cfg₂; cases cfg₁; cases cfg₂; simp at h; obtain ⟨h1,h2,h3,h4,h5,h6,h7⟩ := h; subst_vars; rfl)
             | (rename_i o₁ o₂; cases o₁; cases o₂; simp at h; obtain ⟨h1,h2,h3,h4⟩ := h; subst_vars; rfl))

theorem encode_distinct (c₁ c₂ : WalletCmd) (h : c₁ ≠ c₂) :
    encodeWalletCmd c₁ ≠ encodeWalletCmd c₂ :=
  fun heq => h (encode_injective heq)

-- ============================================================================
-- 10. PROOF: Decode consistency (partial inverse)
-- ============================================================================

/--
  If decoding j succeeds with cmd, re-encoding cmd and decoding again gives cmd.
  (The decoder accepts extra fields the encoder does not produce, so the
  full converse `encode cmd = j` does not hold in general.)
-/
theorem encode_decode_partial_inverse (j : JsonValue) (cmd : WalletCmd)
    (_ : decodeWalletCmd j = some cmd) :
    decodeWalletCmd (encodeWalletCmd cmd) = some cmd :=
  decode_encode_roundtrip cmd

-- ============================================================================
-- 11. Tag Distinctness
-- ============================================================================

def walletCmdTag : WalletCmd → String
  | .RequestConnect      => "connect"
  | .RequestDisconnect   => "disconnect"
  | .RequestSwitchChain _  => "switchChain"
  | .RequestSelectWallet _ => "selectWallet"
  | .RequestAddChain _     => "addChain"
  | .RequestWatchAsset _   => "watchAsset"
  | .RequestPermissions    => "requestPermissions"
  | .GetPermissions        => "getPermissions"

/-- All eight tags are distinct strings. -/
theorem walletCmdTags_distinct :
    ["connect", "disconnect", "switchChain", "selectWallet",
     "addChain", "watchAsset", "requestPermissions", "getPermissions"].Nodup := by
  decide

theorem walletCmdTag_same_family (c₁ c₂ : WalletCmd)
    (h : walletCmdTag c₁ = walletCmdTag c₂) :
    (∃ n₁ n₂, c₁ = .RequestSwitchChain n₁ ∧ c₂ = .RequestSwitchChain n₂) ∨
    (∃ s₁ s₂, c₁ = .RequestSelectWallet s₁ ∧ c₂ = .RequestSelectWallet s₂) ∨
    (∃ cfg₁ cfg₂, c₁ = .RequestAddChain cfg₁ ∧ c₂ = .RequestAddChain cfg₂) ∨
    (∃ o₁ o₂, c₁ = .RequestWatchAsset o₁ ∧ c₂ = .RequestWatchAsset o₂) ∨
    c₁ = c₂ := by
  cases c₁ <;> cases c₂ <;> simp [walletCmdTag] at h ⊢

/-!
## Verified Properties

1. **Roundtrip** (`decode_encode_roundtrip`):
   `∀ cmd, decodeWalletCmd (encodeWalletCmd cmd) = some cmd`

2. **Injectivity** (`encode_injective`):
   `encodeWalletCmd c₁ = encodeWalletCmd c₂ → c₁ = c₂`

3. **Distinctness** (`encode_distinct`):
   `c₁ ≠ c₂ → encodeWalletCmd c₁ ≠ encodeWalletCmd c₂`

4. **Partial Inverse** (`encode_decode_partial_inverse`):
   `decodeWalletCmd j = some cmd → decodeWalletCmd (encodeWalletCmd cmd) = some cmd`

5. **Tag Separation** (`walletCmdTag_same_family`):
   Commands with equal JSON tags belong to the same constructor family.

6. **String list roundtrip** (`asStringList_encodeStringList`):
   `asStringList (encodeStringList xs) = some xs`
   (Used in the addChain roundtrip: rpcUrls and blockExplorerUrls survive the codec.)

## v2 changes from v1

- `RequestBalance` removed (moved to `Web3.Balance`).
- `RequestAddChain ChainConfig`, `RequestWatchAsset WatchAssetOpts`,
  `RequestPermissions`, `GetPermissions` added.
- `JsonValue.list` added to model `rpcUrls` and `blockExplorerUrls` list fields.
-/
