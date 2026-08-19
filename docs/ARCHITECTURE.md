# Kite Compiler — Architecture

The Kite compiler is **self-hosting** (written in Kite, compiles itself to a byte-identical binary)
and now has a **decoupled backend**: a target-independent front/middle end feeds a swappable
machine backend through a single IR seam. This document describes the pipeline, the directory
layout, the IR contract, and how to add a new target.

## Pipeline

```
source.kite
   │  frontend/kfront.kite        lexer + parser          (full Kite surface grammar)
   ▼
surface AST  (F-prefixed enums: FExpr, FStmt, FFunc, FPat, ...)
   │  driver/klower.kite          lowering + closure conversion + type-directed desugars
   ▼                              (for→while, methods→UFCS, list literals, interpolation,
core AST  (Expr, Stmt, ...)        indexing, lambdas→lifted fns + heap closures)
   │  codegen/codegen.kite        AST → IR                (TARGET-INDEPENDENT)
   ▼
IR  (List<Instr>)  ◄──────────────── the decoupling seam ─────────────────►
   │  codegen/codegen.kite        optimize()  — target-independent IR peephole pass
   ▼
IR  (List<Instr>, optimized)
   │  backend/arm64/arm64.kite    IR → AArch64 machine code + Mach-O + ad-hoc code signature
   ▼
signed native executable  (macOS / arm64)
```

Two more independent tools sit beside the compile path (they do not gate `run`/`exe`):
- **frontend/kprint.kite** — prints the parsed AST in `kitec parse` form (differential parser test).
- **sema/kcheck.kite** — M2 name resolution + type check, matching `kitec check` (programmer diagnostics).

## Directory layout

```
compiler/
  kitec.kite    entry / module manifest — quoted-includes the four units below so the compiler assembles
                ITSELF via its own import (dogfooding), replacing a shell `cat`; byte-identical build.
  frontend/     kfront.kite  (lexer + surface AST + parser)   kprint.kite  (AST printer + test main)
  sema/         kcheck.kite  (name resolution + type check → `kitec check`-form diagnostics)
  codegen/      codegen.kite (core AST + the IR type `Instr` + AST→IR codegen)   ← target-independent
  backend/
    arm64/      arm64.kite   (IR→AArch64 encoder + two-pass assembler + Mach-O writer + SHA-256 signer)
  driver/       klower.kite  (the integrated full-language compiler driver)
  prelude.conf  the default-prelude CONFIG (data): names the lib modules auto-included into every
                program (see "Prelude" below). The compiler's only tie to the stdlib — a list of names.
  tests/        run-parser-tests.sh · run-check-tests.sh · run-compiler-tests.sh
                parser/ (corpus + golden/) · check/ (corpus + golden/ + expected/) · programs/ ·
                kenc_test.kite (backend self-test). The parser/checker harnesses diff kcc against the
                committed golden snapshots — no live oracle.
lib/            the **kite** standard library (kite:: resolves here): core.kite (kite::core),
                alloc.kite (kite::alloc), std.kite (kite::std); nested modules under these three
                top-level packages (e.g. lib/std/… = kite::std::…). The default prelude's code lives
                here too, each convention method WITH its type (Kotlin-style, no sugar package):
                lib/alloc/collections/list.kite (List/Map data structure + List_push/Map_size/list()/
                map()) + lib/core/string.kite (String_charAt/len/substr), injected via the prelude config.
bootstrap/      kite-seed — the committed prebuilt compiler and the SOLE bootstrap; the gate/suite build
                from it (NO OCaml). Also historical proof programs (calc, calcast, minikite, ...)
                The OCaml stage-0 (Fledge) is retired to its own repo (kitelang-io/fledge); it is only
                needed to reseed kite-seed after a parser change, and is no longer part of this tree.
docs/           LANGUAGE-DESIGN.md, ROADMAP.md, PHASE-E-PARSER.md, this file, ...
```

**Module system**: `import kite::core` (namespace path) resolves `kite::a::b` → `lib/a/b.kite` (the `kite`
root package maps to `lib/`; a package is a `.kite` file whose own-name directory holds its sub-modules —
Rust-2018 style, e.g. `lib/alloc/collections.kite` = `kite::alloc::collections`, and `lib/alloc.kite` can
carry alloc's own top-level items alongside). `import "path.kite"` (quoted) is a **flat textual include**
— no mangling; resolveImports splices the file's text in. `lowerInput` picks the route by whether the
input has a *namespace* import: namespace → the module pipeline, quoted-only → the flat include. **The
compiler assembles ITSELF this way**: `compiler/kitec.kite` quoted-includes its four translation units,
so it dogfoods its own import machinery while every cross-file call keeps its global name (the build is
byte-identical to the old shell `cat`, and the mangling code path never runs while compiling the compiler).
A module's top-level free functions are namespaced (`mod__fn`); `mod::name` and `use mod::name` resolve/alias.
**Visibility (方案 A / Rust model)**: collection of module *files* is transitive (everything needed links),
but *name visibility* follows `pub import` edges only. `import X` is a **private** dependency (X's code links,
X's names are NOT re-exported to your importers); `pub import X` **re-exports** X's names as part of your
public surface. A module's export surface = its own names + its `pub import` chain; each module auto-imports
the export surfaces of what it imports. So `import kite::alloc` gives you alloc's re-exported sub-modules
(collections/string) but NOT `collections`' private `import kite::core::option` — no transitive name leak.

**Prelude (default availability, config-driven)**: every program has an implicit prelude — the
language-primitive `List`/`Map` runtime plus the built-in nominal methods (`xs.push(x)`, `s.len()`,
`m.size()`) — so `[..]` list literals and `{..}` maps work with no `import`, like C/C++ default
availability. Crucially this is **configuration, not compiler code**: `compiler/prelude.conf` is a
newline list of `kite::` module names, and `injectHelpers` resolves each through the ordinary
`kite::`→`lib/` mapping and injects its functions as globals. The compiler has **no hardcoded prelude
and no coupling to lib/** — the prelude's code lives in the stdlib, each type's convention methods with
that type (Kotlin-style, no separate sugar package): List/Map + their methods at
`lib/alloc/collections/list.kite`, String's methods at `lib/core/string.kite`. Swapping the config or
those modules changes the defaults without touching the compiler.

**Bootstrap (OCaml retired)**: the gate compiles the current source with `bootstrap/kite-seed` to get
gen-1, then verifies self-reproduction (kcc2==kcc3) — no OCaml. The seed is the **sole** bootstrap and
stays valid across codegen/lowering changes; only a **parser** change that outdates it needs a reseed,
now done from the archived OCaml Fledge in its own repo (kitelang-io/fledge). This completes the M8 "drop
OCaml" milestone via a committed seed (à la Rust's stage0). The parser/checker regression net is no longer
a live Fledge oracle but committed golden snapshots (`compiler/tests/{parser,check}/golden/`) diffed against
kcc — regenerate a golden deliberately when adding syntax or checks.

## The IR seam — `enum Instr`

`codegen.kite` defines `enum Instr` and emits a `List<Instr>` per function. It contains **only IR**,
never machine bytes — verified: `codegen.kite` references no encoder/assembler/Mach-O function.
`backend/arm64/arm64.kite` is the sole consumer that turns `Instr` into bytes — verified: it
references no codegen internal.

### IR optimizer (`optimize` in codegen.kite)

Between codegen and the backend, `optimize(code)` runs a target-independent peephole pass over the
`List<Instr>`, iterated to a fixpoint. Current rewrites (all semantics-preserving, adjacency-guarded so a
label between two instructions blocks fusion): `IPush(r);IPop(r) → ∅`, `IPush(a);IPop(b) → IMov(b,a)`,
`IMov(r,r) → ∅`. Both drivers call it before `assembleReloc`/`entryOffset`. It shrinks the self-hosted
compiler's own binary by ~6% and is the natural home for future passes (const-fold, dead-store, ARC-insertion).

The IR is a small register/stack machine:
- **registers are virtual** — the integers in the IR (0 = accumulator, 1 = temp, 29 = frame, 31 = sp)
  are IR register ids; each backend maps them to real registers (arm64 maps them 1:1 to x0/x1/x29/sp).
- **operations** (purpose-named, target-neutral): moves & immediates (`IMovImm`/`IMov`/`IZero`),
  integer arith/bitwise/shift (`IAdd`/`ISub`/`IMul`/`IDiv`/`IAnd`/`IOr`/`IXor`/`IShl`/`IShr`),
  `ICmp`/`ICset`, stack `IPush`/`IPop`, frame-local load/store (`ILoadLocal`/`IStoreLocal`), offset
  load/store for struct & list fields (`ILoadOff`/`IStoreOff`/`ILoadByte`/`IStoreByte`), stack-top
  load/store (`ILoadTop`/`IStoreTop`), labels + relative branches (`IJmp`/`IJmpCond`/`IJmpZero`),
  `ICallL` (internal call to a label), `ICallSym` (call a symbol — internal → relative branch,
  external → reloc), `ICallReg` (indirect call through a register), `IFuncAddr` (address of a local
  function), `ISymHi`/`ISymLo` (address of a data symbol / cstring, hi/lo parts), `IEnter`/`ILeave`/
  `ISetFrame` (frame prologue/epilogue/set), `IStackAlloc`/`IStackFree` (frame growth). Every op's
  semantics is ISA-neutral — a second backend realizes them per target (e.g. an x86 backend fuses
  `ISymHi`+`ISymLo` into one rip-relative `lea`, and maps `ICallReg` to `call reg`).

## Adding a backend (e.g. x86-64, RISC-V, WASM)

Write a new `compiler/backend/<target>/<target>.kite` that provides the same surface the arm64 backend
does — consuming `List<Instr>` and producing the target's machine code + object file:
- `assembleReloc(instrs) -> {words, relocs}` (or the target equivalent) — encode each `Instr`;
- object/executable writer for the target's format (ELF / PE / Mach-O-x86 / wasm module);
- resolve internal branches/addresses and external symbol relocations.
Then the integrated compiler is `frontend/kfront + codegen/codegen + backend/<target>/<target> + driver/klower`.
**`codegen.kite` and everything above it are unchanged** — that is the point of the decoupling.

## Self-hosting fixpoints (do not break these)

- **integrated fixpoint**: `frontend/kfront + codegen + arm64 + driver/klower` compiled by itself is
  byte-identical (kcc2 == kcc3). The full-language compiler self-hosts.
Any backend/codegen change must keep it. The test scripts + the integrated fixpoint check are the gate.

## Current capabilities & gaps

**Compiles** (integrated compiler, verified end-to-end): fun/val/var/return, if/else (expr + stmt),
while, for (range + for-each over a List), arithmetic/bitwise/shift/comparison/logic, structs + fields +
field assignment, enums + `when` pattern matching, lists + list literals + indexing, **maps** (literals +
lookup, String/Int keys), strings + interpolation (literals via a `__cstring` pool; the ops charAt/strLen/strEq/concat/substr/intToStr are now pure-Kite prelude on raw bytes, not builtins), **floats** (boxed IEEE-754 double:
literals via `strtod`, `+ - * / < > <= >= == !=`, `toInt(f)` truncation — scalar-double FP codegen in the
arm64 backend), method calls (UFCS) + struct-body methods, and **closures / first-class functions** (lambdas
with captures, escaping, nesting, higher-order — via `IFuncAddr`+`ICallReg`).

**Generics**: work today by **type erasure** — every value is one word, so a generic fn/struct compiles once
for all `T` (verified: generic structs, higher-order generic fns, generic map). No monomorphization needed in
the boxed model.

**ARC**: every heap object carries a hidden **16-byte header** — refcount at `[obj-16]` and a runtime
**type-id** at `[obj-8]` — written by the single alloc funnel `genAllocHdr`. Primitives
`__retain`/`__release`/`__refcount`/`__typeId` (all nil-safe) work on any object; `__release` is
**type-directed** — a type with reference fields or a `deinit` dispatches to a generated `___rel_<T>` routine
that runs the destructor, releases fields depth-first, then frees (recursive/deep release). Automatic
retain/release **insertion** is done for **`class` (reference) types**: klower marks class-typed locals as
owned, retains on aliasing, zero-inits the slots at entry, and releases at **every** exit (fall-through and
returns nested in `if`/`when`), with a returned local transferring ownership; `deinit` runs on the last
release. Safe by construction for self-hosting — the compiler is written entirely in `struct`/`enum`, so its
own bodies are emitted unchanged. `struct`/`enum` remain value/leak types. Reassigning a `var` class local
(`x = other`) balances ARC (retain-new → release-old → store, safe for self-assignment). See docs/ARC-DESIGN.md.

**Traits / methods**: struct-body methods, inherent `impl` blocks, and `impl Trait for Type` blocks register
as UFCS methods, **mangled by owner** (`Circle_area` vs `Square_area`); a concrete-typed call resolves
statically (falling back to a bare free function — UFCS). Otherwise — a **trait-typed** receiver (`s: Shape`)
*or* an **erased** one (an element pulled from a `List<Shape>`) — uses **dynamic dispatch**: a generated
`___dyn_<Trait>_<m>` switch reads the object's type-id header and calls the right impl, with no boxing (the
object carries its own type). Trait **default methods** (a trait method with a body) are synthesized as
`<Type>_<m>` for any impl that doesn't override them.

**Nullable**: `?.` / `?:` / `!!` lower against a 0-pointer null (`a?.f` → null-guarded field, `a?:b` → elvis,
`a!!` → `abort()` on null).

**Comptime**: `comptime(expr)` and `const NAME = expr` are evaluated by a compile-time **interpreter**
(literals, arithmetic/bitwise/compare, params/locals, `if`/`while`, calls to pure functions incl. recursion —
`const N = fib(10)`) and replaced by a literal. Int-returning operations over **heap-valued literals** work too
(`comptime(strLen("hi"))`, `comptime(listGet([10,20,30], 2))`).

**Float printing**: `println`/`print` of a `Float` lower to `%g` (the double is passed as a stack vararg per
the Apple arm64 variadic ABI).

**Modules**: `import kite::a::b` (namespace) engages the module system — a file module's top-level FREE
FUNCTIONS are mangled `b__name`, so two modules may define the same name without colliding. Inside a module
an unqualified reference resolves to that module's own item first, else a `use`/import alias, else global;
`mod::name` selects the mangled item; `use mod::name` aliases bare `name`. Name visibility follows `pub
import` edges (see the module-system paragraph above). `import "x.kite"` (quoted) is instead a **flat
textual include** — no mangling. `use` is a RESERVED keyword (lexer token 81). Fixpoint-safe by
construction: the compiler assembles itself with QUOTED includes (`compiler/kitec.kite`), which never
engage the mangling pipeline (`collectModules`/rename/`parseLowerModules`), so that code never runs while
compiling the compiler.
v1 limitation: only free functions are namespaced — types/enums/traits/impls/consts and struct-method bodies stay
global; `mod::a::b` nested paths and per-module type collisions are future work.

**Not yet**: computed (non-literal) heap values in comptime, generic trait bounds (`<T: Show>`), a second
target backend. The **front end parses the full language**; the limit is what codegen lowers, not what can be
parsed.
