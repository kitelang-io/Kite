#!/bin/zsh
# Regression test for the full-language Kite parser (frontend/kfront.kite + kprint.kite), built with the
# SELF-HOSTED compiler (kcc). Fledge is retired, so the parser's AST dump is diffed against committed
# golden snapshots (compiler/tests/parser/golden/) instead of a live OCaml oracle. The harness is OCaml-free.
#
#   - Curated corpus (compiler/tests/parser/*.kite + examples/demos/*.kite): the parser output must match
#     golden/<basename>.txt byte-for-byte. A corpus file with no golden (e.g. examples/demos/patterns.kite,
#     which uses `when` patterns beyond the retired oracle's grammar) is smoke-only: it must parse without
#     crashing.
#   - Compiler sources (frontend/sema/codegen/backend/driver + kenc_test): smoke-only — kcc must parse each
#     without crashing. The self-host fixpoint (gate.sh) already proves their correctness.
# Usage: compiler/tests/run-parser-tests.sh
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
ROOT=${0:A:h:h:h}
cd "$ROOT" || exit 1
KP=/tmp/kfront_kite

echo "building the Kite parser (kfront + kprint) via the self-hosted seed ..."
TMPD=$(mktemp -d); KCC="$TMPD/kcc"
"$ROOT/bootstrap/kite-seed" compiler/kitec.kite "$KCC" >"$TMPD/build.log" 2>&1
[ -f "$KCC" ] || { echo "SEED BUILD FAILED"; cat "$TMPD/build.log"; rm -rf "$TMPD"; exit 1; }
chmod +x "$KCC"
"$KCC" compiler/tests/kparse_driver.kite -o "$KP" >"$TMPD/kp_build.log" 2>&1 \
  || { echo "PARSER BUILD FAILED"; tail -5 "$TMPD/kp_build.log"; rm -rf "$TMPD"; exit 1; }
chmod +x "$KP"

# run KP on $1; write the AST dump (minus the driver's exit-code line) to $2; leave KP's raw exit in KPRC
# (KP returns the number of top-level decls it parsed; 139 means it crashed).
run_kp() {
  cp "$1" /tmp/kparse_input.kite
  "$KP" 2>/dev/null | grep -v ' -> exit code ' > "$2"
  KPRC=${pipestatus[1]}
}

golden_one() {  # $1 = source file (has a golden)
  local gold="compiler/tests/parser/golden/${1:t:r}.txt"
  run_kp "$1" "$TMPD/got.txt"
  [ "$KPRC" -eq 139 ] && { echo "  FAIL(crash) $1"; return 1; }
  if diff -q "$gold" "$TMPD/got.txt" >/dev/null; then echo "  PASS  $1"; return 0
  else echo "  FAIL  $1"; diff "$gold" "$TMPD/got.txt" | head -30; return 1; fi
}

smoke_one() {  # $1 = source file — must parse without crashing, non-empty AST
  run_kp "$1" "$TMPD/got.txt"
  [ "$KPRC" -eq 139 ] && { echo "  SMOKE FAIL(crash) $1"; return 1; }
  [ -s "$TMPD/got.txt" ] || { echo "  SMOKE FAIL(empty) $1"; return 1; }
  echo "  SMOKE $1"; return 0
}

pass=0; smoke=0; fail=0

echo "== curated corpus (golden diff) =="
for f in compiler/tests/parser/*.kite examples/demos/*.kite; do
  [ -f "$f" ] || continue
  if [ -f "compiler/tests/parser/golden/${f:t:r}.txt" ]; then
    if golden_one "$f"; then pass=$((pass+1)); else fail=$((fail+1)); fi
  else
    if smoke_one "$f"; then smoke=$((smoke+1)); else fail=$((fail+1)); fi
  fi
done

echo "== compiler sources (parse smoke) =="
for f in compiler/frontend/*.kite compiler/sema/*.kite compiler/codegen/*.kite \
         compiler/backend/arm64/*.kite compiler/driver/*.kite compiler/tests/kenc_test.kite; do
  [ -f "$f" ] || continue
  if smoke_one "$f"; then smoke=$((smoke+1)); else fail=$((fail+1)); fi
done

echo "== parser tests: $pass golden, $smoke smoke, $fail fail =="
rm -rf "$TMPD"
[ $fail -eq 0 ]
