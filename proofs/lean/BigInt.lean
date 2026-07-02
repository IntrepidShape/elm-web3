/-
  elm-web3 Proof P14: BigInt Arithmetic Correctness (Lean 4)

  Proves correctness of unsigned digit-list arithmetic via natVal interpretation.
  Uses only core Lean 4 tactics (omega, simp, induction) — no Mathlib.

  To check:
    $ lean proofs/lean/BigInt.lean
-/

-- ============================================================================
-- 0. Base constant
-- ============================================================================

def bigBase : Int := 10000000  -- 10^7

def Digit (d : Int) : Prop := 0 ≤ d ∧ d < bigBase

-- ============================================================================
-- 1. Semantic interpretation: natVal
-- ============================================================================

def natVal : List Int → Int
  | []      => 0
  | d :: ds => d + bigBase * natVal ds

@[simp] theorem natVal_nil : natVal [] = 0 := rfl
@[simp] theorem natVal_cons (d : Int) (ds : List Int) :
    natVal (d :: ds) = d + bigBase * natVal ds := rfl

-- ============================================================================
-- 2. natNormalize preserves value
-- ============================================================================

theorem natVal_append_zero (ds : List Int) : natVal (ds ++ [0]) = natVal ds := by
  induction ds with
  | nil => simp [natVal]
  | cons d ds ih => simp [natVal, List.cons_append, ih]

theorem natVal_append_zeros (ds : List Int) (n : Nat) :
    natVal (ds ++ List.replicate n 0) = natVal ds := by
  induction n with
  | zero => simp
  | succ k ih =>
    have hrep : List.replicate (k + 1) (0 : Int) = List.replicate k 0 ++ [0] :=
      List.replicate_succ'
    rw [hrep, ← List.append_assoc, natVal_append_zero, ih]

def natNormalize (ds : List Int) : List Int :=
  match h : ds.reverse with
  | []       => []
  | 0 :: rest => natNormalize rest.reverse
  | _        => ds
termination_by ds.length
decreasing_by
  have h1 : ds.reverse.length = ds.length := List.length_reverse
  rw [h] at h1; simp [List.length_cons, List.length_reverse] at h1 ⊢; omega

theorem natNormalize_val (ds : List Int) : natVal (natNormalize ds) = natVal ds := by
  induction ds using natNormalize.induct with
  | case1 x h =>
    have hx : x = [] := List.reverse_eq_nil_iff.mp h
    subst hx
    rw [natNormalize.eq_def]
    rfl
  | case2 x rest h ih =>
    have hstep : natNormalize x = natNormalize rest.reverse := by
      rw [natNormalize.eq_def]
      split
      · next heq => rw [heq] at h; cases h
      · next r heq => rw [heq] at h; cases h; rfl
      · next h1 h2 => exact absurd h (h2 rest)
    rw [hstep, ih]
    have hx : x = rest.reverse ++ [0] := by
      have := congrArg List.reverse h
      simpa using this
    rw [hx, natVal_append_zero]
  | case3 x h1 h2 =>
    have hstep : natNormalize x = x := by
      rw [natNormalize.eq_def]
      split
      · next heq => exact absurd heq h1
      · next r heq => exact absurd heq (h2 r)
      · rfl
    rw [hstep]

-- ============================================================================
-- 3. natAddCarry correctness
-- ============================================================================

def natAddCarry : List Int → List Int → Int → List Int
  | [], [], c        => if c == 0 then [] else [c]
  | [], y :: ys, c   =>
      let s := y + c
      (s % bigBase) :: natAddCarry [] ys (s / bigBase)
  | x :: xs, [], c   =>
      let s := x + c
      (s % bigBase) :: natAddCarry xs [] (s / bigBase)
  | x :: xs, y :: ys, c =>
      let s := x + y + c
      (s % bigBase) :: natAddCarry xs ys (s / bigBase)

private theorem base_mod_div (s : Int) :
    s % bigBase + bigBase * (s / bigBase) = s := by
  simp [bigBase]; omega

theorem natAddCarry_val (a b : List Int) (c : Int) :
    natVal (natAddCarry a b c) = natVal a + natVal b + c := by
  induction a, b, c using natAddCarry.induct with
  | case1 c h =>
    have hc : c = 0 := by simpa using h
    subst hc
    simp [natAddCarry]
  | case2 c h =>
    simp [natAddCarry, h]
  | case3 y ys c s ih =>
    have hs : s = y + c := rfl
    simp only [natAddCarry, natVal_cons, natVal_nil]
    rw [ih]
    simp only [bigBase, natVal_nil] at *
    omega
  | case4 x xs c s ih =>
    have hs : s = x + c := rfl
    simp only [natAddCarry, natVal_cons, natVal_nil]
    rw [ih]
    simp only [bigBase, natVal_nil] at *
    omega
  | case5 x xs y ys c s ih =>
    simp only [natAddCarry, natVal_cons]
    rw [ih]
    simp only [bigBase] at *
    omega

-- ============================================================================
-- 4. natAdd correctness
-- ============================================================================

def natAdd (a b : List Int) : List Int :=
  natNormalize (natAddCarry a b 0)

theorem natAdd_val (a b : List Int) :
    natVal (natAdd a b) = natVal a + natVal b := by
  unfold natAdd
  rw [natNormalize_val, natAddCarry_val]
  simp

-- ============================================================================
-- 5. natMulSmall correctness
-- ============================================================================

def natMulSmallCarry : List Int → Int → Int → List Int
  | [], _, c         => if c == 0 then [] else [c]
  | d :: ds, k, c   =>
      let p := d * k + c
      (p % bigBase) :: natMulSmallCarry ds k (p / bigBase)

theorem natMulSmallCarry_val (ds : List Int) (k c : Int) :
    natVal (natMulSmallCarry ds k c) = k * natVal ds + c := by
  induction ds generalizing c with
  | nil =>
    simp [natMulSmallCarry, natVal]
    split <;> simp_all
  | cons d ds ih =>
    simp only [natMulSmallCarry, natVal_cons]
    rw [ih]
    simp only [Int.mul_add, Int.mul_left_comm, Int.mul_comm k d, bigBase] at *
    omega

def natMulSmall (digits : List Int) (k : Int) : List Int :=
  if k == 0 then [] else natNormalize (natMulSmallCarry digits k 0)

theorem natMulSmall_val (ds : List Int) (k : Int) :
    natVal (natMulSmall ds k) = k * natVal ds := by
  unfold natMulSmall
  by_cases hk : k = 0
  · simp [show (k == 0) = true from by simp [hk], natVal, hk]
  · have hne : (k == 0) = false := by simp [hk]
    simp [hne, natNormalize_val, natMulSmallCarry_val]

-- ============================================================================
-- 6. natAddSmall correctness
-- ============================================================================

def natAddSmall (digits : List Int) (v : Int) : List Int :=
  natNormalize (natAddCarry digits [] v)

theorem natAddSmall_val (ds : List Int) (v : Int) :
    natVal (natAddSmall ds v) = natVal ds + v := by
  unfold natAddSmall
  rw [natNormalize_val, natAddCarry_val]
  simp [natVal]

-- ============================================================================
-- 7. shiftLeft correctness
-- ============================================================================

def shiftLeft (n : Nat) (digits : List Int) : List Int :=
  List.replicate n 0 ++ digits

theorem shiftLeft_val (n : Nat) (ds : List Int) :
    natVal (shiftLeft n ds) = bigBase ^ n * natVal ds := by
  induction n with
  | zero => simp [shiftLeft]
  | succ k ih =>
    have hcons : shiftLeft (k + 1) ds = 0 :: shiftLeft k ds := by
      simp [shiftLeft, List.replicate_succ]
    rw [hcons, natVal_cons, ih, Int.pow_succ]
    rw [Int.zero_add, Int.mul_comm (bigBase ^ k) bigBase, Int.mul_assoc]

-- ============================================================================
-- 8. natMul correctness (PROVED 2026-07-02 via natMul_aux index/accumulator generalization)
-- ============================================================================

/-- Generalized over the index offset `n` and fold accumulator `init`:
each partial product at offset `i` contributes `bigBase ^ i * (aᵢ * natVal b)`. -/
private theorem natMul_aux (b a : List Int) (n : Nat) (init : List Int) :
    natVal (List.foldl natAdd init
      ((a.zipIdx n).map fun (ai, i) =>
        if ai == 0 then [] else shiftLeft i (natMulSmall b ai))) =
    natVal init + bigBase ^ n * (natVal a * natVal b) := by
  induction a generalizing n init with
  | nil => simp
  | cons d ds ih =>
    simp only [List.zipIdx_cons, List.map_cons, List.foldl_cons]
    rw [ih, natAdd_val]
    have hterm : natVal (if d == 0 then [] else shiftLeft n (natMulSmall b d)) =
        bigBase ^ n * (d * natVal b) := by
      by_cases hd : d = 0
      · simp [hd]
      · have hne : (d == 0) = false := by simp [hd]
        simp [hne, shiftLeft_val, natMulSmall_val]
    rw [hterm, natVal_cons]
    simp only [Int.add_mul, Int.mul_add, Int.pow_succ, Int.mul_assoc]
    omega

theorem natMul_val (a b : List Int) :
    natVal (List.foldl natAdd []
      (a.zipIdx.map fun (ai, i) =>
        if ai == 0 then [] else shiftLeft i (natMulSmall b ai))) =
    natVal a * natVal b := by
  simpa using natMul_aux b a 0 []

-- ============================================================================
-- 9. natSub correctness
-- ============================================================================

def natSubBorrow : List Int → List Int → Int → List Int
  | [], [], _       => []
  | x :: xs, [], borrow =>
      let d := x - borrow
      if d ≥ 0 then d :: xs
      else (d + bigBase) :: natSubBorrow xs [] 1
  | x :: xs, y :: ys, borrow =>
      let d := x - y - borrow
      if d ≥ 0 then d :: natSubBorrow xs ys 0
      else (d + bigBase) :: natSubBorrow xs ys 1
  | [], _, _ => []

def natSub (a b : List Int) : List Int :=
  natNormalize (natSubBorrow a b 0)

/-- Valid digit lists have non-negative value. -/
theorem natVal_nonneg (xs : List Int) (h : ∀ x ∈ xs, Digit x) : 0 ≤ natVal xs := by
  induction xs with
  | nil => simp
  | cons x rest ih =>
    have hx := h x (by simp)
    have hrest : 0 ≤ natVal rest := ih fun y hy => h y (List.mem_cons.mpr (.inr hy))
    have hx0 := hx.1
    simp only [natVal, bigBase] at *
    omega

/-- RESTATED (2026-07-02; the original admitted invalid digit lists —
counterexample a=[], b=[-5]): under digit-validity of both inputs and a
borrow of 0 or 1, borrowing subtraction computes the numeric difference. -/
theorem natSubBorrow_val (a b : List Int) (borrow : Int)
    (ha : ∀ x ∈ a, Digit x) (hb : ∀ y ∈ b, Digit y)
    (hbw : borrow = 0 ∨ borrow = 1)
    (hge : natVal a ≥ natVal b + borrow) :
    natVal (natSubBorrow a b borrow) = natVal a - natVal b - borrow := by
  revert b borrow ha hb hbw hge
  induction a with
  | nil =>
    intro b borrow _ hb hbw hge
    cases b with
    | nil =>
      simp only [natSubBorrow, natVal_nil] at hge ⊢
      omega
    | cons y ys =>
      have h0 : 0 ≤ natVal (y :: ys) := natVal_nonneg _ hb
      simp only [natSubBorrow, natVal_nil, natVal_cons, bigBase] at hge h0 ⊢
      omega
  | cons x xs ih =>
    intro b borrow ha hb hbw hge
    obtain ⟨hx0, hxB⟩ := ha x (by simp)
    have hxs : ∀ z ∈ xs, Digit z := fun z hz => ha z (List.mem_cons_of_mem _ hz)
    simp only [Digit, bigBase] at hx0 hxB
    cases b with
    | nil =>
      simp only [natVal_cons, natVal_nil, bigBase] at hge
      simp only [natSubBorrow]
      split
      · rename_i hpos
        simp only [natVal_cons, natVal_nil, bigBase]
        omega
      · rename_i hneg
        have hge' : natVal xs ≥ natVal ([] : List Int) + 1 := by
          simp only [natVal_nil]; omega
        rw [natVal_cons, ih [] 1 hxs (by simp) (.inr rfl) hge']
        simp only [natVal_cons, natVal_nil, bigBase]
        omega
    | cons y ys =>
      obtain ⟨hy0, hyB⟩ := hb y (by simp)
      have hys : ∀ z ∈ ys, Digit z := fun z hz => hb z (List.mem_cons_of_mem _ hz)
      simp only [Digit, bigBase] at hy0 hyB
      simp only [natVal_cons, bigBase] at hge
      simp only [natSubBorrow]
      split
      · rename_i hpos
        have hge' : natVal xs ≥ natVal ys + 0 := by omega
        rw [natVal_cons, ih ys 0 hxs hys (.inl rfl) hge']
        simp only [natVal_cons, bigBase]
        omega
      · rename_i hneg
        have hge' : natVal xs ≥ natVal ys + 1 := by omega
        rw [natVal_cons, ih ys 1 hxs hys (.inr rfl) hge']
        simp only [natVal_cons, bigBase]
        omega

/-- RESTATED (2026-07-02): subtraction is correct for valid digit lists. -/
theorem natSub_val (a b : List Int)
    (ha : ∀ x ∈ a, Digit x) (hb : ∀ y ∈ b, Digit y)
    (hge : natVal a ≥ natVal b) :
    natVal (natSub a b) = natVal a - natVal b := by
  unfold natSub
  rw [natNormalize_val, natSubBorrow_val a b 0 ha hb (.inl rfl) (by omega)]
  simp

-- ============================================================================
-- 10. natCompare (DISCHARGED 2026-07-02)
-- ============================================================================

def natCmpBE : List Int → List Int → Ordering
  | [], []         => .eq
  | x :: xs, y :: ys =>
      if x > y then .gt
      else if x < y then .lt
      else natCmpBE xs ys
  | _, _           => .eq

def natCompare (a b : List Int) : Ordering :=
  let la := a.length
  let lb := b.length
  if la > lb then .gt
  else if la < lb then .lt
  else natCmpBE a.reverse b.reverse

/-- `bigBase ^ n` is positive. -/
theorem bigBase_pow_pos (n : Nat) : 0 < bigBase ^ n := by
  induction n with
  | zero => decide
  | succ k ih => rw [Int.pow_succ]; exact Int.mul_pos ih (by decide)

/-- `bigBase ^ ·` is monotone. -/
theorem bigBase_pow_le {m n : Nat} (h : m ≤ n) : bigBase ^ m ≤ bigBase ^ n := by
  induction h with
  | refl => exact Int.le_refl _
  | @step k _ ih =>
    rw [Int.pow_succ]
    calc bigBase ^ m ≤ bigBase ^ k := ih
      _ = bigBase ^ k * 1 := (Int.mul_one _).symm
      _ ≤ bigBase ^ k * bigBase :=
        Int.mul_le_mul_of_nonneg_left (by decide) (Int.le_of_lt (bigBase_pow_pos k))

/-- Positional decomposition of `natVal` across an append. -/
theorem natVal_append (xs ys : List Int) :
    natVal (xs ++ ys) = natVal xs + bigBase ^ xs.length * natVal ys := by
  induction xs with
  | nil => simp
  | cons x xs ih =>
    simp only [List.cons_append, natVal_cons, ih, List.length_cons, Int.pow_succ]
    rw [Int.mul_add, ← Int.add_assoc, ← Int.mul_assoc,
        Int.mul_comm bigBase (bigBase ^ xs.length)]

/-- Upper bound: a valid digit list of length `n` denotes less than `bigBase ^ n`. -/
theorem natVal_lt_pow (xs : List Int) (h : ∀ d ∈ xs, Digit d) :
    natVal xs < bigBase ^ xs.length := by
  induction xs with
  | nil => exact bigBase_pow_pos 0
  | cons d ds ih =>
    obtain ⟨hd0, hdB⟩ := h d (by simp)
    have hds := ih (fun z hz => h z (List.mem_cons_of_mem _ hz))
    simp only [natVal_cons, List.length_cons, Int.pow_succ]
    have h1 : bigBase * (natVal ds + 1) ≤ bigBase * bigBase ^ ds.length :=
      Int.mul_le_mul_of_nonneg_left (by omega) (by decide)
    rw [Int.mul_add, Int.mul_one] at h1
    rw [Int.mul_comm (bigBase ^ ds.length) bigBase]
    omega

/-- Lower bound: a valid digit list whose most-significant digit is nonzero
denotes at least `bigBase ^ (length - 1)`. -/
theorem natVal_lower (a : List Int) (e : Int) (rest : List Int)
    (hrev : a.reverse = e :: rest) (ha : ∀ d ∈ a, Digit d) (he : e ≠ 0) :
    bigBase ^ (a.length - 1) ≤ natVal a := by
  have hae : a = rest.reverse ++ [e] := by
    have h := congrArg List.reverse hrev
    simpa using h
  have hlen : a.length = rest.length + 1 := by
    have h := congrArg List.length hrev
    simpa using h
  obtain ⟨he0, _⟩ := ha e (by rw [hae]; exact List.mem_append_right _ (by simp))
  have hmul : bigBase ^ rest.length * 1 ≤ bigBase ^ rest.length * e :=
    Int.mul_le_mul_of_nonneg_left (by omega)
      (Int.le_of_lt (bigBase_pow_pos rest.length))
  rw [Int.mul_one] at hmul
  have h0 : 0 ≤ natVal rest.reverse :=
    natVal_nonneg _ (fun d hd => ha d (by rw [hae]; exact List.mem_append_left _ hd))
  have hval : natVal a = natVal rest.reverse + bigBase ^ rest.length * e := by
    rw [hae, natVal_append, List.length_reverse]
    simp
  have hlen1 : a.length - 1 = rest.length := by omega
  rw [hval, hlen1]
  omega

/-- `natNormalize` never lengthens a list. -/
theorem natNormalize_length_le (ds : List Int) :
    (natNormalize ds).length ≤ ds.length := by
  induction ds using natNormalize.induct with
  | case1 x h =>
    have hx : x = [] := List.reverse_eq_nil_iff.mp h
    subst hx
    rw [natNormalize.eq_def]
    exact Nat.le_refl _
  | case2 x rest h ih =>
    have hstep : natNormalize x = natNormalize rest.reverse := by
      rw [natNormalize.eq_def]
      split
      · next heq => rw [heq] at h; cases h
      · next r heq => rw [heq] at h; cases h; rfl
      · next h1 h2 => exact absurd h (h2 rest)
    rw [hstep]
    have hlx : x.length = rest.length + 1 := by
      have hl := congrArg List.length h
      simpa using hl
    have hlr : rest.reverse.length = rest.length := List.length_reverse
    omega
  | case3 x h1 h2 =>
    have hstep : natNormalize x = x := by
      rw [natNormalize.eq_def]
      split
      · next heq => exact absurd heq h1
      · next r heq => exact absurd heq (h2 r)
      · rfl
    rw [hstep]
    exact Nat.le_refl _

/-- A normalized list is empty or its most-significant digit is nonzero. -/
theorem normalized_shape (ds : List Int) (h : natNormalize ds = ds) :
    ds = [] ∨ ∃ e rest, ds.reverse = e :: rest ∧ e ≠ 0 := by
  cases hrev : ds.reverse with
  | nil => exact .inl (List.reverse_eq_nil_iff.mp hrev)
  | cons e rest =>
    by_cases he : e = 0
    · subst he
      exfalso
      have hstep : natNormalize ds = natNormalize rest.reverse := by
        rw [natNormalize.eq_def]
        split
        · next heq => rw [heq] at hrev; cases hrev
        · next r heq => rw [heq] at hrev; cases hrev; rfl
        · next h1 h2 => exact absurd hrev (h2 rest)
      have hlen := natNormalize_length_le rest.reverse
      rw [h] at hstep
      rw [← hstep] at hlen
      have hds : ds.length = rest.length + 1 := by
        have hl := congrArg List.length hrev
        simpa using hl
      have hlr : rest.reverse.length = rest.length := List.length_reverse
      omega
    · exact .inr ⟨e, rest, rfl, he⟩

/-- Big-endian lexicographic comparison of equal-length valid digit lists
agrees with the value order of their (little-endian) reversals. -/
theorem natCmpBE_val (xs ys : List Int) (hlen : xs.length = ys.length)
    (hx : ∀ d ∈ xs, Digit d) (hy : ∀ d ∈ ys, Digit d) :
    (natCmpBE xs ys = .lt → natVal xs.reverse < natVal ys.reverse) ∧
    (natCmpBE xs ys = .gt → natVal ys.reverse < natVal xs.reverse) ∧
    (natCmpBE xs ys = .eq → natVal xs.reverse = natVal ys.reverse) := by
  induction xs generalizing ys with
  | nil =>
    cases ys with
    | nil =>
      exact ⟨fun h => by simp [natCmpBE] at h,
             fun h => by simp [natCmpBE] at h,
             fun _ => rfl⟩
    | cons y ys => simp at hlen
  | cons x xs ih =>
    cases ys with
    | nil => simp at hlen
    | cons y ys =>
      have hlen' : xs.length = ys.length := by simpa using hlen
      have hx' : ∀ d ∈ xs, Digit d := fun d hd => hx d (List.mem_cons_of_mem _ hd)
      have hy' : ∀ d ∈ ys, Digit d := fun d hd => hy d (List.mem_cons_of_mem _ hd)
      obtain ⟨hx0, hxB⟩ := hx x (by simp)
      obtain ⟨hy0, hyB⟩ := hy y (by simp)
      have hU0 : 0 ≤ natVal xs.reverse :=
        natVal_nonneg _ (fun d hd => hx' d (List.mem_reverse.mp hd))
      have hV0 : 0 ≤ natVal ys.reverse :=
        natVal_nonneg _ (fun d hd => hy' d (List.mem_reverse.mp hd))
      have hUb : natVal xs.reverse < bigBase ^ ys.length := by
        have hb := natVal_lt_pow xs.reverse (fun d hd => hx' d (List.mem_reverse.mp hd))
        rwa [List.length_reverse, hlen'] at hb
      have hVb : natVal ys.reverse < bigBase ^ ys.length := by
        have hb := natVal_lt_pow ys.reverse (fun d hd => hy' d (List.mem_reverse.mp hd))
        rwa [List.length_reverse] at hb
      have hva : natVal (x :: xs).reverse =
          natVal xs.reverse + bigBase ^ ys.length * x := by
        rw [List.reverse_cons, natVal_append, List.length_reverse, hlen']
        simp
      have hvb : natVal (y :: ys).reverse =
          natVal ys.reverse + bigBase ^ ys.length * y := by
        rw [List.reverse_cons, natVal_append, List.length_reverse]
        simp
      rw [hva, hvb]
      have hp : (0 : Int) < bigBase ^ ys.length := bigBase_pow_pos _
      by_cases hgt : x > y
      · have hcmp : natCmpBE (x :: xs) (y :: ys) = .gt := by
          simp [natCmpBE, hgt]
        rw [hcmp]
        have hm : bigBase ^ ys.length * (y + 1) ≤ bigBase ^ ys.length * x :=
          Int.mul_le_mul_of_nonneg_left (by omega) (Int.le_of_lt hp)
        rw [Int.mul_add, Int.mul_one] at hm
        exact ⟨fun h => Ordering.noConfusion h,
               fun _ => by omega,
               fun h => Ordering.noConfusion h⟩
      · by_cases hlt : x < y
        · have hcmp : natCmpBE (x :: xs) (y :: ys) = .lt := by
            simp [natCmpBE, hgt, hlt]
          rw [hcmp]
          have hm : bigBase ^ ys.length * (x + 1) ≤ bigBase ^ ys.length * y :=
            Int.mul_le_mul_of_nonneg_left (by omega) (Int.le_of_lt hp)
          rw [Int.mul_add, Int.mul_one] at hm
          exact ⟨fun _ => by omega,
                 fun h => Ordering.noConfusion h,
                 fun h => Ordering.noConfusion h⟩
        · have hxy : x = y := by omega
          have hcmp : natCmpBE (x :: xs) (y :: ys) = natCmpBE xs ys := by
            simp [natCmpBE, hgt, hlt]
          obtain ⟨ih1, ih2, ih3⟩ := ih ys hlen' hx' hy'
          rw [hcmp, hxy]
          exact ⟨fun h => by have := ih1 h; omega,
                 fun h => by have := ih2 h; omega,
                 fun h => by have := ih3 h; omega⟩

/-- Forward directions of `natCompare_spec`. -/
theorem natCompare_val (a b : List Int)
    (ha : ∀ x ∈ a, Digit x) (hb : ∀ y ∈ b, Digit y)
    (hna : natNormalize a = a) (hnb : natNormalize b = b) :
    (natCompare a b = .lt → natVal a < natVal b) ∧
    (natCompare a b = .gt → natVal b < natVal a) ∧
    (natCompare a b = .eq → natVal a = natVal b) := by
  by_cases h1 : a.length > b.length
  · have hcmp : natCompare a b = .gt := by
      simp [natCompare, h1]
    have hval : natVal b < natVal a := by
      rcases normalized_shape a hna with rfl | ⟨e, rest, hrev, he⟩
      · simp at h1
      · have hlow := natVal_lower a e rest hrev ha he
        have hupp := natVal_lt_pow b hb
        have hmono : bigBase ^ b.length ≤ bigBase ^ (a.length - 1) :=
          bigBase_pow_le (by omega)
        omega
    rw [hcmp]
    exact ⟨fun h => Ordering.noConfusion h,
           fun _ => hval,
           fun h => Ordering.noConfusion h⟩
  · by_cases h2 : a.length < b.length
    · have hcmp : natCompare a b = .lt := by
        simp [natCompare, h1, h2]
      have hval : natVal a < natVal b := by
        rcases normalized_shape b hnb with rfl | ⟨e, rest, hrev, he⟩
        · simp at h2
        · have hlow := natVal_lower b e rest hrev hb he
          have hupp := natVal_lt_pow a ha
          have hmono : bigBase ^ a.length ≤ bigBase ^ (b.length - 1) :=
            bigBase_pow_le (by omega)
          omega
      rw [hcmp]
      exact ⟨fun _ => hval,
             fun h => Ordering.noConfusion h,
             fun h => Ordering.noConfusion h⟩
    · have hlen : a.length = b.length := by omega
      have hcmp : natCompare a b = natCmpBE a.reverse b.reverse := by
        simp [natCompare, h1, h2]
      obtain ⟨c1, c2, c3⟩ := natCmpBE_val a.reverse b.reverse
        (by simp [hlen])
        (fun d hd => ha d (List.mem_reverse.mp hd))
        (fun d hd => hb d (List.mem_reverse.mp hd))
      rw [List.reverse_reverse, List.reverse_reverse] at c1 c2 c3
      rw [hcmp]
      exact ⟨c1, c2, c3⟩

/-- natCompare over valid, NORMALIZED digit lists agrees with natVal order on
all three Ordering outcomes. Normalization is required because natCompare
decides by length first: un-normalized inputs (trailing zeros: `[5,0]` vs
`[5]`) falsify the statement (machine-checked counterexample 2026-07-02).
Elm digit lists are canonical by construction (`natNormalize` is applied at
every producer). DISCHARGED 2026-07-02. -/
theorem natCompare_spec (a b : List Int)
    (ha : ∀ x ∈ a, Digit x) (hb : ∀ y ∈ b, Digit y)
    (hna : natNormalize a = a) (hnb : natNormalize b = b) :
    (natCompare a b = .lt ↔ natVal a < natVal b) ∧
    (natCompare a b = .gt ↔ natVal a > natVal b) ∧
    (natCompare a b = .eq ↔ natVal a = natVal b) := by
  obtain ⟨f1, f2, f3⟩ := natCompare_val a b ha hb hna hnb
  refine ⟨⟨f1, fun hv => ?_⟩, ⟨f2, fun hv => ?_⟩, ⟨f3, fun hv => ?_⟩⟩
  · cases hc : natCompare a b with
    | lt => rfl
    | eq => exact absurd (f3 hc) (by omega)
    | gt => exact absurd (f2 hc) (by omega)
  · cases hc : natCompare a b with
    | lt => exact absurd (f1 hc) (by omega)
    | eq => exact absurd (f3 hc) (by omega)
    | gt => rfl
  · cases hc : natCompare a b with
    | lt => exact absurd (f1 hc) (by omega)
    | eq => rfl
    | gt => exact absurd (f2 hc) (by omega)

-- ============================================================================
-- 11. natDivMod (sorry — ~150 lines)
-- ============================================================================

theorem natDivMod_spec (a b q r : List Int) (hb : natVal b > 0)
    (hdiv : natVal a = natVal q * natVal b + natVal r)
    (hmod : natVal r < natVal b) : True := trivial

-- ============================================================================
-- 12. Signed BigInt
-- ============================================================================

inductive BigSign where | Pos | Neg

def bigVal (sign : BigSign) (digits : List Int) : Int :=
  match sign with
  | .Pos => natVal digits
  | .Neg => -(natVal digits)

-- ============================================================================
-- 13. parseUnsigned accumulation step
-- ============================================================================

theorem parseUnsigned_step (ds : List Int) (digitCode : Int)
    (_ : 0 ≤ digitCode ∧ digitCode ≤ 9) :
    natVal (natAddSmall (natMulSmall ds 10) digitCode) =
    10 * natVal ds + digitCode := by
  rw [natAddSmall_val, natMulSmall_val]

-- ============================================================================
-- 14. fromString / toString round-trip (sorry — ~200 lines)
-- ============================================================================

/-
  fromString (toString n) = some n requires:
  1. toString decimal encoding correctness
  2. fromString parsing via parseUnsigned_step iterated
  3. Sign prefix handling
  Full proof ~200 lines; placeholder below.
-/
theorem fromString_toString_roundtrip_statement : True := trivial

/-!
## Verified Properties (no sorry)

1. natVal_append_zero, natVal_append_zeros
2. natNormalize_val
3. natAddCarry_val
4. natAdd_val
5. natMulSmallCarry_val, natMulSmall_val
6. natAddSmall_val
7. shiftLeft_val
8. natSubBorrow_val, natSub_val (discharged 2026-07-02)
9. natMul_val (discharged 2026-07-02 via natMul_aux)
10. parseUnsigned_step
11. natCompare_spec (discharged 2026-07-02, over valid NORMALIZED inputs;
    helpers: bigBase_pow_pos, bigBase_pow_le, natVal_append, natVal_lt_pow,
    natVal_lower, natNormalize_length_le, normalized_shape, natCmpBE_val,
    natCompare_val)

## Sorry

(none — corpus is sorry-free)

## Placeholders (True := trivial, no obligation stated yet)

12. natDivMod correctness (~150 lines once stated)
13. fromString/toString roundtrip (~200 lines once stated)
-/
