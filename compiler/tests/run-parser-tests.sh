#!/bin/zsh
# Differential test for the full-language Kite parser (frontend/kfront.kite + kprint.kite) vs the OCaml
# oracle. Builds the parser with the SELF-HOSTED compiler (kcc) — Fledge can no longer compile the
# compiler's method-call syntax — then checks `<kite parser> F` == `oracle parse F` byte-for-byte for
# every compiler source file + probe.
# Usage: compiler/tests/run-parser-tests.sh
set -e
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
ROOT=${0:A:h:h:h}
cd "$ROOT"
REF=/tmp/kp_ref.txt; GOT=/tmp/kp_got.txt
KP=/tmp/kfront_kite

echo "building the Kite parser (kfront + kprint) via the self-hosted seed ..."
TMPD=$(mktemp -d); KCC="$TMPD/kcc"
"$ROOT/bootstrap/kite-seed" compiler/kitec.kite "$KCC" >"$TMPD/build.log" 2>&1
[ -f "$KCC" ] || { echo "SEED BUILD FAILED"; cat "$TMPD/build.log"; exit 1; }
chmod +x "$KCC"
"$KCC" compiler/tests/kparse_driver.kite -o "$KP" >"$TMPD/kp_build.log" 2>&1 \
  || { echo "PARSER BUILD FAILED"; tail -5 "$TMPD/kp_build.log"; exit 1; }
chmod +x "$KP"

one() {
  dune exec stage0/bin/main.exe -- parse "$1" >"$REF" 2>/dev/null
  cp "$1" /tmp/kparse_input.kite
  "$KP" 2>/dev/null | grep -v ' -> exit code ' >"$GOT"
  if diff -q "$REF" "$GOT" >/dev/null; then echo "  PASS $1"; return 0
  else echo "  FAIL $1"; diff "$REF" "$GOT" | head -30; return 1; fi
}

pass=0; fail=0
CORPUS=(examples/demos/hello.kite examples/demos/native_demo.kite examples/demos/native_loops.kite
        bootstrap/*.kite
        compiler/frontend/*.kite compiler/sema/*.kite compiler/codegen/*.kite
        compiler/backend/arm64/*.kite compiler/driver/*.kite compiler/tests/kenc_test.kite
        compiler/tests/parser/*.kite)
for f in $CORPUS; do
  [ -f "$f" ] || continue
  if one "$f"; then pass=$((pass+1)); else fail=$((fail+1)); fi
done
echo "== parser tests: $pass pass, $fail fail =="
[ $fail -eq 0 ]
