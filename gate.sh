#!/bin/zsh
# Portable verification gate — NO OCaml, NO shared /tmp. Bootstraps from the committed seed
# (bootstrap/kite-seed) via the compiler's real CLI into a private temp dir, so it is safe to run in
# parallel git worktrees. Verifies the integrated self-hosting fixpoint (kcc2==kcc3) + the compiler suite.
# Re-seed via stage0/reseed.sh only when a PARSER change makes the seed unable to compile the source.
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
ROOT=${0:A:h}
cd "$ROOT" || exit 1
SEED="$ROOT/bootstrap/kite-seed"
T=$(mktemp -d)
fail() { echo "❌ GATE FAILED: $1"; rm -rf "$T"; exit 1; }
[ -x "$SEED" ] || fail "seed missing ($SEED) — run stage0/reseed.sh"

echo "=== [1/2] compiler suite (correctness, built via seed CLI) ==="
zsh compiler/tests/run-compiler-tests.sh >"$T/suite.log" 2>&1
tail -1 "$T/suite.log"
grep -q "0 fail" "$T/suite.log" || fail "compiler suite not all-pass ($(grep '==' "$T/suite.log" | tail -1))"

echo "=== [2/2] integrated fixpoint (kcc2==kcc3) ==="
"$SEED" compiler/kitec.kite "$T/k1" >"$T/b1.log" 2>&1; [ -f "$T/k1" ] || fail "seed could not compile kcc source (re-seed?)"; chmod +x "$T/k1"
"$T/k1" compiler/kitec.kite "$T/k2" >/dev/null 2>&1; [ -f "$T/k2" ] || fail "kcc2 not produced"; chmod +x "$T/k2"
"$T/k2" compiler/kitec.kite "$T/k3" >/dev/null 2>&1; [ -f "$T/k3" ] || fail "kcc3 not produced (kcc2 crashed?)"; chmod +x "$T/k3"
cmp -s "$T/k2" "$T/k3" && echo "  kcc2 == kcc3 ✓ ($(wc -c <"$T/k2") bytes)" || fail "kcc2 != kcc3"

echo "✅ GATE PASSED (no OCaml, no shared /tmp) — suite green, kcc2==kcc3"
rm -rf "$T"
