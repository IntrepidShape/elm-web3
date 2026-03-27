/-
  elm-web3 Proof P9: Address Type Formal Verification (Lean 4)

  Models the Address opaque type from src/Web3/Types.elm and proves:
    1. Soundness: the `address` constructor only produces `some` for valid strings
    2. Injectivity: `addressToString` is injective
    3. Roundtrip: re-validating an extracted address always succeeds

  The Elm implementation:
    - Lowercases the input, checks 0x + length 42 + all lowercase hex, wraps.

  To check:
    $ lean proofs/lean/Address.lean
-/

-- ============================================================================
-- 1. Character and String Predicates
-- ============================================================================

/-- A character is a lowercase hex digit: 0-9, a-f. -/
def isLowerHexDigit (c : Char) : Bool :=
  ('0' ≤ c && c ≤ '9') || ('a' ≤ c && c ≤ 'f')

/-- All chars in a list are lowercase hex. -/
def isLowerHexBody (cs : List Char) : Bool :=
  cs.all isLowerHexDigit

/-- Drop first 2 chars as a new String. -/
def addrDrop2 (s : String) : List Char :=
  s.toList.drop 2

/-- A string starts with "0x". -/
def startsWith0x (s : String) : Bool :=
  match s.toList with
  | '0' :: 'x' :: _ => true
  | _               => false

-- ============================================================================
-- 2. Validity Predicate
-- ============================================================================

def IsValidAddress (s : String) : Prop :=
  startsWith0x s = true ∧
  s.length = 42 ∧
  isLowerHexBody (addrDrop2 s) = true

instance : Decidable (IsValidAddress s) :=
  inferInstanceAs (Decidable (_ ∧ _ ∧ _))

-- ============================================================================
-- 3. Address Type and Constructor
-- ============================================================================

structure Address where
  val      : String
  property : IsValidAddress val
  deriving Repr

/-- Lowercase a hex-range character: maps A-F → a-f, identity elsewhere. -/
def toLowerHex (c : Char) : Char :=
  if 'A' ≤ c ∧ c ≤ 'F' then
    Char.ofNat (c.toNat - 'A'.toNat + 'a'.toNat)
  else
    c

/-- Lowercase all characters in a string. -/
def toLowerString (s : String) : String :=
  String.ofList (s.toList.map toLowerHex)

def mkAddress (s : String) : Option Address :=
  let lower := toLowerString s
  if h : IsValidAddress lower then some ⟨lower, h⟩ else none

def addressToString (a : Address) : String := a.val

-- ============================================================================
-- 4. Soundness
-- ============================================================================

theorem mkAddress_sound (s : String) (a : Address) (_ : mkAddress s = some a) :
    IsValidAddress a.val :=
  a.property

theorem mkAddress_none_iff_invalid (s : String) :
    mkAddress s = none ↔ ¬ IsValidAddress (toLowerString s) := by
  unfold mkAddress
  constructor
  · intro h
    by_cases hv : IsValidAddress (toLowerString s)
    · simp [dif_pos hv] at h
    · exact hv
  · intro h
    by_cases hv : IsValidAddress (toLowerString s)
    · exact absurd hv h
    · simp [dif_neg hv]

theorem mkAddress_some_iff (s : String) (a : Address) :
    mkAddress s = some a ↔
    (IsValidAddress (toLowerString s) ∧ a.val = toLowerString s) := by
  unfold mkAddress
  constructor
  · intro h
    by_cases hv : IsValidAddress (toLowerString s)
    · rw [dif_pos hv] at h
      exact ⟨hv, (congrArg Address.val (Option.some.inj h).symm)⟩
    · rw [dif_neg hv] at h; simp at h
  · intro ⟨hv, hval⟩
    rw [dif_pos hv]; congr 1
    cases a with | mk av ap =>
      simp only [] at hval; subst hval
      exact congrArg (Address.mk (toLowerString s)) (proof_irrel hv ap)

-- ============================================================================
-- 5. Injectivity
-- ============================================================================

theorem addressToString_injective :
    Function.Injective addressToString := by
  intro ⟨s₁, h₁⟩ ⟨s₂, h₂⟩ heq
  simp [addressToString] at heq
  subst heq; rfl

-- ============================================================================
-- 6. Roundtrip — helpers
-- ============================================================================

/-- `startsWith0x s = true → ∃ rest, s.toList = '0' :: 'x' :: rest`. -/
theorem startsWith0x_decomp (s : String) (h : startsWith0x s = true) :
    ∃ rest, s.toList = '0' :: 'x' :: rest := by
  unfold startsWith0x at h
  match hs : s.toList with
  | '0' :: 'x' :: rest => exact ⟨rest, rfl⟩
  | []         => simp [hs] at h
  | [c]        => simp [hs] at h
  | c :: d :: rest =>
    -- In this arm c ≠ '0' or d ≠ 'x' (otherwise the first arm would match).
    -- Either way, startsWith0x = false, contradicting h.
    -- We establish the contradiction by showing the match gives false.
    -- Since c :: d :: rest didn't match '0' :: 'x' :: _, either c ≠ '0' or d ≠ 'x'.
    -- Lean 4 iota-reduces the match to false in both sub-cases.
    simp only [hs] at h
    -- h : (match c :: d :: rest with | '0' :: 'x' :: _ => true | _ => false) = true
    -- We do case analysis on c and d.
    by_cases hc : c = '0'
    · by_cases hd : d = 'x'
      · -- c = '0', d = 'x', so this IS '0' :: 'x' :: rest — but then the first arm
        -- of our outer match should have caught it. Contradiction in Lean's elaboration:
        -- both 'hc' and 'hd' + 'hs' together imply s.toList = '0' :: 'x' :: rest.
        subst hc; subst hd
        exact ⟨rest, rfl⟩
      · subst hc
        simp [hd] at h
    · simp [hc] at h

/-- `toLowerHex` is the identity on lowercase hex digits. -/
theorem toLowerHex_idempotent (c : Char) (h : isLowerHexDigit c = true) :
    toLowerHex c = c := by
  unfold isLowerHexDigit at h
  simp [Bool.or_eq_true, Bool.and_eq_true] at h
  unfold toLowerHex
  by_cases hAF : 'A' ≤ c ∧ c ≤ 'F'
  · rw [if_pos hAF]
    rcases h with ⟨_, h9⟩ | ⟨ha, _⟩
    · exfalso; exact absurd (Trans.trans hAF.1 h9) (by decide)
    · exfalso; exact absurd (Trans.trans ha hAF.2) (by decide)
  · simp [hAF]

/-- `toLowerHex '0' = '0'` and `toLowerHex 'x' = 'x'`. -/
theorem toLowerHex_zero : toLowerHex '0' = '0' := by decide
theorem toLowerHex_x    : toLowerHex 'x' = 'x' := by decide

/-- A lowercase hex body is a fixed point of `map toLowerHex`. -/
theorem isLowerHexBody_map_id (cs : List Char) (h : isLowerHexBody cs = true) :
    cs.map toLowerHex = cs := by
  induction cs with
  | nil => rfl
  | cons c cs ih =>
    simp only [isLowerHexBody, List.all_cons, Bool.and_eq_true] at h
    simp [List.map, toLowerHex_idempotent c h.1, ih h.2]

/-- `toLowerString` is idempotent on valid addresses: already lowercase → no-op. -/
theorem toLowerString_idem (s : String) (h : isLowerHexBody (addrDrop2 s) = true)
    (hstart : startsWith0x s = true) : toLowerString s = s := by
  unfold toLowerString
  suffices heq : s.toList.map toLowerHex = s.toList by
    rw [heq]; exact String.ofList_toList
  obtain ⟨body, hbody⟩ := startsWith0x_decomp s hstart
  have hbody_hex : isLowerHexBody body = true := by
    have hd2 : addrDrop2 s = body := by unfold addrDrop2; simp [hbody]
    rwa [← hd2]
  rw [hbody, List.map_cons, List.map_cons, toLowerHex_zero, toLowerHex_x,
      isLowerHexBody_map_id body hbody_hex]

-- ============================================================================
-- 7. Roundtrip Theorem
-- ============================================================================

theorem mkAddress_addressToString_roundtrip (a : Address) :
    mkAddress (addressToString a) = some a := by
  obtain ⟨s, hs⟩ := a
  show mkAddress s = some ⟨s, hs⟩
  -- toLowerString s = s (s is already normalized)
  have hls : toLowerString s = s :=
    toLowerString_idem s hs.2.2 hs.1
  -- Now mkAddress s = mkAddress s with lower = s
  unfold mkAddress
  simp only [hls]
  rw [dif_pos hs]

-- ============================================================================
-- 8. Structural Invariants
-- ============================================================================

theorem address_length (a : Address) : a.val.length = 42 :=
  a.property.2.1

theorem address_startsWith0x (a : Address) : startsWith0x a.val = true :=
  a.property.1

theorem address_hex_body (a : Address) : isLowerHexBody (addrDrop2 a.val) = true :=
  a.property.2.2

theorem address_nonempty (a : Address) : a.val ≠ "" := by
  intro h
  have := address_length a
  rw [h] at this; simp at this

/-!
## Verified Properties

1. **Soundness** (`mkAddress_sound`)
2. **Completeness** (`mkAddress_none_iff_invalid`)
3. **Full characterization** (`mkAddress_some_iff`)
4. **Injectivity** (`addressToString_injective`)
5. **Roundtrip** (`mkAddress_addressToString_roundtrip`)
6. **Structural invariants**: length=42, starts "0x", lowercase hex body, non-empty
-/
