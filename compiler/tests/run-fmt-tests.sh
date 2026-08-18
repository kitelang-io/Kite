#!/bin/zsh
# run-fmt-tests.sh — verify the standalone `kitefmt` formatter.
#
# NO OCaml, NO shared /tmp: kitefmt is built from the committed seed (bootstrap/kite-seed) into a
# private mktemp dir, so this is safe to run in parallel git worktrees. Three checks:
#   1. kitefmt BUILDS as its own program via the seed CLI (it is not baked into kitec anymore).
#   2. IDEMPOTENCY on a corpus sample: format(format(x)) == format(x).
#   3. ACID TEST (semantics-preserving): format EVERY .kite in a throwaway copy of the tree, rebuild
#      kitec from the formatted sources via the seed, and assert the binary is BYTE-IDENTICAL to the
#      kitec built from the same tree UNformatted. Formatting must not change what the compiler emits.
set -u
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
ROOT=${0:A:h:h:h}
cd "$ROOT" || exit 1
SEED="$ROOT/bootstrap/kite-seed"
T=$(mktemp -d)
fail() { echo "❌ FMT TESTS FAILED: $1"; rm -rf "$T"; exit 1; }
[ -x "$SEED" ] || fail "seed missing ($SEED)"

echo "=== [1/3] build kitefmt via the seed (standalone tool) ==="
"$SEED" compiler/tools/kitefmt.kite -o "$T/kitefmt" >"$T/build.log" 2>&1 || { cat "$T/build.log"; fail "kitefmt did not build"; }
[ -f "$T/kitefmt" ] || fail "kitefmt binary not produced"
chmod +x "$T/kitefmt"
FMT="$T/kitefmt"
echo "  kitefmt built ✓ ($(wc -c <"$FMT" | tr -d ' ') bytes)"

echo "=== [2/3] idempotency on a corpus sample ==="
CORPUS=(
  compiler/driver/kfmt.kite
  compiler/driver/klower.kite
  compiler/frontend/klex.kite
  compiler/tools/kitefmt.kite
  examples/jq/jv.kite
  lib/core/ops.kite
)
for f in "${CORPUS[@]}"; do
  [ -f "$f" ] || continue
  "$FMT" "$f" >"$T/a" 2>/dev/null || fail "kitefmt errored on $f"
  cp "$T/a" "$T/a.kite"
  "$FMT" "$T/a.kite" >"$T/b" 2>/dev/null || fail "kitefmt errored re-formatting $f"
  cmp -s "$T/a" "$T/b" || fail "NOT idempotent on $f"
  echo "  idempotent ✓ $f"
done

echo "=== [3/3] acid test: format all .kite, rebuild kitec, assert byte-identical ==="
W="$T/tree"
mkdir -p "$W"
# Copy every source dir kitec's build reads (compiler + lib prelude) plus examples/docs so the
# "format ALL .kite" pass is honest. bootstrap/kite-seed we reference via $SEED, not the copy.
cp -R compiler lib examples docs "$W"/ 2>/dev/null
( cd "$W" && "$SEED" compiler/kitec.kite kitec.ref >"$T/ref.log" 2>&1 ) || { cat "$T/ref.log"; fail "reference kitec build failed"; }
[ -f "$W/kitec.ref" ] || fail "reference kitec not produced"
# format every .kite in the throwaway tree in place
find "$W" -name '*.kite' -print0 | while IFS= read -r -d '' f; do
  "$FMT" -w "$f" >/dev/null 2>&1 || { echo "kitefmt -w failed on $f"; exit 1; }
done
( cd "$W" && "$SEED" compiler/kitec.kite kitec.fmt >"$T/fmt2.log" 2>&1 ) || { cat "$T/fmt2.log"; fail "kitec build from FORMATTED sources failed (formatter broke the source)"; }
[ -f "$W/kitec.fmt" ] || fail "kitec from formatted sources not produced"
cmp -s "$W/kitec.ref" "$W/kitec.fmt" || fail "kitec differs after formatting — NOT semantics-preserving"
echo "  formatted-source kitec == unformatted-source kitec ✓ ($(wc -c <"$W/kitec.ref" | tr -d ' ') bytes)"

echo "✅ FMT TESTS PASSED — kitefmt builds standalone, is idempotent, and is semantics-preserving"
rm -rf "$T"
