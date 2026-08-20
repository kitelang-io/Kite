#!/bin/zsh
# compiler/tests/run-shadow-scan.sh — Phase M2 member-table SHADOW harness.
#
# Builds the self-hosted compiler (kcc) from the committed seed, then runs `kcc shadow <file>`. As of
# Phase M2 the `shadow` verb runs the RESOLVER's selector-resolution pass (kcheck.kite rShadowField /
# rShadowStatic): for every dot / `::` selector it cannot resolve against the member table it prints a
# "SHADOW <path>: line N: no member ..." line (never fatal, writes no binary — the shadow log is diverted
# from the real diagnostics). The resolver has NO receiver TYPE at a dot access, so `a.sel` is resolved at
# the NAME level (does `sel` exist as SOME member / free-fn / trait-method?); `Base::sel` is TYPE-DIRECTED
# when Base is a known nominal.
#
# METHODOLOGY — scan COMPLETE COMPILATION UNITS, not fragments. A leaf like compiler/driver/klower.kite is
# NEVER compiled alone: it is assembled into compiler/kitec.kite, which quote-includes the AST struct
# definitions (compiler/frontend/kfront.kite) that klower's `x.body` / `x.params` selectors reach into.
# Scanned in ISOLATION those cross-module struct fields are absent from the per-file table and the resolver
# — lacking the receiver type — flags every one as a would-be no-member. Those are a SCAN-GRANULARITY
# artifact, not a table miss: they all vanish when the file is scanned as the unit it actually compiles as.
# So the headline scan below runs the real compilation ROOTS + every self-contained lib/ module + the
# whitelist fixture; a second, clearly-labelled per-file pass surfaces the fragment artifact for the record.
#
# Usage: compiler/tests/run-shadow-scan.sh            # builds kcc from the seed
#        KCC=/path/to/kcc compiler/tests/run-shadow-scan.sh   # reuse an already-built compiler
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
ROOT=${0:A:h:h:h}
cd "$ROOT" || exit 1
TMPD=$(mktemp -d)

if [ -z "$KCC" ]; then
  KCC="$TMPD/kcc"
  echo "building the self-hosted compiler (kcc) via the seed ..."
  "$ROOT/bootstrap/kite-seed" compiler/kitec.kite "$KCC" >"$TMPD/build.log" 2>&1
  [ -f "$KCC" ] || { echo "SEED BUILD FAILED"; cat "$TMPD/build.log"; rm -rf "$TMPD"; exit 1; }
  chmod +x "$KCC"
fi

# ---- (A) COMPLETE-UNIT scan: the real compilation roots + self-contained lib modules + the fixture ----
ULOG="$TMPD/shadow-units.log"
: > "$ULOG"
UNITS=(
  compiler/kitec.kite            # the whole self-hosted compiler (includes kfront/kcheck/codegen/backend/klower)
  compiler/tools/kitefmt.kite    # the kitefmt tool root (includes kfront + driver/kfmt.kite)
  compiler/tests/programs/member-table-whitelist.kite  # Phase M2 whitelist fixture (one per selector kind)
)
# every lib/ module is self-contained relative to the prelude, so each is a complete unit on its own
for f in ${(f)"$(find lib -name '*.kite' | sort)"}; do UNITS+=("$f"); done
UN=0
for f in "${UNITS[@]}"; do "$KCC" shadow "$f" >>"$ULOG" 2>>"$ULOG"; UN=$((UN+1)); done
UTOTAL=$(grep -c "^SHADOW " "$ULOG"); UTOTAL=${UTOTAL:-0}

echo ""
echo "=== [A] COMPLETE-UNIT scan: $UN units, $UTOTAL false positive(s) ==="
echo "   (this is the go/no-go count for the M3 error-flip; the goal is ZERO)"
grep '^SHADOW-TOTAL' "$ULOG" | awk '$3>0{print "   " $2, $3}'
grep '^SHADOW ' "$ULOG" | sed -E 's|^SHADOW [^:]+: line [0-9]+: ||' | sort | uniq -c | sort -rn | sed 's/^/   /'

# ---- (B) per-file fragment pass: surfaces the cross-module struct-field artifact, for the record ----
PLOG="$TMPD/shadow-perfile.log"
: > "$PLOG"
FILES=$( { find lib -name '*.kite'; find compiler -name '*.kite' ! -path '*/tests/*'; } | sort )
PN=0
for f in ${(f)FILES}; do "$KCC" shadow "$f" >>"$PLOG" 2>>"$PLOG"; PN=$((PN+1)); done
PTOTAL=$(grep -c "^SHADOW " "$PLOG"); PTOTAL=${PTOTAL:-0}

echo ""
echo "=== [B] per-file ISOLATED scan: $PN files, $PTOTAL cross-module fragment artifact(s) ==="
echo "   (files compiled only as part of a larger root; every miss here is a struct field whose defining"
echo "    type lives in another file — ALL resolve to 0 under the complete-unit scan above)"
grep '^SHADOW-TOTAL' "$PLOG" | awk '$3>0{print "   " $2, $3}'

echo ""
echo "unit log: $ULOG"
echo "per-file log: $PLOG"
# Diagnostic collector, not a gate — always exit 0 so it can run informationally in the pipeline. The M3
# error-flip is guarded separately; it may only proceed while the COMPLETE-UNIT count [A] stays ZERO.
exit 0
