#!/usr/bin/env bash
# Model-check every TLA+ spec with TLC. Exits non-zero if any spec fails.
#
# Requires Java + tla2tools.jar. Point TLA_TOOLS at the jar, or drop it in
# ~/.local/share/tla/tla2tools.jar (download:
#   https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar).
# A JDK 11+ works; corretto-21 via mise is what this was verified with.
#
# -deadlock is intentional: the Wallet/Transaction/Sign machines have genuine
# terminal sink states (Confirmed, Signed, …), which TLC would otherwise flag
# as deadlocks.
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
  echo "── TLC: $spec ──"
  out=$(TMPDIR="${TMPDIR:-$HOME/.cache}" "$JAVA" -XX:+UseParallelGC -cp "$JAR" \
        tlc2.TLC -deadlock -metadir "${TMPDIR:-$HOME/.cache}/tlc-$spec" \
        -config "$spec.cfg" "$tla" 2>&1)
  if echo "$out" | grep -q "No error has been found"; then
    echo "  ✓ $(echo "$out" | grep -oE '[0-9]+ distinct states found' | head -1)"
  else
    echo "  ✗ FAILED"; echo "$out" | grep -iE 'error|violat|parse' | head -6
    fail=1
  fi
done
exit $fail
