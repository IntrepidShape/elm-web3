#!/usr/bin/env bash
# Model-check every TLA+ spec with TLC. Exits non-zero if any spec fails.
#
# Requires Java + tla2tools.jar. Point TLA_TOOLS at the jar, or drop it in
# ~/.local/share/tla/tla2tools.jar (download:
#   https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar).
# A JDK 11+ works; corretto-21 via mise is what this was verified with.
#
# -deadlock (i.e. skip TLC's deadlock check) is applied ONLY to SignSpec: its
# terminal states (Signed/SignFailed/SignRejected) are genuine sinks — the Elm
# Sign machine has no reset. WalletSpec and TransactionSpec have no sinks
# (UserConnect / TxReset are always eventually enabled), so they get the full
# deadlock check.
set -uo pipefail
cd "$(dirname "$0")"

JAR="${TLA_TOOLS:-$HOME/.local/share/tla/tla2tools.jar}"
JAVA="${JAVA:-java}"
if ! command -v "$JAVA" >/dev/null 2>&1; then
  JAVA="$HOME/.local/share/mise/installs/java/corretto-21/bin/java"
fi
[ -f "$JAR" ] || { echo "tla2tools.jar not found at $JAR (set TLA_TOOLS)"; exit 2; }

fail=0
for tla in *.tla; do
  spec="${tla%.tla}"
  [ -f "$spec.cfg" ] || continue
  extra=""
  [ "$spec" = "SignSpec" ] && extra="-deadlock"   # terminal sinks are intended
  echo "── TLC: $spec ──"
  out=$(TMPDIR="${TMPDIR:-$HOME/.cache}" "$JAVA" -XX:+UseParallelGC -cp "$JAR" \
        tlc2.TLC $extra -metadir "${TMPDIR:-$HOME/.cache}/tlc-$spec" \
        -config "$spec.cfg" "$tla" 2>&1)
  if echo "$out" | grep -q "No error has been found"; then
    echo "  ✓ $(echo "$out" | grep -oE '[0-9]+ distinct states found' | head -1)"
  else
    echo "  ✗ FAILED"; echo "$out" | grep -iE 'error|violat|parse' | head -6
    fail=1
  fi
done
exit $fail
