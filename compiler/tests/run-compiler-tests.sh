#!/bin/zsh
# End-to-end test for the integrated self-hosted compiler:
#   frontend/kfront.kite (parser) + driver/klower.kite (surface->core lowering + closures)
#   + codegen/codegen.kite (AST->IR) + backend/arm64/arm64.kite (IR->AArch64+Mach-O).
# Builds it, compiles each program to a native binary, checks its exit code.
# Usage: compiler/tests/run-compiler-tests.sh
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
ROOT=${0:A:h:h:h}
cd "$ROOT"

echo "building integrated compiler via the committed SEED (bootstrap/kite-seed — no OCaml) ..."
# The compiler assembles itself through its OWN import (kitec.kite quoted-includes the 4 units) and is
# driven through its real CLI (explicit input/output paths) into a private temp dir — nothing touches a
# shared /tmp, so this is safe to run in parallel worktrees.
TMPD=$(mktemp -d)
KCC="$TMPD/kcc"
"$ROOT/bootstrap/kite-seed" compiler/kitec.kite "$KCC" >"$TMPD/build.log" 2>&1
[ -f "$KCC" ] || { echo "BUILD FAILED (seed could not compile current source — reseed from the archived Fledge bootstrapper: kitelang-io/fledge)"; cat "$TMPD/build.log"; exit 1; }
chmod +x "$KCC"

check() {
  local out="$TMPD/out"; rm -f "$out"; "$KCC" "$1" "$out" >/dev/null 2>&1
  [ -f "$out" ] || { echo "  FAIL $1 (no binary produced)"; return 1; }
  chmod +x "$out"; local r=$("$out" >/dev/null 2>&1; echo $?)
  if [ "$r" = "$2" ]; then echo "  PASS $1 -> $r"; return 0
  else echo "  FAIL $1 -> $r (want $2)"; return 1; fi
}

pass=0; fail=0
TESTS=(examples/demos/native_demo.kite:24 examples/demos/native_loops.kite:67
       bootstrap/calc.kite:26 bootstrap/calcast.kite:26 bootstrap/toklist.kite:26
       bootstrap/letcalc.kite:48 bootstrap/tokenize.kite:13 bootstrap/minikite.kite:30 bootstrap/lex.kite:9
       compiler/tests/programs/closures-fold.kite:15 compiler/tests/programs/closures-escape.kite:15
       compiler/tests/programs/closures-nested.kite:6 compiler/tests/programs/closures-foldmul.kite:120
       compiler/tests/programs/for-each.kite:31 compiler/tests/programs/methods.kite:20
       compiler/tests/programs/index.kite:117 compiler/tests/programs/interp.kite:1
       compiler/tests/programs/integration.kite:25
       compiler/tests/programs/map-string.kite:67 compiler/tests/programs/map-int.kite:25
       compiler/tests/programs/float-arith.kite:12 compiler/tests/programs/float-cmp.kite:1
       compiler/tests/programs/generic-struct.kite:198 compiler/tests/programs/generic-map.kite:17
       compiler/tests/programs/arc-refcount.kite:32 compiler/tests/programs/arc-free.kite:7
       compiler/tests/programs/arc-deep.kite:211 compiler/tests/programs/stdlib-demo.kite:223
       compiler/tests/programs/nullable-ops.kite:127 compiler/tests/programs/trait-dispatch.kite:25
       compiler/tests/programs/class-arc.kite:21 compiler/tests/programs/comptime.kite:38
       compiler/tests/programs/import-demo.kite:86 compiler/tests/programs/features-combined.kite:59
       compiler/tests/programs/dyn-dispatch.kite:91 compiler/tests/programs/arc-deinit.kite:79
       compiler/tests/programs/arc-nested-return.kite:7 compiler/tests/programs/float-print.kite:9
       compiler/tests/programs/const-decl.kite:156 compiler/tests/programs/comptime-fn.kite:78
       compiler/tests/programs/trait-container.kite:24 compiler/tests/programs/arc-reassign.kite:23
       compiler/tests/programs/arc-field.kite:23 compiler/tests/programs/arc-temp.kite:22
       compiler/tests/programs/index-store.kite:115
       compiler/tests/programs/trait-default.kite:42 compiler/tests/programs/comptime-heap.kite:111
       compiler/tests/programs/generic-trait-bound.kite:119 compiler/tests/programs/comptime-computed.kite:25
       compiler/tests/programs/modules-collide.kite:42
       compiler/tests/programs/nominal-methods.kite:32 compiler/tests/programs/pub-reexport.kite:37 compiler/tests/programs/vec-raw.kite:158 compiler/tests/programs/str-raw.kite:37 compiler/tests/programs/map-vec.kite:124
       compiler/tests/programs/break-continue.kite:77 compiler/tests/programs/compound-assign.kite:96 compiler/tests/programs/exclusive-range.kite:57
       compiler/tests/programs/property-getset.kite:53
       compiler/tests/programs/map-class.kite:166
       compiler/tests/programs/operator-overload.kite:210 compiler/tests/programs/string-methods.kite:114)
for t in $TESTS; do
  if check "${t%:*}" "${t##*:}"; then pass=$((pass+1)); else fail=$((fail+1)); fi
done
echo "== integrated-compiler tests: $pass pass, $fail fail =="
[ $fail -eq 0 ]
