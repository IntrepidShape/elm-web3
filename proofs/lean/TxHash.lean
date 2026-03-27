/-
  elm-web3 Proof P11: TxHash Type Formal Verification (Lean 4)

  Models the TxHash opaque type from src/Web3/Types.elm.
  Same structure as Address.lean, differing only in length (66 vs 42).

  To check:
    $ lean proofs/lean/TxHash.lean
-/

-- ============================================================================
-- 1. Character and String Predicates (primed names to avoid clash with Address)
-- ============================================================================

def isLowerHexDigit' (c : Char) : Bool :=
  ('0' ≤ c && c ≤ '9') || ('a' ≤ c && c ≤ 'f')

def isLowerHexBody' (cs : List Char) : Bool :=
  cs.all isLowerHexDigit'

def txDrop2 (s : String) : List Char :=
  s.toList.drop 2

def startsWith0x' (s : String) : Bool :=
  match s.toList with
  | '0' :: 'x' :: _ => true
  | _               => false

-- ============================================================================
-- 2. Validity Predicate
-- ============================================================================

def IsValidTxHash (s : String) : Prop :=
  startsWith0x' s = true ∧
  s.length = 66 ∧
  isLowerHexBody' (txDrop2 s) = true

instance : Decidable (IsValidTxHash s) :=
  inferInstanceAs (Decidable (_ ∧ _ ∧ _))

-- ============================================================================
-- 3. TxHash Type and Constructor
-- ============================================================================

structure TxHash where
  val      : String
  property : IsValidTxHash val
  deriving Repr

def toLowerHex' (c : Char) : Char :=
  if 'A' ≤ c ∧ c ≤ 'F' then
    Char.ofNat (c.toNat - 'A'.toNat + 'a'.toNat)
  else
    c

def toLowerString' (s : String) : String :=
  String.ofList (s.toList.map toLowerHex')

def mkTxHash (s : String) : Option TxHash :=
  let lower := toLowerString' s
  if h : IsValidTxHash lower then some ⟨lower, h⟩ else none

def txHashToString (t : TxHash) : String := t.val

-- ============================================================================
-- 4. Soundness
-- ============================================================================

theorem mkTxHash_sound (s : String) (t : TxHash) (_ : mkTxHash s = some t) :
    IsValidTxHash t.val :=
  t.property

theorem mkTxHash_none_iff_invalid (s : String) :
    mkTxHash s = none ↔ ¬ IsValidTxHash (toLowerString' s) := by
  unfold mkTxHash
  constructor
  · intro h
    by_cases hv : IsValidTxHash (toLowerString' s)
    · simp [dif_pos hv] at h
    · exact hv
  · intro h
    by_cases hv : IsValidTxHash (toLowerString' s)
    · exact absurd hv h
    · simp [dif_neg hv]

theorem mkTxHash_some_iff (s : String) (t : TxHash) :
    mkTxHash s = some t ↔
    (IsValidTxHash (toLowerString' s) ∧ t.val = toLowerString' s) := by
  unfold mkTxHash
  constructor
  · intro h
    by_cases hv : IsValidTxHash (toLowerString' s)
    · rw [dif_pos hv] at h
      exact ⟨hv, (congrArg TxHash.val (Option.some.inj h).symm)⟩
    · rw [dif_neg hv] at h; simp at h
  · intro ⟨hv, hval⟩
    rw [dif_pos hv]; congr 1
    cases t with | mk av ap =>
      simp only [] at hval; subst hval
      exact congrArg (TxHash.mk (toLowerString' s)) (proof_irrel hv ap)

-- ============================================================================
-- 5. Injectivity
-- ============================================================================

theorem txHashToString_injective :
    Function.Injective txHashToString := by
  intro ⟨s₁, h₁⟩ ⟨s₂, h₂⟩ heq
  simp [txHashToString] at heq
  subst heq; rfl

-- ============================================================================
-- 6. Roundtrip helpers
-- ============================================================================

theorem startsWith0x'_decomp (s : String) (h : startsWith0x' s = true) :
    ∃ rest, s.toList = '0' :: 'x' :: rest := by
  unfold startsWith0x' at h
  match hs : s.toList with
  | '0' :: 'x' :: rest => exact ⟨rest, rfl⟩
  | []         => simp [hs] at h
  | [c]        => simp [hs] at h
  | c :: d :: rest =>
    simp only [hs] at h
    by_cases hc : c = '0'
    · by_cases hd : d = 'x'
      · subst hc; subst hd; exact ⟨rest, rfl⟩
      · subst hc; simp [hd] at h
    · simp [hc] at h

theorem toLowerHex'_idempotent (c : Char) (h : isLowerHexDigit' c = true) :
    toLowerHex' c = c := by
  unfold isLowerHexDigit' at h
  simp [Bool.or_eq_true, Bool.and_eq_true] at h
  unfold toLowerHex'
  by_cases hAF : 'A' ≤ c ∧ c ≤ 'F'
  · rw [if_pos hAF]
    rcases h with ⟨_, h9⟩ | ⟨ha, _⟩
    · exfalso; exact absurd (Trans.trans hAF.1 h9) (by decide)
    · exfalso; exact absurd (Trans.trans ha hAF.2) (by decide)
  · simp [hAF]

theorem toLowerHex'_zero : toLowerHex' '0' = '0' := by decide
theorem toLowerHex'_x    : toLowerHex' 'x' = 'x' := by decide

theorem isLowerHexBody'_map_id (cs : List Char) (h : isLowerHexBody' cs = true) :
    cs.map toLowerHex' = cs := by
  induction cs with
  | nil => rfl
  | cons c cs ih =>
    simp only [isLowerHexBody', List.all_cons, Bool.and_eq_true] at h
    simp [List.map, toLowerHex'_idempotent c h.1, ih h.2]

theorem toLowerString'_idem (s : String) (h : isLowerHexBody' (txDrop2 s) = true)
    (hstart : startsWith0x' s = true) : toLowerString' s = s := by
  unfold toLowerString'
  suffices heq : s.toList.map toLowerHex' = s.toList by
    rw [heq]; exact String.ofList_toList
  obtain ⟨body, hbody⟩ := startsWith0x'_decomp s hstart
  have hbody_hex : isLowerHexBody' body = true := by
    have hd2 : txDrop2 s = body := by unfold txDrop2; simp [hbody]
    rwa [← hd2]
  rw [hbody, List.map_cons, List.map_cons, toLowerHex'_zero, toLowerHex'_x,
      isLowerHexBody'_map_id body hbody_hex]

-- ============================================================================
-- 7. Roundtrip
-- ============================================================================

theorem mkTxHash_txHashToString_roundtrip (t : TxHash) :
    mkTxHash (txHashToString t) = some t := by
  obtain ⟨s, hs⟩ := t
  show mkTxHash s = some ⟨s, hs⟩
  have hls : toLowerString' s = s :=
    toLowerString'_idem s hs.2.2 hs.1
  unfold mkTxHash
  simp only [hls]
  rw [dif_pos hs]

-- ============================================================================
-- 8. Structural Invariants
-- ============================================================================

theorem txHash_length (t : TxHash) : t.val.length = 66 :=
  t.property.2.1

theorem txHash_startsWith0x (t : TxHash) : startsWith0x' t.val = true :=
  t.property.1

theorem txHash_hex_body (t : TxHash) : isLowerHexBody' (txDrop2 t.val) = true :=
  t.property.2.2

theorem txHash_nonempty (t : TxHash) : t.val ≠ "" := by
  intro h; have := txHash_length t; rw [h] at this; simp at this

/-!
## Verified Properties

1. **Soundness** (`mkTxHash_sound`)
2. **Completeness** (`mkTxHash_none_iff_invalid`)
3. **Full characterization** (`mkTxHash_some_iff`)
4. **Injectivity** (`txHashToString_injective`)
5. **Roundtrip** (`mkTxHash_txHashToString_roundtrip`)
6. **Structural invariants**: length=66, starts "0x", lowercase hex body, non-empty
-/
