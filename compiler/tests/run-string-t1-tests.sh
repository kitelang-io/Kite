#!/bin/zsh
# String-T1 (Phase 9) test harness. The default compiler suite (run-compiler-tests.sh) compiles every program
# WITHOUT --string-t1, so it exercises only the T0 primitive String and gives ZERO signal on the boxed T1 path.
# This runner drives the SAME seed-built compiler with `--string-t1`, selecting the boxed `class String(len,
# data)` representation (lib/core/string_t1.kite) instead of the T0 C-string modules, and asserts exit codes on
# fixtures that prove box + deinit + concat + substr + interpolation + print + the leak-end. It also asserts the
# T1 build is DETERMINISTIC (compiling a fixture twice is byte-identical), the T1 analogue of the fixpoint.
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
ROOT=${0:A:h:h:h}
cd "$ROOT"

TMPD=$(mktemp -d)
KCC="$TMPD/kcc"
echo "building the compiler via the committed SEED (bootstrap/kite-seed) ..."
"$ROOT/bootstrap/kite-seed" compiler/kitec.kite "$KCC" >"$TMPD/build.log" 2>&1
[ -f "$KCC" ] || { echo "BUILD FAILED (seed could not compile current source)"; cat "$TMPD/build.log"; rm -rf "$TMPD"; exit 1; }
chmod +x "$KCC"

pass=0; fail=0
# t1check <file> <expected-exit>: compile with --string-t1 (checker ON), run, compare exit code; also compile a
# second time and assert byte-identical output (T1-path determinism).
t1check() {
  local src="$1" want="$2"
  local out="$TMPD/out" out2="$TMPD/out2"; rm -f "$out" "$out2"
  "$KCC" --string-t1 "$src" "$out" >/dev/null 2>&1
  [ -f "$out" ] || { echo "  FAIL $src (no binary produced)"; fail=$((fail+1)); return; }
  chmod +x "$out"; local r=$("$out" >/dev/null 2>&1; echo $?)
  "$KCC" --string-t1 "$src" "$out2" >/dev/null 2>&1
  if ! cmp -s "$out" "$out2"; then echo "  FAIL $src (T1 build not deterministic)"; fail=$((fail+1)); return; fi
  if [ "$r" = "$want" ]; then echo "  PASS $src -> $r"; pass=$((pass+1))
  else echo "  FAIL $src -> $r (want $want)"; fail=$((fail+1)); fi
}

t1check compiler/tests/programs/string-t1-basics.kite 77
t1check compiler/tests/programs/string-t1-leak-end.kite 0
# The char tier (lib/core/char.kite) must decode/encode UTF-8 correctly over the BOXED String too: its byte
# access goes through String_byteAt, so decodeUtf8At/utf8CharCount load `s.data` under T1 (not the box word).
# char-utf8.kite returns 127 iff every helper is correct; it also passes under T0 in the default suite.
t1check compiler/tests/programs/char-utf8.kite 127

echo "== string-T1 tests: $pass pass, $fail fail =="
rm -rf "$TMPD"
[ $fail -eq 0 ]
