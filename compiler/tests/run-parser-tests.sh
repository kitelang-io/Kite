#!/bin/zsh
# Differential test for the full-language Kite parser (frontend/kfront.kite + kprint.kite) vs the
# OCaml oracle. Builds the parser, then checks `kfront F` == `kitec parse F` byte-for-byte for
# every compiler source file + probe.
# Usage: compiler/tests/run-parser-tests.sh
set -e
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
ROOT=${0:A:h:h:h}
cd "$ROOT"
REF=/tmp/kp_ref.txt; GOT=/tmp/kp_got.txt

echo "building compiler/frontend/{kfront,kprint}.kite ..."
dune exec stage0/bin/main.exe -- exe compiler/frontend/kfront.kite compiler/frontend/kprint.kite >/tmp/kp_build.log 2>&1 \
  || { echo "BUILD FAILED"; tail -5 /tmp/kp_build.log; exit 1; }

one() {
  dune exec stage0/bin/main.exe -- parse "$1" >"$REF" 2>/dev/null
  cp "$1" /tmp/kparse_input.kite
  ./compiler/frontend/kfront 2>/dev/null | grep -v ' -> exit code ' >"$GOT"
  if diff -q "$REF" "$GOT" >/dev/null; then echo "  PASS $1"; return 0
  else echo "  FAIL $1"; diff "$REF" "$GOT" | head -30; return 1; fi
}

pass=0; fail=0
CORPUS=(examples/hello.kite examples/native_demo.kite examples/native_loops.kite
        bootstrap/*.kite
        compiler/frontend/*.kite compiler/sema/*.kite compiler/codegen/*.kite
        compiler/backend/arm64/*.kite compiler/driver/*.kite compiler/tests/kenc_test.kite
        compiler/tests/parser/*.kite)
for f in $CORPUS; do
  [ -f "$f" ] || continue
  if one "$f"; then pass=$((pass+1)); else fail=$((fail+1)); fi
done
echo "== parser tests: $pass pass, $fail fail =="
rm -f compiler/frontend/kfront
[ $fail -eq 0 ]
