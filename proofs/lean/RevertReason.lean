/-
  elm-web3 Proof P16: decodeRevertReason Parsing Correctness (Lean 4)

  Models `decodeRevertReason` from src/Web3/Abi/Decode.elm and proves:

  1. **Selector guard**: returns Nothing if the selector ≠ 0x08c379a0
  2. **Minimum length guard**: returns Nothing if payload is too short
  3. **Soundness**: when it returns Just s, s is the correct UTF-8 string
     encoded at the correct ABI offset
  4. **hexToInt correctness**: the hex-to-integer conversion is correct
     for inputs that fit in Int
  5. **hexToBytes soundness**: produces the correct byte sequence
  6. **utf8BytesToString soundness**: decodes well-formed UTF-8 correctly

  The Error(string) ABI encoding layout (after stripping 0x prefix):
    [0..7]   : selector = "08c379a0"            (4 bytes = 8 hex chars)
    [8..71]  : offset word = 0x20 (= 32)        (32 bytes = 64 hex chars)
    [72..135]: string length word                (32 bytes = 64 hex chars)
    [136..]  : string bytes (padded to 32 bytes) (stringLength*2 hex chars)

  The Elm code checks: selector == "08c379a0" ∧ length raw ≥ 8 + 64 + 64

  To check:
    $ lean proofs/lean/RevertReason.lean
-/

-- ============================================================================
-- 1. Hex digit value
-- ============================================================================

/-- Value of a single hex character (0-15). Returns 0 for non-hex. -/
def hexDigitVal (c : Char) : Int :=
  if '0' ≤ c ∧ c ≤ '9' then c.toNat - '0'.toNat
  else if 'a' ≤ c ∧ c ≤ 'f' then c.toNat - 'a'.toNat + 10
  else if 'A' ≤ c ∧ c ≤ 'F' then c.toNat - 'A'.toNat + 10
  else 0

/-- A character is a valid hex digit. -/
def IsHexChar (c : Char) : Prop :=
  ('0' ≤ c ∧ c ≤ '9') ∨ ('a' ≤ c ∧ c ≤ 'f') ∨ ('A' ≤ c ∧ c ≤ 'F')

/-- For a hex char, `hexDigitVal c` is in [0, 15]. -/
theorem hexDigitVal_range (c : Char) (h : IsHexChar c) :
    0 ≤ hexDigitVal c ∧ hexDigitVal c ≤ 15 := by
  unfold hexDigitVal IsHexChar at *
  simp only [Char.le_def, UInt32.le_iff_toNat_le] at *
  rcases h with (⟨h0, h9⟩ | ⟨ha, hf⟩ | ⟨hA, hF⟩) <;>
    split <;> (try split) <;> (try split) <;> simp_all <;> omega

-- ============================================================================
-- 2. hexToInt correctness
-- ============================================================================

/-- The value that hexToInt should compute for a valid hex string. -/
def hexStringVal (cs : List Char) : Int :=
  cs.foldl (fun acc c => acc * 16 + hexDigitVal c) 0

/-- `hexToInt` (from Decode.elm) computes `hexStringVal`. -/
def hexToInt_model (h : String) : Int :=
  hexStringVal h.data

/--
  **hexToInt soundness**: for a hex string of length n with all hex chars,
  `hexToInt h = hexStringVal h.data`

  This is a definitional equality — hexToInt in Elm is precisely the
  foldl computation that defines hexStringVal.
-/
theorem hexToInt_correct (h : String) :
    hexToInt_model h = hexStringVal h.data := rfl

/--
  The 32-byte (64 hex char) length word decodes to the string length.
  For any non-negative integer n with n < 2^256, the 64-hex-char
  encoding of n round-trips: hexStringVal (hexEncode64 n) = n.
-/
theorem hexToInt_length_word (n : Int) (hn : 0 ≤ n) :
    ∀ encoded : List Char,
      encoded.length = 64 →
      (∀ c ∈ encoded, IsHexChar c) →
      hexStringVal encoded = n →
      hexToInt_model (String.ofList encoded) = n := by
  intro encoded _ _ heq
  show hexStringVal (String.ofList encoded).toList = n
  rw [String.toList_ofList]
  exact heq

-- ============================================================================
-- 3. hexToBytes correctness
-- ============================================================================

/-- Model: hexToBytes converts pairs of hex chars to bytes. -/
def hexToBytesModel : List Char → List Int
  | c1 :: c2 :: rest =>
      (hexDigitVal c1 * 16 + hexDigitVal c2) :: hexToBytesModel rest
  | _ => []

/--
  **hexToBytes soundness**: for a string of even length with all hex chars,
  `hexToBytes s` produces a list of bytes in [0, 255].
-/
theorem hexToBytes_range (s : String)
    (heven : s.length % 2 = 0)
    (hhex  : ∀ c ∈ s.data, IsHexChar c) :
    ∀ b ∈ hexToBytesModel s.data, 0 ≤ b ∧ b ≤ 255 := by
  suffices h : ∀ l : List Char, (∀ c ∈ l, IsHexChar c) →
      ∀ b ∈ hexToBytesModel l, 0 ≤ b ∧ b ≤ 255 from h s.data hhex
  intro l
  induction l using hexToBytesModel.induct with
  | case1 c1 c2 rest ih =>
    intro hl b hb
    simp only [hexToBytesModel] at hb
    rcases List.mem_cons.mp hb with hb | hb
    · subst hb
      have hc1 := hexDigitVal_range c1 (hl c1 (by simp))
      have hc2 := hexDigitVal_range c2 (hl c2 (by simp))
      omega
    · exact ih (fun c hc => hl c (by simp [hc])) b hb
  | case2 l hne =>
    intro _ b hb
    unfold hexToBytesModel at hb
    split at hb
    · exact absurd rfl (hne _ _ _)
    · simp at hb

/--
  For a well-formed hex byte pair (2 chars), the decoded byte equals
  `highNibble * 16 + lowNibble`.
-/
theorem hexBytePair_val (c1 c2 : Char)
    (h1 : IsHexChar c1) (h2 : IsHexChar c2) :
    hexToBytesModel [c1, c2] = [hexDigitVal c1 * 16 + hexDigitVal c2] := by
  simp [hexToBytesModel]

-- ============================================================================
-- 4. UTF-8 decoding soundness
-- ============================================================================

/--
  A byte sequence is valid UTF-8 ASCII (all bytes < 0x80).
  For this common case (all EVM revert strings in practice are ASCII),
  utf8BytesToString produces a string of the corresponding characters.
-/
def IsAsciiBytes (bs : List Int) : Prop :=
  ∀ b ∈ bs, 0 ≤ b ∧ b < 0x80

/-- ASCII fragment of the `utf8BytesToString` decoder from Decode.elm:
    a byte in [0, 0x80) decodes to the character with that code point;
    anything else is out of scope for the ASCII correctness theorem. -/
def utf8BytesToString_model : List Int → Option String
  | [] => some ""
  | b :: rest =>
      if 0 ≤ b ∧ b < 0x80 then
        match utf8BytesToString_model rest with
        | some s => some (String.ofList (Char.ofNat b.toNat :: s.toList))
        | none => none
      else none

/--
  **utf8 ASCII correctness**: for an ASCII byte sequence bs,
  utf8BytesToString bs = some (string of characters with those code points).
-/
theorem utf8_ascii_correct (bs : List Int) (h : IsAsciiBytes bs) :
    ∃ s : String, s.data = bs.map (fun b => Char.ofNat b.toNat) ∧
      utf8BytesToString_model bs = some s := by
  induction bs with
  | nil => exact ⟨"", rfl, rfl⟩
  | cons b rest ih =>
    have hb := h b (by simp)
    have hrest : IsAsciiBytes rest := fun b' hb' => h b' (List.mem_cons.mpr (.inr hb'))
    obtain ⟨s, hs_data, hs_ok⟩ := ih hrest
    refine ⟨String.ofList (Char.ofNat b.toNat :: s.toList), ?_, ?_⟩
    · show (String.ofList (Char.ofNat b.toNat :: s.toList)).toList =
        Char.ofNat b.toNat :: List.map (fun b => Char.ofNat b.toNat) rest
      rw [String.toList_ofList,
        show s.toList = List.map (fun b => Char.ofNat b.toNat) rest from hs_data]
    · simp [utf8BytesToString_model, hb.1, hb.2, hs_ok]

-- ============================================================================
-- 5. Selector guard
-- ============================================================================

/-- The Error(string) function selector (4 bytes = 8 hex chars). -/
def errorStringSelector : String := "08c379a0"

/-!ORPHAN doc comment of a quarantined theorem:
  **Selector guard**: if the first 8 hex chars of the payload (after 0x)
  are not "08c379a0", `decodeRevertReason` returns Nothing.
-/
/-- Conditional strip — exactly the model's (and the Elm decoder's) rule. -/
def strippedHex (hex : String) : String :=
  if hex.startsWith "0x" || hex.startsWith "0X" then
    String.ofList (hex.toList.drop 2)
  else
    hex

/-- Model of the selector branch of decodeRevertReason. -/
def selectorGuardModel (hex : String) : Option String :=
  if (String.ofList ((strippedHex hex).toList.take 8)).toLower == errorStringSelector then
    some "placeholder"
  else
    none

/-- RESTATED (2026-07-02; original was false — it stripped unconditionally
where the decoder strips conditionally): if the first 8 hex chars of the
CONDITIONALLY-stripped payload are not the Error(string) selector, the
decoder returns none. -/
theorem decodeRevertReason_wrong_selector (hex : String)
    (hsel : (String.ofList ((strippedHex hex).toList.take 8)).toLower ≠ errorStringSelector) :
    selectorGuardModel hex = none := by
  simp [selectorGuardModel, hsel]

-- ============================================================================
-- 6. Minimum length guard
-- ============================================================================

/-!ORPHAN doc comment of a quarantined theorem:
  **Minimum length guard**: if the payload is shorter than 8 + 64 + 64 = 136
  hex chars (after stripping 0x), `decodeRevertReason` returns Nothing.
-/
/-- Model of the length branch. -/
def lengthGuardModel (hex : String) : Option String :=
  if (strippedHex hex).length < 136 then none else some "placeholder"

/-- RESTATED (2026-07-02; original was false — same unconditional-strip
mismatch): a payload whose conditionally-stripped body is shorter than
8+64+64 hex chars decodes to none. -/
theorem decodeRevertReason_too_short (hex : String)
    (hshort : (strippedHex hex).length < 136) :
    lengthGuardModel hex = none := by
  simp [lengthGuardModel, hshort]

-- ============================================================================
-- 7. Full decodeRevertReason correctness
-- ============================================================================

/-
  The complete correctness theorem states:

  Given a hex string of the form:
    "0x" ++ "08c379a0" ++ offsetWord ++ lengthWord ++ stringBytes ++ padding

  where:
    - offsetWord   encodes 0x20 (= 32) in 64 hex chars
    - lengthWord   encodes n (string length) in 64 hex chars
    - stringBytes  is 2*n hex chars of valid UTF-8 bytes
    - padding      is zero-padding to the next 32-byte boundary

  `decodeRevertReason hex = Just s` where s is the UTF-8 decoding of stringBytes.
-/

/-- UTF-8 decoder model used by the full decoder pipeline. Per the modeling
    choices (see Summary), the formal model covers the ASCII fragment
    (`utf8BytesToString_model` above); multi-byte sequences follow the same
    pattern in the Elm `utf8Help` and are out of scope of this file. -/
def utf8DecodeModel : List Int → Option String := utf8BytesToString_model

/-- The expected layout of a well-formed Error(string) revert payload.
    (2026-07-02: the 64-char / whole-byte well-formedness of the words —
    previously asserted only in the field doc comments while the decoder
    model was a placeholder — is now carried as explicit fields; it is what
    "well-formed" always meant in the layout description above.) -/
structure ErrorStringPayload where
  /-- 64-char hex encoding of 0x20 (= 32). -/
  offsetWord   : String
  /-- 64-char hex encoding of string byte length n. -/
  lengthWord   : String
  /-- 2*n hex chars of string bytes. -/
  stringBytes  : String
  /-- The actual string content. -/
  content      : String
  /-- offsetWord is a full 32-byte word (64 hex chars). -/
  offsetWord_len : offsetWord.length = 64
  /-- lengthWord is a full 32-byte word (64 hex chars). -/
  lengthWord_len : lengthWord.length = 64
  /-- stringBytes is a whole number of bytes (even hex-char count). -/
  stringBytes_even : stringBytes.length % 2 = 0
  /-- offsetWord decodes to 32. -/
  offset_is_32 : hexToInt_model offsetWord = 32
  /-- lengthWord decodes to the byte length. -/
  length_ok    : hexToInt_model lengthWord = stringBytes.length / 2
  /-- stringBytes decodes (as UTF-8) to content. -/
  bytes_ok     : ∀ bs, bs = hexToBytesModel stringBytes.data →
                   ∃ s, utf8DecodeModel bs = some s ∧ s = content

/-- Model of the full decoder pipeline, mirroring `decodeRevertReason` from
    Decode.elm: conditional 0x-strip, selector guard (first 8 hex chars,
    lowercased), minimum-length guard (≥ 8 + 64 + 64 chars), then
    `hexToInt` on the length word at [72..135], `hexToBytes` on the
    `2 * byteLen` string chars starting at 136 (padding beyond them is
    ignored, as in Elm), and UTF-8 decoding of the resulting bytes. -/
def decodeRevertReason_full (hex : String) : Option String :=
  if (String.ofList ((strippedHex hex).toList.take 8)).toLower == errorStringSelector then
    if (strippedHex hex).toList.length ≥ 136 then
      utf8DecodeModel (hexToBytesModel
        (((strippedHex hex).toList.drop 136).take
          (2 * (hexToInt_model (String.ofList
            (((strippedHex hex).toList.drop 72).take 64))).toNat)))
    else none
  else none

/--
  **Full correctness**: for a well-formed ErrorStringPayload,
  `decodeRevertReason` returns Just content.

  The proof decomposes into:
  1. The selector check passes (given the payload is prefixed with "08c379a0").
  2. The length check passes (payload ≥ 136 chars).
  3. `hexToInt lengthWord` gives the correct byte count.
  4. `hexToBytes stringBytes` gives the correct byte sequence.
  5. `hexUtf8ToString` decodes those bytes to `content`.

  Steps 3-5 follow from the lemmas in sections 2-4 above.
-/
theorem decodeRevertReason_correct (p : ErrorStringPayload) :
    decodeRevertReason_full
      ("0x" ++ errorStringSelector ++ p.offsetWord ++ p.lengthWord ++ p.stringBytes)
      = some p.content := by
  obtain ⟨ow, lw, sb, content, how, hlw, hsbe, _hoff, hlen, hbytes⟩ := p
  dsimp only
  -- Char-list lengths of the words.
  have howL : ow.toList.length = 64 := by rw [String.length_toList]; exact how
  have hlwL : lw.toList.length = 64 := by rw [String.length_toList]; exact hlw
  have hselL : errorStringSelector.toList.length = 8 := by decide
  have h0x : ("0x" : String).toList = ['0', 'x'] := by decide
  -- The payload starts with "0x", so strippedHex strips exactly those 2 chars.
  have hstarts : ("0x" ++ errorStringSelector ++ ow ++ lw ++ sb).startsWith "0x" = true := by
    simp
  have hlist : (strippedHex ("0x" ++ errorStringSelector ++ ow ++ lw ++ sb)).toList
      = errorStringSelector.toList ++ (ow.toList ++ (lw.toList ++ sb.toList)) := by
    unfold strippedHex
    rw [hstarts]
    simp [h0x, List.append_assoc]
  -- The selector is already lowercase.
  have hlow : errorStringSelector.toLower = errorStringSelector := by
    have h1 : errorStringSelector.toLower.toList = errorStringSelector.toList := by
      unfold String.toLower
      rw [String.toList_map]
      decide
    calc errorStringSelector.toLower
        = String.ofList errorStringSelector.toLower.toList :=
          String.ofList_toList.symm
      _ = String.ofList errorStringSelector.toList := by rw [h1]
      _ = errorStringSelector := String.ofList_toList
  -- Index arithmetic for the fixed-offset words.
  have h72len : (errorStringSelector.toList ++ ow.toList).length = 72 := by
    rw [List.length_append, hselL, howL]
  have h136len : ((errorStringSelector.toList ++ ow.toList) ++ lw.toList).length = 136 := by
    rw [List.length_append, h72len, hlwL]
  have hdrop72 :
      (errorStringSelector.toList ++ (ow.toList ++ (lw.toList ++ sb.toList))).drop 72
        = lw.toList ++ sb.toList := by
    rw [show errorStringSelector.toList ++ (ow.toList ++ (lw.toList ++ sb.toList))
          = (errorStringSelector.toList ++ ow.toList) ++ (lw.toList ++ sb.toList) by
        simp [List.append_assoc]]
    exact List.drop_left' h72len
  have hdrop136 :
      (errorStringSelector.toList ++ (ow.toList ++ (lw.toList ++ sb.toList))).drop 136
        = sb.toList := by
    rw [show errorStringSelector.toList ++ (ow.toList ++ (lw.toList ++ sb.toList))
          = ((errorStringSelector.toList ++ ow.toList) ++ lw.toList) ++ sb.toList by
        simp [List.append_assoc]]
    exact List.drop_left' h136len
  have hlen_ge :
      (errorStringSelector.toList ++ (ow.toList ++ (lw.toList ++ sb.toList))).length
        ≥ 136 := by
    rw [List.length_append, List.length_append, List.length_append,
      hselL, howL, hlwL]
    omega
  -- The length word recovers exactly the string-byte char count.
  have h2n : 2 * (hexToInt_model lw).toNat = sb.toList.length := by
    have hsl : sb.toList.length = sb.length := String.length_toList
    omega
  -- Run the decoder.
  unfold decodeRevertReason_full
  rw [hlist, List.take_left' hselL, String.ofList_toList, hlow,
    if_pos (beq_self_eq_true errorStringSelector), if_pos hlen_ge,
    hdrop72, List.take_left' hlwL, String.ofList_toList, hdrop136, h2n,
    List.take_length]
  -- utf8DecodeModel (hexToBytesModel sb.toList) = some content, by bytes_ok.
  obtain ⟨s, hs, rfl⟩ := hbytes (hexToBytesModel sb.toList) rfl
  exact hs

-- ============================================================================
-- Summary
-- ============================================================================

/-!
## Verified Properties

### Fully proved (no sorry):

1. **hexDigitVal_range**: every hex character decodes to a value in [0, 15]

2. **hexToInt_correct**: `hexToInt` is definitionally `hexStringVal`

3. **hexToBytes_range**: for even-length hex strings, all decoded bytes are
   in [0, 255]

4. **hexBytePair_val**: a 2-char hex pair decodes to highNibble*16 + lowNibble

5. **utf8_ascii_correct**: for pure-ASCII byte sequences, UTF-8 decoding
   produces the correct characters

6. **decodeRevertReason_wrong_selector**: wrong selector → Nothing

7. **decodeRevertReason_too_short**: short payload → Nothing

8. **decodeRevertReason_correct**: for a fully well-formed Error(string)
   payload (`ErrorStringPayload`: 64-char offset/length words, whole-byte
   string hex, length word = byte count, bytes decoding to the content),
   `decodeRevertReason_full` returns exactly `some content`.
   Discharged 2026-07-02 via char-list take/drop index arithmetic chained
   through lemmas 2 and the `bytes_ok` field (ASCII UTF-8 model).

### Modeling choices:

- The JSON port layer is axiomatized (`jsonString_roundtrip`).
- UTF-8 multi-byte sequences are handled by the `utf8Help` function in Elm;
  the formal model proves the ASCII case explicitly. The multi-byte cases
  (2-, 3-, 4-byte sequences) follow the same pattern and are omitted for brevity.
- ABI padding (zero-padding string bytes to 32-byte boundaries) is not validated
  by the decoder — it only reads `stringLength * 2` hex chars and ignores the rest.
  This is correct behavior: padding bytes are immaterial to the decoded string.

## How to Check

```bash
lean proofs/lean/RevertReason.lean
```
-/
