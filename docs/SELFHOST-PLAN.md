# Kite — Self-Hosting Execution Plan

The single objective: **rewrite the Kite compiler in Kite, then have it compile
itself** (fixpoint), and retire the OCaml stage-0 (Fledge). Everything here is the
critical path to that. Language features, optimization, and tooling that don't
move self-hosting forward wait until after.

Owner: the compiler work is planned and driven here; branding/naming is the user's.

---

## Where we are (2026-08-16)

- **Stage-0 (Fledge, OCaml): front-end complete** (lexer, parser, AST, resolve,
  typecheck) + **self-built backend** (own AArch64 encoder, own Mach-O object
  writer, own linker, own ad-hoc code-signer — no clang/as/ld).
- **The compiler *shape* self-hosts**: real Kite programs written in Kite and
  compiled natively by Fledge — a token-list front-end, an environment/symbol
  table, and `stage1/minikite.kite`: a real (small) Kite front-end + tree-walking
  interpreter (functions, recursion, val/var, assignment, if/else, while, a real
  multi-variant AST built from a real token list). All pass `check` **and** `run`.
- **Backend hardened for big programs**: the >32-locals frame-slot blocker is
  fixed; `writeFile` output is plumbed; multi-file input works (`kitec run a.kite
  b.kite …` concatenates decls) so the compiler-in-Kite can span files.

The *architecture* is proven end-to-end in the bootstrap subset. What remains is
**scale**: grow these proofs into the actual Kite language and the actual backend.

---

## The phased plan

### Phase A — Solidify the bootstrap substrate  *(in progress)*
Make Fledge able to compile a multi-thousand-line Kite program without hitting a
wall. Done: >32 locals, strings/lists/structs/enums/patterns, file I/O + write,
multi-file input. Remaining likely gaps (fill as they surface, each verified):
- **Nested payload patterns** (currently one level; the real AST wants `Neg(Num n)`).
- More list/string builtins the compiler needs (e.g. `listSet`, `substr` edge cases).
- Robustness: never crash Fledge on a well-formed-but-large program.

### Phase B — Port the real Kite FRONT-END to Kite
Rewrite, in Kite (bootstrap subset), over the **real** Kite token/AST set:
1. **Lexer** → token list (all keywords, operators, punctuation, string literals,
   comments). Verify token-for-token against Fledge's `kitec lex`.
2. **Parser** → the real Kite AST. Verify by pretty-printing and diffing against
   `kitec parse`.
3. **Resolve + Typecheck**. Verify diagnostics match Fledge's `kitec check`.

### Phase C — Port the BACKEND to Kite
Rewrite in Kite: codegen (AST → instr IR → machine words), the Mach-O object/
executable writer, the linker, and the SHA-256 signer. Milestone: the Kite-written
backend, *run under Fledge*, emits a working native binary for a small program —
**byte-compare** its output against Fledge's own.

### Phase D — Fixpoint / self-host
`Fledge(OCaml)` compiles `kitec(Kite)` → `kitec₁`. `kitec₁` compiles `kitec(Kite)`
→ `kitec₂`. Assert `kitec₁` and `kitec₂` produce **identical** output (the fixpoint).
Drop OCaml. **Self-hosting achieved** (ROADMAP M7).

### Phase E — Grow in Kite  *(post-self-host)*
Now everything is Kite. Add the full language and tooling, in rough order:
generics/monomorphization → traits → ARC + zero-ceremony optimizer → comptime →
core stdlib → **the `kite` build tool + package manager** (the integrated umbrella:
`kite build/run/test/add`, manifest = a comptime-evaluated Kite file) →
extra backends (x86-64/ELF, WASM). This is ROADMAP M8+.

---

## Immediate next increments (ordered)

1. **Real Kite lexer in Kite** → `stage1/klex.kite`: tokenize real Kite source into
   a token list; diff against `kitec lex`. *(Phase B.1 — starts now.)*
2. **Real Kite parser in Kite** → build the real AST; diff against `kitec parse`.
3. **Nested patterns in Fledge** when the parser/checker port needs them (Phase A).
4. **Resolve/typecheck in Kite** (Phase B.3).

Then Phase C (the backend port), which is the largest single chunk.

---

## How each step is verified

- **Differential testing against the OCaml oracle**: the Kite port of each stage
  must match Fledge's output (`lex`/`parse`/`check`, and byte-identical machine code
  for codegen) on a corpus of `.kite` files.
- **Native exit codes / stdout** for the interpreter-style proofs.
- **The fixpoint** (Phase D) is the final proof of correctness.

## Build-system note (recap)

The build system is **not** a separate program — it is a *facet of one integrated
tool* (`kite`), which wraps the compiler (`kitec`), the build graph, the package
manager, and the test runner behind subcommands. We build our own (every serious
modern language does; ours is distinguished by a comptime-evaluated Kite manifest
instead of TOML). It is a **Phase E / M8** item — deliberately after self-hosting.
