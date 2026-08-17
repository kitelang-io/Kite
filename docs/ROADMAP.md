# Kite — Roadmap to Self-Hosting

> Working name **Kite** (rename anytime). A modern, self-hosting, multi-platform
> language: **Kotlin-flavored syntax, ARC memory (no GC), self-built native backend.**

## Locked design decisions

| Axis | Choice | Rationale |
|------|--------|-----------|
| Paradigm / surface | Kotlin-like ergonomics (`fun`/`val`/`var`, `when`, null-safety, data structs) | Modern, familiar, expression-oriented |
| Memory | **ARC + RAII, no GC** | "Swift core": deterministic, no GC runtime |
| Host (stage-0) | **OCaml** | Classic compiler language: ADTs + pattern matching |
| Backend | **Self-built native codegen** (no LLVM/C) | Full control, zero-dependency toolchain |
| First target | **AArch64 + Mach-O** (Apple Silicon) | The dev machine's arch |

## Language design

The full language spec lives in [`LANGUAGE-DESIGN.md`](LANGUAGE-DESIGN.md) —
produced by a multi-agent design pass (8 dimensions → coherence/feasibility/
north-star critique → synthesis). It defines the value/reference split
(`struct`/`enum` vs `class`), ARC details, `Result` + `try`/`try!`, generics +
traits, async/structured-concurrency, the full sigil table, and a per-milestone
staging plan. Kite's **signature identity** is two pillars — `comptime` (compile-time
execution unifying generics/const/derive/macros) + **zero-ceremony ARC** (GC
feel, manual performance, no borrow-checker ceremony); see the doc's Signature
identity section. It supersedes the earlier `LANGUAGE.md` sketch for anything
beyond the current bootstrap slice. Implementation-level detail for the four
interlocking areas (pattern matching, traits/generics/derives, closures/iterators,
core stdlib/formatting) and the exact bootstrap slice live in
[`LANGUAGE-DESIGN-DETAIL.md`](LANGUAGE-DESIGN-DETAIL.md).

## Compiler pipeline (stage-0)

```
source
  → lexer            (lib/lexer.ml)          [DONE]
  → parser → AST     (lib/parser.ml)         [DONE]
  → name resolution  (scopes, symbols)       [next: M2]
  → type checker     (inference + null-safety)
  → ARC insertion    (retain/release, ownership analysis)
  → IR lowering      (typed three-address / SSA-lite)
  → backend          (instr selection → regalloc → AArch64 machine code)
  → own Mach-O writer + own linker (MH_EXECUTE); dyld only at runtime
```

## Backend: two steps

- **Step A (to reach the milestone fast) — DONE.** Our codegen does instruction
  selection + register allocation and emits AArch64 (assembly text via `kitec
  asm` for inspection, and raw machine-code words for real builds). Our own
  backend, not blocked on external encoding/linking.
- **Step B — DONE (ahead of self-hosting).** `as`/`ld`/`clang` are fully
  replaced by our own **object-file emitter + linker** in `lib/macho.ml`:
  `write_object` (MH_OBJECT) and `write_executable` (fully-linked MH_EXECUTE,
  with dyld chained-fixups imports + ad-hoc code signature). Only `dyld` remains
  at runtime. x86-64/WASM and ELF/PE still ahead for multi-platform.

## Bootstrap stages

- **Stage 0** — compiler in OCaml, compiles the "bootstrap subset" to AArch64.
- **Stage 1** — compiler rewritten *in Kite*, compiled by stage-0 → native binary.
- **Stage 2** — stage-1 compiles its own source again.
  **Fixpoint: stage-1 and stage-2 output byte-identical ⇒ self-hosting achieved.**

## Milestones

- [x] **M0** — project scaffold builds; `kitec version` runs.
- [x] **M1** — lexer + recursive-descent/Pratt parser; `kitec parse` pretty-prints the AST.
- [x] **M2** — name resolution + type checker (functions, structs, primitives, null-safety).
- [ ] **M3** — IR + ARC insertion pass.
- [x] **M4** — AArch64 backend (Step A): compile & run arithmetic + functions natively.
- [ ] **M5** — enough features to write a compiler (strings, arrays, structs, `when`, I/O).
- [ ] **M6** — begin rewriting the compiler in Kite (stage-1 source).
- [ ] **M7** — stage-0 compiles stage-1; fixpoint reached. **Self-hosting.**
- [ ] **M8** — drop OCaml; add x86-64/ELF + WASM; own assembler/linker.

## Known bootstrap shortcuts (to revisit before self-hosting)

- **Statement separation: Go-style ATI — DONE.** The lexer inserts a NEWLINE
  terminator only after a token that can end a statement, and suppresses it
  before a leading `.`/`?.` (method chains). So trailing-operator continuations,
  multi-line `if`/`else`, `)`-then-newline-`{` bodies, and dotted chains all work.
  Residual limit: a continuation line still must not *begin* with a binary
  operator other than `.`/`?.` (wrap in parens).
- **String interpolation — DONE.** `"$name"` and `"${ expr }"` lex to an INTERP
  token (literal chunks + recursively-lexed expression parts) and parse to an
  `Interp` AST node; a string with no interpolation stays a plain STRING.
- **Triple-quoted raw strings — DONE.** `"""..."""` span lines, apply no
  backslash escapes (raw), but still interpolate (Kotlin-style).
- **`::` paths — partial.** `import a::b::c` uses `::`. Brace-grouping `{A, B}`,
  glob `::*`, and `as` renaming, plus `::` in expression paths and turbofish, are
  a later increment.
- **Declaration forms + pattern matching — DONE (partial).** `struct`/`class`
  paren primary constructors (`struct P(pub val x: Int, var y: Int)`) + optional
  `{ deinit { ... } }`; payloaded `enum`. **`when`**: subject `when (val n = e)`
  and subject-less forms; patterns `_` / int·float·char·string·bool·null literals
  (incl. negatives) / lowercase bindings / `::`-paths (unit variants) / ctor with
  positional (`Some(v)`, nested `Neg(Lit(n))`) and record args (pun / `x = pat` /
  trailing `..`) / `is`·`!is` / `in`·`!in` / `|` or-patterns; guards `if`. Also:
  char literals `'c'`, `|` (PIPE), and `::` paths in expressions (`Op::Add`).
- **Front-end (lexer + parser) — COMPLETE for the bootstrap surface** (~1860 LOC
  OCaml; 7 example programs parse). Now covers: generics in types
  (`List<T>`, `Map<K,V>`, `(A)->R`), generic params (`<T: Bound + …>`) + `where`;
  `trait` (supertraits, associated `type`, method sigs + default bodies); `impl`
  (trait & inherent, generic, associated-type bindings, methods); methods with
  receivers (`self`/`mut self`/`consuming self`) + param modes
  (`inout`/`consuming`); `@annotations` (`@derive(...)`, `@inline`, …); list/map
  literals `[a,b]`/`["k":v]`; indexing `a[i]`; turbofish `f::<T>()`; named args
  `f(x = 1)`; **closures/lambdas** `{ x -> … }`, implicit `it`, trailing lambdas
  `xs.filter { it > 0 }`; `return`/`break`/`continue` as diverging expressions.
  Small deferred bits: import brace-grouping/glob/`as`, `@file:` annotations,
  `consuming` in `when`-subject, `dyn` types.
- **M2 pass 1 — name resolution — DONE.** `lib/resolve.ml` + `kitec check`:
  builds the top-level symbol table (funs/types/enum variants/traits), flags
  duplicate top-level definitions, and walks every fn/method body over a lexical
  scope stack flagging unresolved *value* identifiers (locals + globals + a
  seeded prelude builtin set). Position-free diagnostics for now.
- **M2 pass 2 — type checker core — DONE.** `lib/typecheck.ml` (folded into
  `kitec check`): a deliberately *lenient* checker (unknowns compatible with
  everything, never false-positives) that infers a type for every expression and
  reports definite mismatches — arithmetic on non-numerics, wrong call arity,
  non-`Bool` `if`/`while`/guard conditions, annotation/return/body-vs-return
  incompatibilities, assigning a nullable to a non-null slot, unknown field access
  on a known struct. Builds signatures for funs + struct fields + enum names.
- **M2 remaining** — tighten the checker over subsequent increments: **AST source
  spans** (for positioned diagnostics), bidirectional inference for un-annotated
  lambdas/returns, null-safety flow typing (smart-casts), enum-variant &
  generic/trait method-call typing, trait solving (lookup+substitution), and
  monomorphization.
- **M4 walking skeleton — DONE (native code runs!).** `lib/codegen_arm64.ml` +
  `kitec asm` / `kitec run`: lowers a small subset (Int functions, `val`,
  `return`, `+ - * / %`, comparisons, unary neg, calls) **directly to AArch64
  assembly**, assembled+linked by the system toolchain; `main`'s Int result is
  the exit code. Verified end-to-end: `2 + 3 * 4` → 14; `sq(5)+add3(...)` → 31;
  `examples/native_demo.kite` → 24. A stack-machine strategy (temporaries on the
  CPU stack) — register allocation, a real IR, ARC, and more types come next.
- **Control flow in codegen — DONE.** `if`/`else` (as an expression, via
  `cbz`/branch) and `while` loops now lower to native code; verified with real
  algorithms compiled and run: **factorial(5)=120**, **gcd(48,36)=12**,
  **fib(10)=55** (`examples/native_loops.kite` → 67).
- **Backend broadened (agent workflow, all verified) — DONE.** `println`/`print`
  (libc printf, Darwin stack-vararg), `when` over integers, `for (i in a..b)`, and
  recursion now compile & run natively. Verified end-to-end: prints work,
  `classify(1)=200`, `sum 1..10=55`, `fact(5)+fib(10)=175`, regressions 24/67.
- **Own Mach-O emitter — DONE (clang/as dropped for assembling).** Fledge now
  **self-emits its own Mach-O `.o`**: `lib/codegen_arm64.ml`'s `encode_instr`/
  `assemble` produce raw AArch64 machine-code words + relocations, and
  `lib/macho.ml` writes the MH_OBJECT container (mach_header, LC_SEGMENT_64,
  LC_BUILD_VERSION, LC_SYMTAB, LC_DYSYMTAB, `__text`/`__cstring`, relocations,
  nlist symbol table) — byte-matched against `clang -c` reference objects via
  `otool`/`llvm-objdump`. `kitec obj` writes the self-emitted object;
  `kitec asm` renders assembly text for inspection.
- **Own linker — DONE (ld dropped; Fledge fully self-links).** `lib/macho.ml`'s
  `write_executable` is Fledge's own minimal LINKER: it writes a fully-linked,
  directly-runnable **MH_EXECUTE** — `__PAGEZERO`/`__TEXT`/`__DATA_CONST`(`__got`)/
  `__LINKEDIT` segments laid out at their runtime vm addresses, intra-image
  pc-relative branches + `adrp`/`add` to our own `__cstring` resolved, `LC_MAIN`
  entry set, and dyld **chained-fixups** bindings for external imports (`printf`
  from libSystem), plus an ad-hoc code signature — all byte-structure diffed
  against an `ld`-linked reference. `kitec run` now goes parse -> codegen ->
  encode -> **write MH_EXECUTE (Fledge)** -> execute; **NO external assembler or
  linker (as/ld/clang) is invoked anywhere** — only `dyld` loads the produced
  binary at runtime. (`kitec exe` writes the same self-linked executable without
  running it.) Verified by actually running the self-linked binaries: regressions
  24/67 plus return 14, println 42/7, sum 1..10=55, fact(5)+fib(10)=175 all run
  through the self-linked path.
- **Next (broaden toward M5):** a real **IR (M3)** + register allocation + ARC
  insertion → strings/collections → structs & enums in codegen →
  generics/monomorphization → the core stdlib. (The toolchain is now
  self-contained — own encoder, own object writer, own executable linker; only
  `dyld` remains at runtime.) **M5** = enough of that to write the compiler in
  Kite — a large multi-increment effort still ahead.

The stage-0 bootstrap compiler is named **Fledge** (language = Kite, binary = kitec).
- `when` supports only the subject-less form (`when { cond -> ... }`); the
  `when (x) { ... }` subject form and `is`/`in`/range patterns come later.
- No generics, traits, or closures in the bootstrap subset (see LANGUAGE.md).

## Build & run

```sh
export PATH="/opt/homebrew/bin:$PATH"
dune build
dune exec bin/main.exe -- version
dune exec bin/main.exe -- lex   examples/hello.kite
dune exec bin/main.exe -- parse examples/hello.kite
```
