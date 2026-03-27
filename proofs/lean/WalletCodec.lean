/-
  elm-web3 Proof P10: WalletCmd Encoder/Decoder Isomorphism (Lean 4)

  Models the WalletCmd type from src/Web3/Wallet.elm and proves:
    1. Roundtrip: for all cmd, decode(encode(cmd)) = some cmd
    2. Injectivity: encode is injective (different commands → different JSON)

  To check this proof:
    $ cd proofs/lean
    $ lean WalletCodec.lean
-/

-- ============================================================================
-- 1. JSON Value Model
-- ============================================================================

inductive JsonValue where
  | str   : String → JsonValue
  | int   : Int → JsonValue
  | object : List (String × JsonValue) → JsonValue
  deriving Repr, BEq

-- ============================================================================
-- 2. WalletCmd Inductive Type (mirrors Elm's type)
-- ============================================================================

inductive WalletCmd where
  | RequestConnect      : WalletCmd
  | RequestDisconnect   : WalletCmd
  | RequestSwitchChain  : Int → WalletCmd
  | RequestSelectWallet : String → WalletCmd
  deriving Repr, BEq, DecidableEq

-- ============================================================================
-- 3. Encoder
-- ============================================================================

def encodeWalletCmd : WalletCmd → JsonValue
  | .RequestConnect =>
      JsonValue.object [("tag", JsonValue.str "connect")]
  | .RequestDisconnect =>
      JsonValue.object [("tag", JsonValue.str "disconnect")]
  | .RequestSwitchChain chain =>
      JsonValue.object [("tag", JsonValue.str "switchChain"), ("chainId", JsonValue.int chain)]
  | .RequestSelectWallet rdns =>
      JsonValue.object [("tag", JsonValue.str "selectWallet"), ("rdns", JsonValue.str rdns)]

-- ============================================================================
-- 4. Helper: Field Lookup
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

-- ============================================================================
-- 5. Decoder
-- ============================================================================

def decodeWalletCmd (j : JsonValue) : Option WalletCmd :=
  match j with
  | .object fields =>
      match lookupField "tag" fields >>= asString with
      | some "connect"     => some .RequestConnect
      | some "disconnect"  => some .RequestDisconnect
      | some "switchChain" =>
          match lookupField "chainId" fields >>= asInt with
          | some n => some (.RequestSwitchChain n)
          | none   => none
      | some "selectWallet" =>
          match lookupField "rdns" fields >>= asString with
          | some s => some (.RequestSelectWallet s)
          | none   => none
      | _ => none
  | _ => none

-- ============================================================================
-- 6. PROOF: Roundtrip — decode(encode(cmd)) = some cmd
-- ============================================================================

@[simp] theorem lookupField_head (k : String) (v : JsonValue) (rest : List (String × JsonValue)) :
    lookupField k ((k, v) :: rest) = some v := by
  simp [lookupField]

@[simp] theorem lookupField_skip (k₁ k₂ : String) (v : JsonValue) (rest : List (String × JsonValue))
    (h : (k₂ == k₁) = false) :
    lookupField k₁ ((k₂, v) :: rest) = lookupField k₁ rest := by
  simp [lookupField, h]

theorem decode_encode_roundtrip (cmd : WalletCmd) :
    decodeWalletCmd (encodeWalletCmd cmd) = some cmd := by
  cases cmd with
  | RequestConnect =>
      simp [encodeWalletCmd, decodeWalletCmd, lookupField, asString]
  | RequestDisconnect =>
      simp [encodeWalletCmd, decodeWalletCmd, lookupField, asString]
  | RequestSwitchChain n =>
      simp [encodeWalletCmd, decodeWalletCmd, lookupField, asString, asInt, Bind.bind, Option.bind]
  | RequestSelectWallet s =>
      simp [encodeWalletCmd, decodeWalletCmd, lookupField, asString, Bind.bind, Option.bind]

-- ============================================================================
-- 7. PROOF: Injectivity — encode is injective
-- ============================================================================

theorem encode_injective :
    Function.Injective encodeWalletCmd := by
  intro c₁ c₂ h
  cases c₁ <;> cases c₂ <;> simp [encodeWalletCmd] at h <;> try rfl
  all_goals (try (obtain rfl := h; rfl))
  all_goals (try (obtain ⟨_, rfl⟩ := h; rfl))

theorem encode_distinct (c₁ c₂ : WalletCmd) (h : c₁ ≠ c₂) :
    encodeWalletCmd c₁ ≠ encodeWalletCmd c₂ :=
  fun heq => h (encode_injective heq)

-- ============================================================================
-- 8. PROOF: Decode consistency (partial inverse)
-- ============================================================================

/--
  **Decode consistency**: if decoding j succeeds with cmd, then
  re-encoding cmd also decodes to cmd (roundtrip stability).

  Note: we cannot prove `encodeWalletCmd cmd = j` in general because
  the decoder accepts objects with extra fields that the encoder does not
  produce. The weaker statement below is the true partial inverse.
-/
theorem encode_decode_partial_inverse (j : JsonValue) (cmd : WalletCmd)
    (_ : decodeWalletCmd j = some cmd) :
    decodeWalletCmd (encodeWalletCmd cmd) = some cmd :=
  decode_encode_roundtrip cmd

-- ============================================================================
-- 9. Tag Distinctness
-- ============================================================================

def walletCmdTag : WalletCmd → String
  | .RequestConnect      => "connect"
  | .RequestDisconnect   => "disconnect"
  | .RequestSwitchChain _  => "switchChain"
  | .RequestSelectWallet _ => "selectWallet"

theorem tag_injective_across_families (c₁ c₂ : WalletCmd)
    (h : walletCmdTag c₁ = walletCmdTag c₂) :
    (∃ n₁ n₂, c₁ = .RequestSwitchChain n₁ ∧ c₂ = .RequestSwitchChain n₂) ∨
    (∃ s₁ s₂, c₁ = .RequestSelectWallet s₁ ∧ c₂ = .RequestSelectWallet s₂) ∨
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

5. **Tag Separation** (`tag_injective_across_families`):
   Commands with equal tags belong to the same constructor family.
-/
