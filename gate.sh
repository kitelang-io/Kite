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

echo "✅ GATE PASSED (no OCaml, no shared /tmp) — suite green, kcc2==kcc3, robust to malformed input"
rm -rf "$T"
