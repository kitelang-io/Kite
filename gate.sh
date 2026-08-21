#!/bin/zsh
# Portable verification gate — NO OCaml, NO shared /tmp. Bootstraps from the committed seed
# (bootstrap/kite-seed) via the compiler's real CLI into a private temp dir, so it is safe to run in
# parallel git worktrees. Verifies the integrated self-hosting fixpoint (kcc2==kcc3) + the compiler suite.
# Reseed from the archived Fledge bootstrapper (kitelang-io/fledge) only when a PARSER change makes the
# seed unable to compile the source.
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
ROOT=${0:A:h}
cd "$ROOT" || exit 1
SEED="$ROOT/bootstrap/kite-seed"
T=$(mktemp -d)
fail() { echo "❌ GATE FAILED: $1"; rm -rf "$T"; exit 1; }
[ -x "$SEED" ] || fail "seed missing ($SEED) — reseed from the archived Fledge bootstrapper (kitelang-io/fledge)"

echo "=== [1/2] compiler suite (correctness, built via seed CLI) ==="
zsh compiler/tests/run-compiler-tests.sh >"$T/suite.log" 2>&1
tail -1 "$T/suite.log"
grep -q "0 fail" "$T/suite.log" || fail "compiler suite not all-pass ($(grep '==' "$T/suite.log" | tail -1))"

echo "=== [2/2] integrated fixpoint (kcc2==kcc3) ==="
"$SEED" compiler/kitec.kite "$T/k1" >"$T/b1.log" 2>&1; [ -f "$T/k1" ] || fail "seed could not compile kcc source (re-seed?)"; chmod +x "$T/k1"
"$T/k1" compiler/kitec.kite "$T/k2" >/dev/null 2>&1; [ -f "$T/k2" ] || fail "kcc2 not produced"; chmod +x "$T/k2"
"$T/k2" compiler/kitec.kite "$T/k3" >/dev/null 2>&1; [ -f "$T/k3" ] || fail "kcc3 not produced (kcc2 crashed?)"; chmod +x "$T/k3"
cmp -s "$T/k2" "$T/k3" && echo "  kcc2 == kcc3 ✓ ($(wc -c <"$T/k2") bytes)" || fail "kcc2 != kcc3"

echo "=== [fmt] kitefmt builds standalone, idempotent, semantics-preserving ==="
zsh compiler/tests/run-fmt-tests.sh >"$T/fmt.log" 2>&1
tail -1 "$T/fmt.log"
grep -q "FMT TESTS PASSED" "$T/fmt.log" || fail "kitefmt tests failed ($(tail -3 "$T/fmt.log" | tr '\n' ' '))"

echo "=== [robustness] malformed input rejected, never segfaults ==="
BAD=compiler/tests/bugs/malformed-input-must-not-segfault.kite
"$T/k2" check "$BAD" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 139 ] && fail "compiler SEGFAULTED (139) on malformed input — parser bounds-check regressed"
[ "$rc" -eq 0 ] && fail "compiler ACCEPTED malformed input (should error)"
echo "  malformed input -> exit $rc (non-zero, not signal-killed) ✓"

echo "=== [robustness] missing-module import never segfaults ==="
MISS=compiler/tests/bugs/missing-module-import-must-not-segfault.kite
"$T/k2" check "$MISS" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 139 ] && fail "compiler SEGFAULTED (139) on a dangling namespace import — readFile NULL-guard regressed"
echo "  missing-module import -> exit $rc (deterministic, not signal-killed) ✓"

echo "=== [robustness] unsupported construct hard-aborts, no silent binary ==="
UC=compiler/tests/bugs/unsupported-construct-must-abort.kite
rm -f "$T/uc_out"
"$T/k2" --no-check "$UC" "$T/uc_out" >"$T/uc_stdout" 2>"$T/uc_err"; rc=$?
[ "$rc" -eq 0 ] && fail "compiler returned 0 on an unsupported construct — lowFail silent-corruption regressed"
[ -f "$T/uc_out" ] && fail "compiler wrote a binary despite an unsupported construct — lowFail did not abort"
grep -q "unsupported construct" "$T/uc_err" || fail "unsupported-construct diagnostic not on stderr"
[ -s "$T/uc_stdout" ] && fail "unsupported-construct diagnostic leaked to stdout (must be stderr-only)"
echo "  unsupported construct -> exit $rc, no binary, diagnostic on stderr ✓"

echo "=== [robustness] undefined Type::member static hard-aborts, no silent bare-symbol binary ==="
US=compiler/tests/bugs/undefined-static-must-abort.kite
rm -f "$T/us_out"
"$T/k2" --no-check "$US" "$T/us_out" >"$T/us_stdout" 2>"$T/us_err"; rc=$?
[ "$rc" -eq 0 ] && fail "compiler returned 0 on an undefined Type::member — staticCallee bare-symbol fallback regressed"
[ -f "$T/us_out" ] && fail "compiler wrote a binary despite an undefined static (dangling bare symbol)"
grep -q "no such associated member" "$T/us_err" || fail "undefined-static diagnostic not on stderr"
echo "  Widget::nope() -> exit $rc, no binary, diagnostic on stderr ✓"

echo "=== [robustness] undefined Type.member DOT static is a compile error, no silent binary ==="
UD=compiler/tests/bugs/undefined-dot-must-abort.kite
rm -f "$T/ud_out"
"$T/k2" "$UD" "$T/ud_out" >"$T/ud_stdout" 2>"$T/ud_err"; rc=$?
[ "$rc" -eq 0 ] && fail "compiler returned 0 on an undefined Type.member DOT static — checker dot-routing regressed"
[ -f "$T/ud_out" ] && fail "compiler wrote a binary despite an undefined Type.member dot static (dangling bare symbol)"
grep -q "has no member" "$T/ud_err" || fail "undefined-dot-static diagnostic not on stderr"
echo "  Widget.nope() -> exit $rc, no binary, diagnostic on stderr ✓"

echo "=== [robustness] dot-qualified enum-variant construction under a namespace import hard-aborts, no segfaulting binary ==="
VD=compiler/tests/bugs/variant-dot-with-import-must-abort.kite
rm -f "$T/vd_out"
"$T/k2" "$VD" "$T/vd_out" >"$T/vd_stdout" 2>"$T/vd_err"; rc=$?
[ "$rc" -eq 0 ] && fail "compiler returned 0 on Color.Red under 'import kite::core' — dot-variant enforcement regressed"
[ -f "$T/vd_out" ] && fail "compiler wrote a binary for a dot-qualified variant construction (would segfault at runtime)"
# The member-table checker now enforces this under namespace imports too (its concat-module gate no longer
# desyncs at `pub`), so the diagnostic reads "must be accessed with `::` not `.`" — caught before the
# lowerer backstop that would otherwise fire on the `Color.Red` construction.
grep -q "must be accessed with .::. not" "$T/vd_err" || fail "dot-variant diagnostic not on stderr"
echo "  Color.Red (with import) -> exit $rc, no binary, diagnostic on stderr ✓"

echo "=== [robustness] undefined instance x.nope() hard-aborts under --no-check, no silent bare-symbol binary ==="
UM=compiler/tests/bugs/undefined-method-must-abort.kite
rm -f "$T/um_out"
"$T/k2" --no-check "$UM" "$T/um_out" >"$T/um_stdout" 2>"$T/um_err"; rc=$?
[ "$rc" -eq 0 ] && fail "compiler returned 0 on an undefined instance method under --no-check — klower backstop regressed"
[ -f "$T/um_out" ] && fail "compiler wrote a binary despite an undefined instance method (dangling bare symbol)"
grep -q "no such method or function" "$T/um_err" || fail "undefined-method diagnostic not on stderr"
echo "  w.nope() --no-check -> exit $rc, no binary, diagnostic on stderr ✓"

echo "=== [robustness] @derive of a non-derivable trait hard-aborts, no silent binary ==="
DR=compiler/tests/bugs/derive-nonderivable-must-abort.kite
rm -f "$T/dr_out"
"$T/k2" --no-check "$DR" "$T/dr_out" >"$T/dr_stdout" 2>"$T/dr_err"; rc=$?
[ "$rc" -eq 0 ] && fail "compiler returned 0 on @derive(Display) — non-derivable-trait guard regressed"
[ -f "$T/dr_out" ] && fail "compiler wrote a binary despite @derive of a non-derivable trait"
grep -q "auto-derivable" "$T/dr_err" || fail "non-derivable-derive diagnostic not on stderr"
echo "  @derive(Display) -> exit $rc, no binary, diagnostic on stderr ✓"

echo "=== [robustness] @derive over a non-derivable FIELD hard-aborts, no silent binary ==="
DF=compiler/tests/bugs/derive-nonderivable-field-must-abort.kite
rm -f "$T/df_out"
"$T/k2" --no-check "$DF" "$T/df_out" >"$T/df_stdout" 2>"$T/df_err"; rc=$?
[ "$rc" -eq 0 ] && fail "compiler returned 0 on @derive(Eq) over a field lacking Eq — WF field guard regressed"
[ -f "$T/df_out" ] && fail "compiler wrote a binary despite a non-derivable field (silent pointer-compare)"
grep -q "does not implement" "$T/df_err" || fail "non-derivable-field diagnostic not on stderr"
echo "  @derive(Eq) over non-Eq field -> exit $rc, no binary, diagnostic on stderr ✓"

echo "=== [robustness] @derive compare/print over a Double field hard-aborts, no silent miscompile ==="
DD=compiler/tests/bugs/derive-double-compare-must-abort.kite
rm -f "$T/dd_out"
"$T/k2" --no-check "$DD" "$T/dd_out" >"$T/dd_stdout" 2>"$T/dd_err"; rc=$?
[ "$rc" -eq 0 ] && fail "compiler returned 0 on @derive(Eq,Ord,Debug) over a Double field — float WF guard regressed"
[ -f "$T/dd_out" ] && fail "compiler wrote a binary despite a Double compare derive (silent pointer-compare)"
grep -q "floating-point" "$T/dd_err" || fail "double-derive diagnostic not on stderr"
echo "  @derive(Eq,Ord,Debug) over Double -> exit $rc, no binary, diagnostic on stderr ✓"

echo "=== [robustness] malformed extension-function decl hard-aborts, no silent miscompile ==="
XF=compiler/tests/bugs/malformed-extension-must-abort.kite
rm -f "$T/xf_out"
"$T/k2" --no-check "$XF" "$T/xf_out" >"$T/xf_stdout" 2>"$T/xf_err"; rc=$?
[ "$rc" -eq 0 ] && fail "compiler returned 0 on 'fun Int..dbl()' — extension-fn parser validation regressed (silent desync)"
[ -f "$T/xf_out" ] && fail "compiler wrote a binary despite a malformed extension-fn decl (parser desynced, main swallowed)"
grep -q "extension function" "$T/xf_err" || fail "malformed-extension diagnostic not on stderr"
[ -s "$T/xf_stdout" ] && fail "malformed-extension diagnostic leaked to stdout (must be stderr-only)"
echo "  fun Int..dbl() -> exit $rc, no binary, diagnostic on stderr ✓"

echo "=== [robustness] bare \`const\` (no \`val\`) is rejected, no silent binary (M5) ==="
BC=compiler/tests/bugs/bare-const-must-abort.kite
rm -f "$T/bc_out"
"$T/k2" "$BC" "$T/bc_out" >"$T/bc_stdout" 2>"$T/bc_err"; rc=$?
[ "$rc" -eq 0 ] && fail "compiler returned 0 on a bare \`const\` — const-val unification regressed"
[ -f "$T/bc_out" ] && fail "compiler wrote a binary despite a bare \`const\` decl"
grep -q "const val" "$T/bc_err" || fail "bare-const diagnostic not on stderr"
echo "  const MAX = 100 -> exit $rc, no binary, diagnostic on stderr ✓"

echo "=== [robustness] a same-signature duplicate definition is a hard error, no silent last-wins (M5) ==="
DS=compiler/tests/bugs/duplicate-signature-must-abort.kite
rm -f "$T/ds_out"
"$T/k2" "$DS" "$T/ds_out" >"$T/ds_stdout" 2>"$T/ds_err"; rc=$?
[ "$rc" -eq 0 ] && fail "compiler returned 0 on a same-signature duplicate — skipDup hard-error regressed"
[ -f "$T/ds_out" ] && fail "compiler wrote a binary despite a same-signature duplicate definition"
grep -q "duplicate top-level definition" "$T/ds_err" || fail "duplicate-definition diagnostic not on stderr"
echo "  fun add(Int,Int) x2 -> exit $rc, no binary, diagnostic on stderr ✓"

echo "=== [robustness] a bare \`<Type>_<member>\` surface identifier is rejected, no silent binary (M6) ==="
MS=compiler/tests/bugs/mangled-surface-must-abort.kite
# --no-check exercises the guard this fixture NAMES — klower's rejectMangledSurface. (With the checker on,
# `String_len` is now rejected one phase earlier as "unresolved name": String's queries are real MEMBER
# methods, so the mangle is no longer a top-level symbol the checker resolves — same reject, no binary, just
# an earlier phase. --no-check bypasses the checker so the lowerer's dedicated surface guard keeps coverage.)
rm -f "$T/ms_out"
"$T/k2" --no-check "$MS" "$T/ms_out" >"$T/ms_stdout" 2>"$T/ms_err"; rc=$?
[ "$rc" -eq 0 ] && fail "compiler returned 0 on a bare \`String_len\` — member-table surface enforcement regressed"
[ -f "$T/ms_out" ] && fail "compiler wrote a binary despite a bare \`<Type>_<member>\` surface identifier"
grep -q "not a valid identifier" "$T/ms_err" || fail "mangled-surface diagnostic not on stderr"
echo "  String_len(s) --no-check -> exit $rc, no binary, diagnostic on stderr ✓"

echo "✅ GATE PASSED (no OCaml, no shared /tmp) — suite green, kcc2==kcc3, robust to malformed input"
rm -rf "$T"
