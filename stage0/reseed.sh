#!/bin/zsh
# Re-seed bootstrap/kite-seed from the current compiler source via the archived OCaml Fledge (stage0/).
# This is the ONLY place OCaml/dune is used. Run it when a PARSER-level change makes the current seed
# unable to compile the source (the gate will tell you: "seed could not compile ... — re-seed?").
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
ROOT=/Users/john/AndroidStudioProjects/Language
cd "$ROOT" || exit 1
echo "re-seeding via OCaml Fledge (stage0) ..."
dune exec stage0/bin/main.exe -- exe \
  compiler/frontend/kfront.kite compiler/codegen/codegen.kite \
  compiler/backend/arm64/arm64.kite compiler/driver/klower.kite || { echo "reseed FAILED"; exit 1; }
mv compiler/frontend/kfront bootstrap/kite-seed; chmod +x bootstrap/kite-seed
echo "re-seeded bootstrap/kite-seed ($(wc -c <bootstrap/kite-seed) bytes)"
