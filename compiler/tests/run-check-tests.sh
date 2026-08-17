#!/bin/zsh
# Regression test for the M2 semantic checker (frontend/kfront.kite + sema/kcheck.kite), run via the
# SELF-HOSTED compiler (`kcc check`). Fledge is retired, so `kcc check` output is diffed against committed
# golden snapshots (compiler/tests/check/golden/) instead of a live OCaml oracle. The harness is OCaml-free.
#
# Two views per file:
#   1. CONTENT: `kcc check F` (kcc's "line N: " position prefix stripped; count trailer normalized) must
#      match golden/<basename>.txt — the message text, order, and count.
#   2. POSITION: for probes with a golden expectation (compiler/tests/check/expected/<name>.txt), the RAW
#      position-bearing output must match (same trailer normalization) — pins the line numbers.
#
# Corpus: the diagnostic probes (compiler/tests/check/*.kite) + the demos. A demo with no committed golden
# is skipped — the retired oracle accepted `when`-pattern/enum-path syntax in demos/{patterns,raw,traits,
# types}.kite that the self-hosted checker does not yet handle, so those have no reproducible golden.
# Usage: compiler/tests/run-check-tests.sh
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
ROOT=${0:A:h:h:h}
cd "$ROOT" || exit 1

echo "building the self-hosted checker (kcc) via the seed ..."
TMPD=$(mktemp -d); KCC="$TMPD/kcc"
"$ROOT/bootstrap/kite-seed" compiler/kitec.kite "$KCC" >"$TMPD/build.log" 2>&1
[ -f "$KCC" ] || { echo "SEED BUILD FAILED"; cat "$TMPD/build.log"; rm -rf "$TMPD"; exit 1; }
chmod +x "$KCC"

norm() { sed -E 's/([0-9]+) semantic error/\1 error/; s/^ok .*/ok/'; }   # normalize count trailer + "ok (...)"

one() {  # $1 = source file (has a content golden)
  local gold="compiler/tests/check/golden/${1:t:r}.txt"
  "$KCC" check "$1" > "$TMPD/raw.txt" 2>&1
  # content view: drop the "line N: " position prefix so message text is comparable to the golden
  sed -E 's|^error: line [0-9]+: |error: |' "$TMPD/raw.txt" | norm > "$TMPD/got.txt"
  local ok=1
  if ! diff -q "$gold" "$TMPD/got.txt" >/dev/null; then
    echo "  FAIL(content) $1"; diff "$gold" "$TMPD/got.txt" | head -20; ok=0
  fi
  # position view: compare RAW output to the golden line-number expectation, when one exists
  local exp="${1:h}/expected/${1:t:r}.txt"
  if [ -f "$exp" ]; then
    if ! diff -q <(norm < "$exp") "$TMPD/raw.txt" >/dev/null; then
      echo "  FAIL(position) $1"; diff <(norm < "$exp") "$TMPD/raw.txt" | head -20; ok=0
    fi
  fi
  if [ $ok -eq 1 ]; then echo "  PASS $1"; return 0; else return 1; fi
}

pass=0; fail=0; skip=0
for f in compiler/tests/check/*.kite examples/demos/*.kite; do
  [ -f "$f" ] || continue
  if [ ! -f "compiler/tests/check/golden/${f:t:r}.txt" ]; then
    echo "  SKIP $f (no golden)"; skip=$((skip+1)); continue
  fi
  if one "$f"; then pass=$((pass+1)); else fail=$((fail+1)); fi
done
echo "== checker tests: $pass pass, $fail fail, $skip skipped =="
rm -rf "$TMPD"
[ $fail -eq 0 ]
