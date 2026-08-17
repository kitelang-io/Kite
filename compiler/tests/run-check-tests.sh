#!/bin/zsh
# Differential test for the M2 semantic checker (frontend/kfront.kite + sema/kcheck.kite) vs the OCaml
# oracle. The Kite checker is run via the SELF-HOSTED compiler (`kcc check`) — Fledge can no longer
# compile the method-call syntax. Two-part per file:
#   1. CONTENT: `kcc check F` message text/order/count must match the oracle `check F` byte-for-byte
#      (path prefix stripped; kcc's "line N: " position prefix stripped; trailer "semantic error(s)" vs
#      "error(s)" normalized) — validates message CONTENT against the independent OCaml oracle.
#   2. POSITION: for probes with a golden expectation (compiler/tests/check/expected/<name>.txt), the RAW
#      position-bearing output must match the golden (same trailer normalization) — pins the line numbers.
# The oracle (dune stage0 parse/check) is the OCaml reference impl; it does NOT compile Kite, so it is
# unaffected by the compiler moving to method syntax. `dune --root .` forces the worktree as dune root.
# Usage: compiler/tests/run-check-tests.sh
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
ROOT=${0:A:h:h:h}
cd "$ROOT"

echo "building the self-hosted checker (kcc) via the seed ..."
TMPD=$(mktemp -d); KCC="$TMPD/kcc"
"$ROOT/bootstrap/kite-seed" compiler/kitec.kite "$KCC" >"$TMPD/build.log" 2>&1
[ -f "$KCC" ] || { echo "SEED BUILD FAILED"; cat "$TMPD/build.log"; exit 1; }
chmod +x "$KCC"
norm() { sed -E 's/([0-9]+) semantic error/\1 error/; s/^ok .*/ok/'; }   # normalize the count trailer + the clean-pass "ok (...)" line

one() {
  # oracle content reference: path prefix stripped, trailer normalized
  dune exec --root . stage0/bin/main.exe -- check "$1" 2>&1 | sed 's|^[^:]*: ||' | norm > /tmp/kck_ref.txt
  # raw kcc checker output (position-bearing)
  "$KCC" check "$1" 2>&1 > /tmp/kck_raw.txt
  # content view: drop the "line N: " position prefix so message text is comparable to the oracle
  sed -E 's|^error: line [0-9]+: |error: |' /tmp/kck_raw.txt > /tmp/kck_got.txt
  local ok=1
  if ! diff -q /tmp/kck_ref.txt /tmp/kck_got.txt >/dev/null; then
    echo "  FAIL(content) $1"; diff /tmp/kck_ref.txt /tmp/kck_got.txt | head -20; ok=0
  fi
  # position view: compare RAW output to the golden line-number expectation, when one exists
  local gold="${1:h}/expected/${1:t:r}.txt"
  if [ -f "$gold" ]; then
    if ! diff -q <(norm < "$gold") /tmp/kck_raw.txt >/dev/null; then
      echo "  FAIL(position) $1"; diff <(norm < "$gold") /tmp/kck_raw.txt | head -20; ok=0
    fi
  fi
  if [ $ok -eq 1 ]; then echo "  PASS $1"; return 0; else return 1; fi
}

pass=0; fail=0
FILES=(examples/demos/hello.kite examples/demos/native_demo.kite examples/demos/native_loops.kite
       bootstrap/*.kite
       compiler/frontend/*.kite compiler/sema/*.kite compiler/codegen/*.kite
       compiler/backend/arm64/*.kite compiler/driver/*.kite compiler/tests/kenc_test.kite
       compiler/tests/check/*.kite)
for f in $FILES; do
  [ -f "$f" ] || continue
  if one "$f"; then pass=$((pass+1)); else fail=$((fail+1)); fi
done
echo "== checker tests: $pass pass, $fail fail =="
[ $fail -eq 0 ]
