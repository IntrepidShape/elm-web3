/-
  elm-web3 Proof P17: SignState Machine Invariants (Lean 4)

  Models src/Web3/Sign.elm — the `SignState` type, `isSignTerminal`,
  `startSign`, and `signUpdate` — and proves:

    1. isSignTerminal characterization: terminal ↔ state ∈ {Signed, SignFailed, SignRejected}
    2. Terminal absorption: isSignTerminal s → signUpdate msg s = s
    3. startSign only transitions SignIdle → SignPending; all other states unchanged
    4. startSign result is never terminal
    5. Matching id transitions: SignPending pendingId + msg carrying pendingId → terminal
    6. Non-matching id: different id → state unchanged
    7. SignIdle is a no-op for signUpdate
    8. Termination characterization: the only path to a terminal state is
       SignIdle → (startSign) → SignPending id → (signUpdate matching msg) → terminal

  To check:
    $ lean proofs/lean/SignState.lean
-/

-- ============================================================================
-- 1. Types (mirroring src/Web3/Sign.elm)
-- ============================================================================

inductive SignState where
  | SignIdle     : SignState
  | SignPending  : String → SignState
  | Signed       : String → String → SignState
  | SignFailed   : String → String → SignState
  | SignRejected : String → SignState
  deriving Repr, DecidableEq

inductive SignMsg where
  | SignResponse : String → String → SignMsg  -- id, signature
  | SignError    : String → String → SignMsg  -- id, error
  | SignCancel   : String → SignMsg           -- id
  deriving Repr, DecidableEq

-- ============================================================================
-- 2. State machine functions (faithful to Elm)
-- ============================================================================

def isSignTerminal : SignState → Bool
  | .Signed _ _    => true
  | .SignFailed _ _ => true
  | .SignRejected _ => true
  | _              => false

def startSign (id : String) (s : SignState) : SignState :=
  match s with
  | .SignIdle => .SignPending id
  | _        => s

private def signUpdateNonTerminal (msg : SignMsg) (s : SignState) : SignState :=
  match msg with
  | .SignResponse id sig =>
      match s with
      | .SignPending pendingId => if pendingId == id then .Signed id sig else s
      | _ => s
  | .SignError id err =>
      match s with
      | .SignPending pendingId => if pendingId == id then .SignFailed id err else s
      | _ => s
  | .SignCancel id =>
      match s with
      | .SignPending pendingId => if pendingId == id then .SignRejected id else s
      | _ => s

def signUpdate (msg : SignMsg) (s : SignState) : SignState :=
  if isSignTerminal s then s else signUpdateNonTerminal msg s

-- ============================================================================
-- 3. isSignTerminal characterization
-- ============================================================================

theorem isSignTerminal_true_iff (s : SignState) :
    isSignTerminal s = true ↔
    (∃ id sig, s = .Signed id sig) ∨
    (∃ id err, s = .SignFailed id err) ∨
    (∃ id, s = .SignRejected id) := by
  cases s <;> simp [isSignTerminal]

theorem isSignTerminal_false_iff (s : SignState) :
    isSignTerminal s = false ↔
    s = .SignIdle ∨ (∃ id, s = .SignPending id) := by
  cases s <;> simp [isSignTerminal]

-- ============================================================================
-- 4. Terminal absorption
-- ============================================================================

theorem signUpdate_terminal (msg : SignMsg) (s : SignState)
    (h : isSignTerminal s = true) : signUpdate msg s = s := by
  simp [signUpdate, h]

theorem signUpdate_terminal_signed (msg : SignMsg) (id sig : String) :
    signUpdate msg (.Signed id sig) = .Signed id sig :=
  signUpdate_terminal msg _ (by simp [isSignTerminal])

theorem signUpdate_terminal_failed (msg : SignMsg) (id err : String) :
    signUpdate msg (.SignFailed id err) = .SignFailed id err :=
  signUpdate_terminal msg _ (by simp [isSignTerminal])

theorem signUpdate_terminal_rejected (msg : SignMsg) (id : String) :
    signUpdate msg (.SignRejected id) = .SignRejected id :=
  signUpdate_terminal msg _ (by simp [isSignTerminal])

-- ============================================================================
-- 5. startSign behavior
-- ============================================================================

@[simp]
theorem startSign_idle (id : String) :
    startSign id .SignIdle = .SignPending id := rfl

theorem startSign_nonidle (id : String) (s : SignState) (h : s ≠ .SignIdle) :
    startSign id s = s := by
  cases s <;> simp [startSign] at *

/-- The result of startSign is never terminal — you always land in SignPending. -/
theorem startSign_result_not_terminal (id : String) :
    isSignTerminal (startSign id .SignIdle) = false := by
  simp [startSign, isSignTerminal]

/-- startSign is a no-op on terminal states. -/
theorem startSign_terminal_unchanged (id : String) (s : SignState)
    (h : isSignTerminal s = true) : startSign id s = s := by
  rcases (isSignTerminal_true_iff s).mp h with
    (⟨_, _, rfl⟩ | ⟨_, _, rfl⟩ | ⟨_, rfl⟩) <;> simp [startSign]

-- ============================================================================
-- 6. signUpdate: matching id transitions
-- ============================================================================

theorem signUpdate_response_match (id sig : String) :
    signUpdate (.SignResponse id sig) (.SignPending id) = .Signed id sig := by
  simp [signUpdate, isSignTerminal, signUpdateNonTerminal]

theorem signUpdate_error_match (id err : String) :
    signUpdate (.SignError id err) (.SignPending id) = .SignFailed id err := by
  simp [signUpdate, isSignTerminal, signUpdateNonTerminal]

theorem signUpdate_cancel_match (id : String) :
    signUpdate (.SignCancel id) (.SignPending id) = .SignRejected id := by
  simp [signUpdate, isSignTerminal, signUpdateNonTerminal]

-- ============================================================================
-- 7. signUpdate: non-matching id is a no-op
-- ============================================================================

theorem signUpdate_response_nomatch (pendingId id sig : String) (h : pendingId ≠ id) :
    signUpdate (.SignResponse id sig) (.SignPending pendingId) = .SignPending pendingId := by
  simp [signUpdate, isSignTerminal, signUpdateNonTerminal, h]

theorem signUpdate_error_nomatch (pendingId id err : String) (h : pendingId ≠ id) :
    signUpdate (.SignError id err) (.SignPending pendingId) = .SignPending pendingId := by
  simp [signUpdate, isSignTerminal, signUpdateNonTerminal, h]

theorem signUpdate_cancel_nomatch (pendingId id : String) (h : pendingId ≠ id) :
    signUpdate (.SignCancel id) (.SignPending pendingId) = .SignPending pendingId := by
  simp [signUpdate, isSignTerminal, signUpdateNonTerminal, h]

-- ============================================================================
-- 8. SignIdle is a no-op for signUpdate
-- ============================================================================

theorem signUpdate_idle (msg : SignMsg) :
    signUpdate msg .SignIdle = .SignIdle := by
  simp only [signUpdate, isSignTerminal, signUpdateNonTerminal]
  cases msg <;> rfl

-- ============================================================================
-- 9. Matching updates produce terminal states
-- ============================================================================

theorem signUpdate_response_terminal (id sig : String) :
    isSignTerminal (signUpdate (.SignResponse id sig) (.SignPending id)) = true := by
  rw [signUpdate_response_match]; simp [isSignTerminal]

theorem signUpdate_error_terminal (id err : String) :
    isSignTerminal (signUpdate (.SignError id err) (.SignPending id)) = true := by
  rw [signUpdate_error_match]; simp [isSignTerminal]

theorem signUpdate_cancel_terminal (id : String) :
    isSignTerminal (signUpdate (.SignCancel id) (.SignPending id)) = true := by
  rw [signUpdate_cancel_match]; simp [isSignTerminal]

-- ============================================================================
-- 10. Terminal output characterization
--     A non-terminal state can only become terminal via a matching-id message
--     to a SignPending state.
-- ============================================================================

theorem signUpdate_produces_terminal_iff
    (msg : SignMsg) (s : SignState)
    (hnt : isSignTerminal s = false)
    (ht  : isSignTerminal (signUpdate msg s) = true) :
    ∃ pendingId,
      s = .SignPending pendingId ∧
      ((∃ sig, msg = .SignResponse pendingId sig) ∨
       (∃ err, msg = .SignError pendingId err) ∨
       (msg = .SignCancel pendingId)) := by
  simp only [signUpdate, hnt, Bool.false_eq_true, if_false] at ht
  rcases (isSignTerminal_false_iff s).mp hnt with rfl | ⟨pendingId, rfl⟩
  -- Case s = SignIdle
  · cases msg <;> simp [signUpdateNonTerminal, isSignTerminal] at ht
  -- Case s = SignPending pendingId
  · refine ⟨pendingId, rfl, ?_⟩
    cases msg with
    | SignResponse id sig =>
      by_cases heq : pendingId = id
      · subst heq; exact Or.inl ⟨sig, rfl⟩
      · simp [signUpdateNonTerminal, heq, isSignTerminal] at ht
    | SignError id err =>
      by_cases heq : pendingId = id
      · subst heq; exact Or.inr (Or.inl ⟨err, rfl⟩)
      · simp [signUpdateNonTerminal, heq, isSignTerminal] at ht
    | SignCancel id =>
      by_cases heq : pendingId = id
      · subst heq; exact Or.inr (Or.inr rfl)
      · simp [signUpdateNonTerminal, heq, isSignTerminal] at ht

/-!
## Verified Properties (no sorry)

1. **isSignTerminal characterization**
   (`isSignTerminal_true_iff`, `isSignTerminal_false_iff`)

2. **Terminal absorption** (`signUpdate_terminal`, `signUpdate_terminal_*`):
   `isSignTerminal s = true → signUpdate msg s = s`

3. **startSign behavior** (`startSign_idle`, `startSign_nonidle`,
   `startSign_result_not_terminal`, `startSign_terminal_unchanged`):
   - `startSign id SignIdle = SignPending id`
   - Non-idle states unchanged
   - Result is never terminal

4. **Matching id transitions** (`signUpdate_response_match`, `signUpdate_error_match`,
   `signUpdate_cancel_match`):
   `signUpdate (SignResponse id sig) (SignPending id) = Signed id sig` (and analogues)

5. **Non-matching id no-ops** (`signUpdate_*_nomatch`):
   `pendingId ≠ id → signUpdate (SignResponse id sig) (SignPending pendingId) = SignPending pendingId`

6. **Idle no-op** (`signUpdate_idle`):
   `signUpdate msg SignIdle = SignIdle`

7. **Matching updates are terminal** (`signUpdate_*_terminal`)

8. **Terminal output characterization** (`signUpdate_produces_terminal_iff`):
   The only way a non-terminal state becomes terminal is if `s = SignPending pendingId`
   and `msg` carries a matching `pendingId`.
-/
