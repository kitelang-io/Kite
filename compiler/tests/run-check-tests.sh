#!/bin/zsh
# Differential test for the M2 semantic checker (frontend/kfront.kite + sema/kcheck.kite) vs the
# OCaml oracle `kitec check`. Builds it, then checks `kcheck F` == `kitec check F` (path prefix
# stripped) byte-for-byte for every compiler source file + check-probe.
# Usage: compiler/tests/run-check-tests.sh
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
ROOT=${0:A:h:h:h}
cd "$ROOT"
O=$ROOT/_build/default/stage0/bin/main.exe

echo "building kfront.kite + sema/kcheck.kite (library) + sema/kcheck_main.kite (entry) ..."
dune exec stage0/bin/main.exe -- exe compiler/frontend/kfront.kite compiler/sema/kcheck.kite compiler/sema/kcheck_main.kite >/tmp/kck_build.log 2>&1 \
  || { echo "BUILD FAILED"; tail -5 /tmp/kck_build.log; exit 1; }
mv compiler/frontend/kfront /tmp/kcheck; chmod +x /tmp/kcheck

one() {
  "$O" check "$1" 2>&1 | sed 's|^[^:]*: ||' > /tmp/kck_ref.txt
  cp "$1" /tmp/kcheck_input.kite
  /tmp/kcheck 2>/dev/null | grep -v ' -> exit code ' > /tmp/kck_got.txt
  if diff -q /tmp/kck_ref.txt /tmp/kck_got.txt >/dev/null; then echo "  PASS $1"; return 0
  else echo "  FAIL $1"; diff /tmp/kck_ref.txt /tmp/kck_got.txt | head -20; return 1; fi
}

pass=0; fail=0
FILES=(examples/hello.kite examples/native_demo.kite examples/native_loops.kite
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
