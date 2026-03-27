/-
  elm-web3 Proof P13: HexString Type Formal Verification (Lean 4)

  Models the HexString opaque type from src/Web3/Types.elm and proves:
    1. Soundness: the `hexString` constructor only accepts valid strings
    2. Injectivity: `hexStringToString` is injective
    3. Roundtrip: re-validating an extracted HexString always succeeds

  The Elm implementation:
    - Takes a String input
    - Checks: starts with "0x" AND all remaining chars are hex digits
    - Does NOT lowercase and has NO length constraint (unlike Address/TxHash)
    - Wraps in opaque `HexString` constructor as-is (no normalization)

  To check:
    $ lean proofs/lean/HexString.lean
-/

-- ============================================================================
-- 1. Character and String Predicates
-- ============================================================================

/-- A character is a hex digit: 0-9, a-f, A-F. -/
def isHexDigit (c : Char) : Bool :=
  ('0' ≤ c && c ≤ '9') || ('a' ≤ c && c ≤ 'f') || ('A' ≤ c && c ≤ 'F')

/-- A string is "all hex" if every character is a hex digit. -/
def isHexBody (s : String) : Bool :=
  s.toList.all isHexDigit

/-- Drop the first 2 characters of a string.
    (In Lean 4.28, String.drop returns String.Slice, so we use toList.) -/
def strDrop2 (s : String) : String :=
  String.ofList (s.toList.drop 2)

/-- A string starts with "0x". -/
def startsWith0x (s : String) : Bool :=
  match s.toList with
  | '0' :: 'x' :: _ => true
  | _               => false

-- ============================================================================
-- 2. The HexString Validity Predicate
-- ============================================================================

def IsValidHexString (s : String) : Prop :=
  startsWith0x s = true ∧ isHexBody (strDrop2 s) = true

instance : Decidable (IsValidHexString s) :=
  inferInstanceAs (Decidable (_ ∧ _))

-- ============================================================================
-- 3. The HexString Type
-- ============================================================================

structure HexString where
  val      : String
  property : IsValidHexString val
  deriving Repr

-- ============================================================================
-- 4. Constructor and Accessor
-- ============================================================================

def mkHexString (s : String) : Option HexString :=
  if h : IsValidHexString s then some ⟨s, h⟩ else none

def hexStringToString (h : HexString) : String := h.val

-- ============================================================================
-- 5. PROOF: Constructor Soundness
-- ============================================================================

theorem mkHexString_sound (s : String) (h : HexString) (_ : mkHexString s = some h) :
    IsValidHexString h.val :=
  h.property

theorem mkHexString_none_iff_invalid (s : String) :
    mkHexString s = none ↔ ¬ IsValidHexString s := by
  unfold mkHexString
  constructor
  · intro h
    by_cases hv : IsValidHexString s
    · simp [dif_pos hv] at h
    · exact hv
  · intro h
    by_cases hv : IsValidHexString s
    · exact absurd hv h
    · simp [dif_neg hv]

theorem mkHexString_some_iff (s : String) (h : HexString) :
    mkHexString s = some h ↔ (IsValidHexString s ∧ h.val = s) := by
  unfold mkHexString
  constructor
  · intro heq
    by_cases hv : IsValidHexString s
    · rw [dif_pos hv] at heq
      have hinj := Option.some.inj heq
      exact ⟨hv, (congrArg HexString.val hinj.symm)⟩
    · rw [dif_neg hv] at heq; simp at heq
  · intro ⟨hv, hval⟩
    rw [dif_pos hv]
    congr 1
    cases h with | mk av ap =>
      simp only [] at hval
      subst hval
      exact congrArg (HexString.mk av) (proof_irrel hv ap)

-- ============================================================================
-- 6. PROOF: hexStringToString is Injective
-- ============================================================================

theorem hexStringToString_injective :
    Function.Injective hexStringToString := by
  intro ⟨s₁, h₁⟩ ⟨s₂, h₂⟩ heq
  simp [hexStringToString] at heq
  subst heq; rfl

-- ============================================================================
-- 7. PROOF: Roundtrip
-- ============================================================================

theorem mkHexString_hexStringToString_roundtrip (h : HexString) :
    mkHexString (hexStringToString h) = some h := by
  obtain ⟨s, hs⟩ := h
  unfold hexStringToString mkHexString
  rw [dif_pos hs]

-- ============================================================================
-- 8. Structural Invariants
-- ============================================================================

theorem hexString_startsWith0x (h : HexString) : startsWith0x h.val = true :=
  h.property.1

theorem hexString_hex_body (h : HexString) : isHexBody (strDrop2 h.val) = true :=
  h.property.2

theorem hexString_nonempty (h : HexString) : h.val ≠ "" := by
  intro heq
  have hstart := hexString_startsWith0x h
  rw [heq] at hstart
  exact absurd hstart (by decide)

/-- If startsWith0x s = true then s has at least 2 characters. -/
theorem startsWith0x_implies_length_ge2 (s : String) (h : startsWith0x s = true) :
    2 ≤ s.toList.length := by
  unfold startsWith0x at h
  cases hs : s.toList with
  | nil =>
    rw [hs] at h; simp at h
  | cons c rest =>
    cases rest with
    | nil =>
      -- s.toList = [c]; match gives false
      rw [hs] at h; simp at h
    | cons d rest2 =>
      -- s.toList = c :: d :: rest2; length = rest2.length + 2
      simp [List.length_cons]

theorem hexString_length_ge_2 (h : HexString) : 2 ≤ h.val.length := by
  have hge := startsWith0x_implies_length_ge2 h.val (hexString_startsWith0x h)
  rwa [String.length_toList] at hge

/-!
## Verified Properties

1. **Soundness** (`mkHexString_sound`)
2. **Completeness** (`mkHexString_none_iff_invalid`)
3. **Full characterization** (`mkHexString_some_iff`)
4. **Injectivity** (`hexStringToString_injective`)
5. **Roundtrip** (`mkHexString_hexStringToString_roundtrip`)
6. **Structural invariants**: starts "0x", hex body, non-empty, length ≥ 2
-/
