#!/bin/zsh
# Differential test: our Kite jq vs the real /usr/bin/jq, over the supported subset.
#
# For every (filter, JSON) pair we run BOTH implementations and require byte-identical output. We
# compare against `jq -c` (compact) because our printer is compact, and we restrict inputs to the
# subset this port implements faithfully: integer numbers (our jv truncates fractions), and the
# filters `.`  `.field`  `.a.b`  `.[N]`  `.[-N]`  `.[]`  `|`  `length`  `keys`  `add`.
# Numeric `add` only (our `add` sums numbers; jq's also concatenates strings/arrays — out of scope).
set -u
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
ROOT=${0:A:h:h:h}
cd "$ROOT"
command -v jq >/dev/null || { echo "SKIP: system jq not installed"; exit 0; }

TMP=$(mktemp -d)
echo "building examples/jq via the seed ..."
./bootstrap/kite-seed examples/jq/main.kite -o "$TMP/jq" >"$TMP/build.log" 2>&1 || { echo "BUILD FAILED"; cat "$TMP/build.log"; exit 1; }
chmod +x "$TMP/jq"
MINE="$TMP/jq"

# JSON fixtures (integers only).
cat > "$TMP/obj.json"  <<'EOF'
{"name":"kite","version":3,"tags":["compiler","arm64","self"],"nested":{"b":20,"a":10},"nums":[3,4,5]}
EOF
cat > "$TMP/arr.json"  <<'EOF'
[10,20,30,40]
EOF
cat > "$TMP/deep.json" <<'EOF'
{"items":[{"id":1,"v":100},{"id":2,"v":200},{"id":3,"v":300}],"count":3}
EOF
cat > "$TMP/scal.json" <<'EOF'
{"a":5,"c":7,"b":6}
EOF

pass=0 ; fail=0
check() {  # $1 = filter   $2 = json file
  local q="$1" f="$2"
  local want got
  want=$(jq -c "$q" "$f" 2>/dev/null | tr '\n' '|')
  got=$("$MINE" "$q" "$f" 2>/dev/null | tr '\n' '|')
  if [ "$want" = "$got" ]; then
    pass=$((pass+1)); printf "  PASS  %-22s %-10s -> %s\n" "$q" "${f:t:r}" "$got"
  else
    fail=$((fail+1)); printf "  FAIL  %-22s %-10s\n        jq: %s\n        me: %s\n" "$q" "${f:t:r}" "$want" "$got"
  fi
}

echo "== differential cases (our jq vs jq $(jq --version)) =="
check '.'                 "$TMP/obj.json"
check '.name'             "$TMP/obj.json"
check '.version'          "$TMP/obj.json"
check '.tags'             "$TMP/obj.json"
check '.tags[0]'          "$TMP/obj.json"
check '.tags[2]'          "$TMP/obj.json"
check '.tags[-1]'         "$TMP/obj.json"
check '.tags[]'           "$TMP/obj.json"
check '.nested'           "$TMP/obj.json"
check '.nested.a'         "$TMP/obj.json"
check '.nested.b'         "$TMP/obj.json"
check 'keys'              "$TMP/obj.json"
check '.nested | keys'    "$TMP/obj.json"
check '.tags | length'    "$TMP/obj.json"
check '.nested | length'  "$TMP/obj.json"
check '.name | length'    "$TMP/obj.json"
check '.nums | add'       "$TMP/obj.json"
check '.nums | length'    "$TMP/obj.json"
check '.nums[]'           "$TMP/obj.json"
check '.'                 "$TMP/arr.json"
check '.[0]'              "$TMP/arr.json"
check '.[-1]'             "$TMP/arr.json"
check '.[]'               "$TMP/arr.json"
check 'length'            "$TMP/arr.json"
check 'add'               "$TMP/arr.json"
check '.items'            "$TMP/deep.json"
check '.items[]'          "$TMP/deep.json"
check '.items[0]'         "$TMP/deep.json"
check '.items[] | .id'    "$TMP/deep.json"
check '.items[] | .v'     "$TMP/deep.json"
check '.count'            "$TMP/deep.json"
check 'keys'              "$TMP/deep.json"
check 'keys'              "$TMP/scal.json"
check '.a'                "$TMP/scal.json"

echo "== jq differential: $pass pass, $fail fail =="
rm -rf "$TMP"
[ $fail -eq 0 ]
