# Kite Platform-Layer Frameworks Roadmap

**Status:** design proposal (execute-against). **Companion to** `docs/STDLIB-REDESIGN.md` — this document assumes that doc's vocabulary (phases 0–10, the bootstrap/target tier split, the role registry, the intrinsic floor) and does not re-argue it. **Invariant that governs everything, unchanged:** the self-hosting fixpoint `kcc2 == kcc3` stays byte-identical at every step; every framework here is built so it *cannot* move a byte of `kitec`. **Sequencing:** the execution of this roadmap runs **after** the STDLIB-REDESIGN 10-phase roadmap — it depends on Phase 0's role/manifest decoupling, Phase 0.5's `Diagnostic`/`Span` substrate and stderr floor, and (for the richer pieces) the numeric tower, collections tier, and typed-AST channel that land across phases 1–10. Where a framework can start earlier against today's front-end, that is called out.

---

## 1. Executive Summary — the platform layer on one page

Kite has reached self-hosting and is decoupling its compiler from its stdlib. What it does **not** yet have is a *platform*: the tools a language needs around the compiler so that people (and the compiler's own maintainers) can test, diagnose, edit, document, and distribute Kite code. Today those jobs are done by shell scripts, exit codes, golden-diff `grep`, and `__abort()` — everything is out-of-band, none of it is written in Kite, and the language cannot test, diagnose, or introspect itself.

**The guiding principle — one pattern, proven once, repeated:** every framework in this document ships as a **standalone tool + a `lib/` library**, both **reusing the shared front-end** (`kfront.kite`'s single lexer/parser, `kcheck.kite`'s resolver/checker, and the Phase-0.5 `Diagnostic`/`Span` substrate), and each is **kept OUT of the self-hosting `kitec`** — exactly the pattern `kitefmt` established (`compiler/tools/kitefmt.kite` + `compiler/driver/kfmt.kite`, quoted-importing `kfront.kite`, built on demand by the seed, never linked into the compiler). There is never a parallel lexer to drift, the fixpoint is never at risk, and each tool is one more external consumer of the front-end *as a library* — which is precisely the forcing function that drives the compiler to expose a clean **analysis boundary**, the on-ramp to full modularization and dependency/package management.

**The toolchain entry — `bridle`.** One user-facing umbrella command (a kite's *bridle* is where the control lines attach — the steering point; this is Kite's answer to `cargo`) fronts the whole toolchain: `bridle build` / `test` / `fmt` / `run` / `add` / `doc` / `lint` / `lsp` dispatch to the decoupled tools (`kitec` / `kitetest` / `kitefmt` / `kpkg` / `kite-doc` / `kite-lint` / `kite-lsp`), each of which stays independently invocable. `bridle` is itself a *thin dispatcher* — it links none of the tools, only execs them — so the decoupling discipline holds all the way up to the entry point, and `bridle` is just one more standalone binary reusing nothing of `kitec`'s internals. (Name chosen for uniqueness — no collision with common Linux/macOS commands/packages.)

**The frameworks and their spine:**

- **Test framework** (§2) — a Kite-native `kitetest` runner + `lib/test/` assertion library that lets Kite test itself and retires `gate.sh` / `run-*-tests.sh` / `difftest.sh`.
- **Error framework** (§3) — humane runtime errors (no more silent segfault or heap corruption): one located panic funnel `__panicAt` over Phase-0.5's `Diagnostic` + `__abort`, plus `?`/`unwrap`/bounds-checks. The worked example is `fib.kite`'s `array[11]` out-of-bounds read.
- **Language server** (§4) — a `kite-lsp` over stdio JSON-RPC, the tool that finally forces spans to stop being baked into message strings.
- **Others** (§5) — doc generator, linter, REPL, debugger/disassembler bridge, coverage/profiler, fuzzer/property-testing — each on the same decoupled template.
- **Modularization + packages** (§6) — the endgame the whole decoupling effort has been aimed at: `kite.pkg` manifests, a `kpkg` resolver, versioned stdlib packages, and one new compiler seam (a resolved module→path map).

**Honest dependency chain (stated up front, detailed per section):** the LSP is hard-blocked on structured spans (Phase 0.5 finished honestly) *and* on new stdin/stdout floor intrinsics + a JSON library; the test framework's `assertThrows`/panic-corpus needs the error framework's located `__panicAt`; the error framework's `file:line` injection needs a source line threaded onto the AST — the same span work the LSP needs, so **span-threading is shared infrastructure, landed once**; the package manager's scalability is blocked not on the manifest but on the compile-unit→object→link boundary (STDLIB-REDESIGN §3h). None of these dependencies are hidden; the phasing in §7 respects them.

---

## 2. Test Framework — Kite testing itself, shell-free

### 2.1 Current state — everything is shell, exit-code, and golden-diff

Six scripts carry the entire regression net:

- **`gate.sh`** — the orchestrator. Bootstraps `kitec` from `bootstrap/kite-seed` into a `mktemp -d`, then runs `run-compiler-tests.sh` (grepping stdout for the literal `"0 fail"`), the three-stage fixpoint (`seed→k1→k2→k3`, `cmp -s k2 k3`), `run-fmt-tests.sh` (grep `"FMT TESTS PASSED"`), and three robustness probes over `compiler/tests/bugs/` asserting the **raw shell exit code** (`rc==139` = SIGSEGV must-not-happen; `rc==0` = must-have-errored; grep stderr for `"unsupported construct"`; assert stdout empty). Pass/fail is grep-over-logs.
- **`compiler/tests/run-compiler-tests.sh`** — a `TESTS=(path:exitcode …)` array of ~60 entries; `check()` compiles each `.kite` to a native binary, runs it, compares `$?` to the expected integer. The entire assertion surface is "program exits with code N"; anything richer is smuggled into an exit code by the program itself.
- **`run-parser-tests.sh`** — builds `kparse_driver.kite` (kfront+kprint), runs it on each corpus file, strips the `-> exit code` line with `grep`, diffs the AST dump against `compiler/tests/parser/golden/<base>.txt`. No-golden files are smoke-only.
- **`run-check-tests.sh`** — runs `kcc check F`, then TWO diffs against goldens: a content view (`sed -E 's|^error: line [0-9]+: |error: |'` to drop positions) vs `check/golden/<base>.txt`, and a raw position view vs `check/expected/<base>.txt`. Fragile `sed` normalization; goldens are opaque blobs.
- **`run-fmt-tests.sh`** — kitefmt idempotency (`format(format(x))==format(x)` via `cmp`) + an ACID test (reformat a tree copy, rebuild kitec, assert byte-identical).
- **`examples/jq/difftest.sh`** — differential vs `/usr/bin/jq`: run 33 (filter, json) pairs through both, `tr '\n' '|'`, string-compare.

**Pain, concretely:** (a) every script hardcodes `export PATH="/opt/homebrew/bin:…"` (Apple-Silicon-only; STDLIB-REDESIGN §3g flags it); (b) assertions are exit-code-or-golden only — no `assertEquals` with an expected/actual message, no per-assertion location; (c) results are recovered by grepping logs for magic strings, brittle; (d) the mktemp/seed-build/chmod boilerplate is copy-pasted across all five; (e) golden files are byte blobs regenerated by hand, with ad-hoc `sed` normalization that itself can drift; (f) no single-test selection, no timing, no machine-readable (TAP/JUnit) output for CI; (g) **tests cannot be written in Kite** — the stdlib redesign's own new `Vec`/`HashMap`/trait code has nowhere Kite-native to assert behavior.

**Infra already present to build on:** `main(argc, argv): Int` where the return is the process exit code; the `__argv`/`readFile`/`writeFile`/`__abort`/`eprintln`/`eprint` floor; the `Diagnostic`/`Span` type + `renderDiag`/`emitDiag` single sink (`kfront.kite:32–65`); the `@name(args)` annotation machinery (`struct Anno`, `parseAnnos`, an `annos` field on every decl); and the kitefmt precedent.

### 2.2 Design — a library half and a standalone-tool half

**Two halves, mirroring kitefmt.** All assertion + reporting logic lives in a Kite **library** `lib/test/`; discovery, main-synthesis, compile, spawn, and collection live in a **standalone `kitetest` tool** (`compiler/tools/kitetest.kite` + `compiler/driver/ktest.kite`). `kitec` is untouched — a test subcommand *in* `kitec` would grow its fixpoint, the exact mistake kitefmt was extracted to undo.

**Test declaration — `@test` annotation, not a naming convention.** The `Anno` infra already threads onto every `FFunc`, so discovery is: kfront-parse the file, walk top-level `FFunc`s, keep those whose `annos` contain `"test"`. Annotations beat a `test_*` convention because they carry data the runner needs: `@test("descriptive name")`, `@ignore("flaky, #12")`, `@shouldAbort`, `@timeout(500)`. Same family for fixtures (`@beforeEach`/`@afterEach`/`@beforeAll`/`@afterAll`) and `@bench`. A test fn is nullary, returns `Unit`, and reports by *calling assertions*, not by return value.

**Assertions (`lib/test/assert.kite`) — soft/accumulating, because Kite has no unwinding.** A failed assertion cannot abort the test body mid-function (no exceptions; `__abort` would kill the whole run). So assertions record into a process-global `TestCtx` sink (current test name + `List<Failure>` of `{message, expected, actual, Span}`) and **continue** — JUnit's `assertAll` soft-assert model, which happens to be the only model the language natively supports. A test fails iff it recorded ≥1 failure. Surface: `assertEquals(exp, act)`, `assertEqualsMsg(exp, act, msg)`, `assertTrue`/`assertFalse(cond)`, `assertNotEquals`, `assertNull`/`assertNotNull` (nullable), `fail(msg)`, and typed variants once the numeric tower (STDLIB-REDESIGN §2a) lands. Failure detail renders through the existing `renderDiag`/`Span` machinery — reuse, don't reinvent.

**`assertThrows` is the honest hard case** and is where this framework **depends on the error framework (§3):** `panic`/`assert` desugar to `__abort` — a hard process exit, uncatchable in-process without the `setjmp`/`longjmp` the runtime lacks. So the split, documented rather than faked: (1) *in-process*, prefer `assertErr(result)`/`assertOk(result)` over `Result` (no unwinding, matches §3's `?`-direction); (2) *hard aborts asserted out of process* by the subprocess runner (`@shouldAbort` → child must exit via SIGABRT/nonzero, decoded from the wait status).

**Runner — standalone `kitetest`.** It (1) kfront-parses each `*_test.kite`, discovering `@test`/`@before*`/`@after*`; (2) **synthesizes a `main`** — writes `<original source>` + a generated `main(argc, argv)` (a `TestCtx`, before-all calls, a loop that per test resets the ctx, runs before-each/test/after-each, prints its result, tallies) to a temp file; (3) invokes the normal `kitec` pipeline to compile it; (4) spawns the binary, collects stdout/stderr/exit; (5) aggregates + reports. Main-synthesis is required because Kite has no reflection/static-init to self-register tests.

**The real cost, stated plainly — one new floor intrinsic.** Steps 3–4 need `__exec(path, argvList, stdoutPath, stderrPath): Int` (fork/exec/waitpid with output redirected to files, then `readFile` to capture), returning the **raw wait status** so signals (139 = SIGSEGV, SIGABRT) are distinguishable from clean exits. That single intrinsic is what makes the *compiler-behavior* tests expressible in Kite at all. A second small intrinsic, `__fileBytesEqual(a, b): Bool`, is needed because `readFile` is NUL-terminated and truncates binaries — byte-comparing two executables (the fixpoint check) needs a NUL-safe compare. A third, `__clockMs(): Int`, lands only if benchmarks/timing do. All are added to `intrinsicFloor()` (from which `isIntrinsic` derives) — the existing single-source-of-truth pattern — and grouped/labelled a **"process/host shim"** alongside the libc-shim I/O group, honest that they are a stopgap until STDLIB-REDESIGN §4's `@extern` FFI can express fork/exec as a library over declared externals.

**Reporting (`lib/test/report.kite`) — pretty default, TAP + JUnit opt-in.** `--format=pretty` (colored PASS/FAIL, per-failure expected/actual + location, `"N passed, M failed, K skipped in T ms"` footer); `--format=tap` (`ok 1 - name` / `not ok 2 - …` + `# diagnostic` lines — trivial from Kite `println`, recommended CI primary); `--format=junit` (a `StrBuilder` of `<testsuite>`/`<testcase>` XML, more code, opt-in). Pretty progress on **stdout**; assertion **diagnostics go through `eprintln`** so gate.sh's clean-stdout golden discipline (STDLIB-REDESIGN §3e) is preserved.

**Fixtures:** `@beforeEach`/`@afterEach` around every test, `@beforeAll`/`@afterAll` once per file, wired by the synthesized main. No DI container — fixtures are plain helper fns returning constructed values, called explicitly (matches Kite's no-magic ethos).

### 2.3 Expressing the four existing test kinds — the crux

This is what makes the shell scripts retirable. `lib/test/compile.kite` + `lib/test/golden.kite` are category-2 libraries over `__exec`:

- **Exit-code programs** (`run-compiler-tests`): `compileRun(srcPath): Int = __exec(kitec, [src, out])` then `__exec(out, [])`; `assertExit(compileRun(p), want)`. The `TESTS=(path:code)` array becomes a data-driven `@test` looping a `List<Case>`.
- **Golden / differential** (parser AST, checker): `assertGolden(actual, goldenPath)` reads the golden via `readFile`, compares, and — with `kitetest --update` — **rewrites it** (snapshot testing, subsuming manual golden regeneration). The `sed` normalization becomes a Kite `normalize(s)` fn (drop `line N:` prefix, canonicalize the count trailer) kept beside the assert. AST dumps come from `__exec(kparse_bin, [src])` stdout; checker output from `__exec(kitec, [check, src])`.
- **Self-host fixpoint:** `@test fun fixpoint()` execs `k1→k2→k3` then `assertFilesEqual(k2, k3)` via the NUL-safe `__fileBytesEqual`.
- **Robustness** (must-not-segfault): `assertNotSignaled(status)` / `assertExitedWith(status, code)` decode the raw wait status from `__exec` — exactly gate.sh's `rc==139` logic, but as a named assertion with a real message.

The **jq differential** becomes `assertSameOutput(exec(ourJq, args), exec(sysJq, args))` — the one test legitimately depending on an external binary; guard with a skip if `jq` is absent.

Once all four kinds are migrated, **`gate.sh` collapses** to `kitetest --format=tap compiler/tests/`; the seed-build/mktemp/grep-for-magic-string boilerplate and the hardcoded Homebrew PATH disappear into the tool, and CI consumes TAP instead of scraping logs.

### 2.4 Phases (each independently gated; kitec byte-frozen throughout)

1. **Assertion library, no floor change.** `lib/test/assert.kite`: `TestCtx` sink + soft assertions, rendering failures through `renderDiag`/`Span`. Dogfood with one hand-written test file that has its own `main`, imports the lib, self-reports — proves the model with **zero new intrinsics**.
2. **`__exec` floor + kitetest discovery/synthesis/run.** Add `__exec` to `intrinsicFloor()` (one re-fixpoint, since codegen lowering changes). Build `kitetest.kite` + `ktest.kite`. In-process unit tests run end-to-end.
3. **Reporting.** `lib/test/report.kite`: pretty + TAP; `--format`, timing footer, `--filter=<glob>` single-test selection. TAP into CI.
4. **Compiler-behavior libraries + snapshot update.** `lib/test/compile.kite` + `lib/test/golden.kite`; add `__fileBytesEqual`. Migrate `run-compiler-tests` / `run-parser-tests` / `run-check-tests` onto Kite; delete their `sed`/`grep`.
5. **Fixtures + lifecycle annotations.** `@beforeEach`/…/`@ignore`/`@shouldAbort` wired into the synthesized main.
6. **Fixpoint, robustness, jq-diff migrated; retire the shells.** `gate.sh` becomes a thin `kitetest` invocation; the five harness scripts are deleted.
7. *(extra)* **Benchmarks + coverage groundwork.** `@bench` + `__clockMs`; a cheap `--coverage` = which `@test`s ran. Real line/branch coverage (codegen instrumentation) stays a Phase-10-class deferral.

---

## 3. Error Framework — humane runtime errors, no more silent segfault

### 3.1 Current state — there is no runtime-error framework

There is exactly one runtime failure primitive: **`__abort()`** (`klower.kite`, `codegen.kite`), lowering to `bl _abort` → SIGABRT → exit 134 with **no message, no location, no backtrace**. Everything else either segfaults or silently corrupts:

- **Bounds/index (the `fib.kite` `array[11]` case):** `List.get`/`set` (`lib/alloc/collections/list.kite:41,44`) are `__rawLoad(self.data, i*8)` / `__rawStore(self.data, i*8, x)` with **no `0 <= i < n` check**. `xs[i]` desugars (klower `lowerIndex` → role `list.get`) straight to `List_get`. So `array[11]` on a shorter list computes `data + 88` and reads/writes adjacent heap: silent garbage on load, heap corruption on store, negative index → negative offset. Pure UB, exit 0. Same for String `s[i]` (byte-indexed `charAt`, no check).
- **Map miss:** `Map.get`/`getI` linear-scan and `return 0` on miss — the silent-zero the redesign repeatedly flags, indistinguishable from a real stored 0.
- **Null/nil deref:** null = the 0 pointer. `a?.f`→0, `a?:b`→fallback, `a!!`→`__abort()` (raw, message-less). A plain `.field` on a null object is unchecked → loads `[0 + off]` → SIGSEGV.
- **Div/mod by zero:** `/`→`IDiv (SDIV)`, `%`→`IDiv`+`IMulSub`. On AArch64 SDIV-by-0 **returns 0 and does not trap**, so `x/0` and `x%0` silently yield 0 — no error at all. `INT_MIN/-1` similarly wraps silently.
- **Integer overflow:** ADD/SUB/MUL wrap at 64 bits, undetected. (STDLIB-REDESIGN §6.6 locked the default = silent wrap-by-width + explicit `wrapping_`/`checked_`/`saturating_` families — so this is *by design*, not an error class.)
- **Unwrap of None/Err:** no `unwrap`/`expect`/`?` exist; `!!` is the only unwrap and only checks the 0-pointer, aborting bare.
- **OOM:** `__rawAlloc`→malloc, result **not checked**; a NULL flows into `__rawStore(NULL, …)` → SIGSEGV.
- **Stack overflow:** no guard; deep/infinite recursion (incl. the comptime `ceEval`) runs the guard page → SIGSEGV, no message.
- **File/IO:** `readFile` NULL-guards `fopen` and returns `""` silently — a missing file is invisible; `writeFile`/`fputByte`/`fcloseF` return ignored codes.
- **Compile-time (already humane):** `lowFail` emits a real `Diagnostic` to stderr via the Phase-0.5 sink and hard-aborts — **the model to copy.**

**What Phase 0.5 already gives us (the substrate):** `struct Span(off, line, col)` + `struct Diagnostic(severity, span, message, code)` + `diagError`/`diagErrorAt(line)` + `renderDiag` + the `emitDiag`→`eprintln`→`write(2, …)` floor. **Critical gap:** `FExpr` AST nodes carry **no line/span** (only `Tok` does) — so klower cannot today stamp a source `file:line` onto an injected panic; diagnostics are only decl-line granular. This is the same gap the LSP (§4) forces us to close, so it is landed once as shared infrastructure.

### 3.2 Design — recoverable values ride Result/`?`; bugs funnel through one located panic

Two halves, both already sketched in STDLIB-REDESIGN §4: **recoverable** errors ride `Option`/`Result` + a new `?` operator (values, no unwinding); **bugs** funnel through one located panic path that prints a Phase-0.5 `Diagnostic` and aborts non-zero. **Panic = abort, never unwind** — matches ARC (no landing pads, no per-frame release on an unwind path, self-host-safe), matches Rust's `panic=abort`, and matches the existing `__abort`.

**The panic funnel — one path, library-bodied over the floor** (`lib/std/panic.kite`):

```kite
fun __panicAt(loc: String, msg: String): Never {
  emitDiag(Diagnostic(0, spanNone(), concat(loc, concat(": panic: ", msg)), ""))
  __abort()
}
```

It **reuses the existing `Diagnostic`/sink verbatim** — panics and compiler diagnostics render identically (`"<file>:<line>: panic: <msg>"`). `loc` is a compile-time string literal the compiler injects at the call site (klower). `Never` (STDLIB-REDESIGN §2a's bottom type) makes `val x = xs[i] ?: panic("empty")` typecheck. **No new intrinsic is strictly required** — `__panicAt` is pure library over `eprintln` + `__abort` — but a thin reserved `__panicAt` name is worth keeping so codegen can inject calls (div-by-zero, bounds) without name-resolution-order concerns and so a future backtrace hook has one funnel.

### 3.3 The error taxonomy

Every runtime error class, how it is detected, and how it is reported. "Tier" flags whether the fix is target-tier only (compiler self-host path pays nothing via `getUnchecked`) or applies compiler-wide.

| # | Error class | Today | Detection | Report | Tier |
|---|---|---|---|---|---|
| 1 | **Index / bounds OOB** | UB (silent garbage / heap corruption) | `if (i < 0 \|\| i >= self.n)` guard before the raw op, inside `List/Vec/Array/Deque.get/set` (role-routed, so no new compiler coupling) | `"fib.kite:12: panic: index 11 out of bounds for length 3"`, exit 134 | target (compiler uses `getUnchecked`) |
| 2 | **Null / nil deref** | `!!`→bare abort; `.field` on null→SIGSEGV | upgrade `lowerNotNull` to `__panicAt(loc, "unwrap of null")`; raw `.field` stays SIGSEGV unless a debug-flag null-check mode is on | `"…: panic: unwrap of null"` | compiler-wide (`!!`) |
| 3 | **Div / mod by zero** | SDIV returns 0, no trap | **codegen-injected** guard `cmp divisor,#0; b.ne ok; <__panicAt>; ok:` before `IDiv` (cannot be caught in library) | `"…: panic: divide by zero"` | target/debug (gated OFF for self-host) |
| 4 | **`INT_MIN / -1`** | wraps silently | optional codegen guard, or define as wrapping | `"…: panic: divide overflow"` or documented wrap | target/debug |
| 5 | **Integer overflow** | wraps (by design) | **not a panic class** — `checkedAdd(b): Option` family over reserved `__addOverflow`/`__mulOverflow`; optional `-C overflow=panic` debug flag | `None` (recoverable) / debug panic | target |
| 6 | **Unwrap of None/Err** | only `!!` (0-ptr) | recoverable: `?` desugar + checker rule on enclosing return type; bug: `Option/Result.unwrap()/.expect(msg)` → `__panicAt(loc, "unwrap of None")` | `"…: panic: unwrap of None"` | library |
| 7 | **Allocation failure (OOM)** | NULL → SIGSEGV on store | `if (p == 0) __panicAt(loc, "out of memory")` in the `__rawAlloc`/`__rawRealloc` wrapper (one `cbz` per alloc) | `"…: panic: out of memory"` | library |
| 8 | **Stack overflow** | SIGSEGV, no message | (b) comptime recursion-depth cap in `ceEval` now; (a) a SIGSEGV handler in the runtime entry deferred to R5 | `"stack overflow (or null deref)"` | deferred |
| 9 | **Cast / conversion OOR** | `fcvtzs` saturates; no `as` yet | `TryFrom` narrowing → `Option`/`Result`; hard `as` truncates (defined, no panic); optional `toIntChecked: Option` | `None` (recoverable) | library |
| 10 | **Assertion failure** | undefined | klower desugar `assert(c)` → `if (!c) __panicAt(loc, "assertion failed")`; `assertEq(a,b)` prints both | `"…: panic: assertion failed"` | library + klower |
| 11 | **Compile-time unsupported** | `lowFail`→Diagnostic+abort | **already humane** — keep as the template | stderr Diagnostic, hard abort | (compile-time) |
| 12 | **File / IO error** | silent `""` on miss | `readFile: Result<String, IoError>` over the future `@extern` FFI; interim: `Result`-returning `readAll` wrapper in `lib/std/io.kite` | `Err(...)` (recoverable) | library |
| 13 | **`todo()` / `unreachable()`** | absent | desugar like panic → `__panicAt(loc, "not yet implemented")` / `"internal error: entered unreachable code"`, both `Never` | `"…: panic: …"` | library + klower |
| 14 | **`__dyn` fall-through** | `return 0` (silent-wrong) | flip trait-object no-impl to `__panicAt(loc, "no impl for type-id")` (also STDLIB-REDESIGN §2b) | `"…: panic: no impl for type-id"` | codegen |

### 3.4 Worked example — `fib.kite`'s `array[11]`

Today, indexing a length-3 list at 11 lowers through role `list.index-get` → `List_get(array, 11)` → `__rawLoad(array.data, 11*8)` = `__rawLoad(data + 88, 0)`, reading 8 bytes of whatever heap follows the 3-element buffer. The program keeps running on garbage and exits 0. With the framework (taxonomy row 1): `List.get` gains

```kite
fun get(self, i: Int): Int {
  if (i < 0 || i >= self.n) {
    __panicAt(loc, concat("index ", concat(intToStr(i),
      concat(" out of bounds for length ", intToStr(self.n)))))
  }
  return __rawLoad(self.data, i * 8)
}
```

and `array[11]` now prints `fib.kite:N: panic: index 11 out of bounds for length 3` to stderr and exits 134. The guard is *inside the role target*, so the compiler needs **no new coupling** — the bounds check rides the existing `list.get` role. The compiler's own hot loops stay on `IntBuf`/`getUnchecked` and pay nothing, so the fixpoint is untouched.

**OPEN — index-assign `i >= n` semantics.** For `xs[i] = v` past the end, two coherent choices exist and must be settled per container kind:

- A **sequence** (`List`/`Vec`/`Array`) index-set OOB is a **bug → panic** (never auto-grow; growth is `.push`). So `xs[3] = v` on a length-3 vec panics.
- A **map** index-set is insert-or-update **by definition → never panics** on a "missing" key. So `m[k] = v` inserts.

This is the recommended split, but it is flagged **OPEN** because it pre-commits the container API contract and interacts with whether `m[k]` *get* on a missing key returns `Option`, `getOr`, or panics (recommended: `Option`, never silent-0). `getUnchecked`/`setUnchecked` give the compiler hot paths a checked-free escape regardless of the decision.

### 3.5 Location injection — the load-bearing enabler

To print `file:line`, klower must know the source line at each injected call (bounds guard, `assert`, `!!`, div-guard). Since `FExpr` carries no span, either add a `line` field to the fault-capable `FExpr` variants (or a parallel side-table keyed by node identity), or — cheaper interim — stamp the **enclosing function's name + decl-line + file**. The compiler already knows the current file (the `compileFile` input path); thread it into `Lo`. This dovetails exactly with the LSP's structured-span need (§4) and STDLIB-REDESIGN §3h's typed/spanned-AST item — **do the span-threading once, as shared infrastructure.**

### 3.6 Decoupling + phases

Three layers, mirroring kitefmt: a **runtime-support library** (`lib/std/panic.kite` funnel + `Option`/`Result` `.unwrap`/`.expect` in `lib/core/option.kite` + bounds guards inside container methods) is ordinary Kite over the tiny floor; the **irreducible floor** grows by *zero* names in the base form (`__panicAt` is library over the existing `__abort` + `eprintln` + `Diagnostic`), reserving the optional `__panicAt` intrinsic only so codegen can inject the div/bounds guards without name-resolution fragility; the **compiler's only knowledge** is three single-truth points — the role table already routes container ops (bounds check lives in the role target), the klower desugar sites for `!!`/`?`/`assert`/`panic`/`todo`/`unreachable` inject the call-site `loc`, and codegen's div-guard + `__dyn` fall-through. All messages render through the Phase-0.5 sink. **Self-host safety:** the compiler stays on `IntBuf`/`RawMap` + `getUnchecked`, so the target-tier bounds checks do not slow or alter the self-host build; the div-by-zero codegen guard, being bytes-moving, must be gated OFF for self-host or its own divisions re-fixpointed deliberately.

A **panic-test harness** — a corpus of programs that *should* panic, asserting exit 134 + a golden stderr line — reuses the parser/checker golden-diff pattern (and later becomes the test framework's `@shouldAbort` category), making "does `array[11]` panic humanely?" a regression-gated contract.

Phases (each fully gated): **R0** panic funnel + location plumbing (bootstrap-safe, no codegen bytes; route `!!` and `__dyn` fall-through through `__panicAt`; add `panic`/`assert`/`todo`/`unreachable` to checker + prelude). **R1** recoverable errors: `?` operator + `unwrap`/`expect`; add `kite::core::option` to `prelude.conf`; target-tier `Map.get`→`Option`. **R2** bounds checks (target tier; the `fib.kite` fix; lands with/after collections, STDLIB-REDESIGN Phase 7). **R3** codegen-injected guards (div/mod-by-zero, OOM; bytes-moving, deliberate re-fixpoint or opt-flag OFF for self-host). **R4** overflow-checked family (ties to STDLIB-REDESIGN Phase 3). **R5 (deferred)** backtraces + stack-overflow handler + `Result`-returning I/O over `@extern` FFI.

---

## 4. Language Server + Editor Tooling

### 4.1 Current state — reusable front-end, but products are thrown away and spans are strings

**What exists:** the kitefmt decoupling template (`zfFormat(src): String` is a pure, idempotent library entry directly reusable for `textDocument/formatting`); the Diagnostic substrate (`Span`, `Diagnostic`, `renderDiag`/`emitDiag`, the `eprint`/`eprintln` floor, hard-aborting `lowFail`); and a de-facto reusable front-end API — `lex(src): List<Tok>` (`Tok(kind, text, line)`), `parseProgramLn(toks, lines): List<Decl>`, the `Decl`/`FExpr`/`FStmt`/`FPat` AST, `checkDiags(toks, skipDup)` (= `resolveCheck` + `typecheckCheck`), `preludeSigs()`, `infer(env, e): Ty`, `showTy(t): String`, and `TEnv` (a de-facto symbol table built during checking).

**Critical gaps for an LSP:**

- **Spans are not structured.** The `Span`/`Diagnostic` type exists but the checker does not use it: `rErr`/`tErr` push pre-formatted `"line N: msg"` strings via `linePrefix(curLine)`, at **decl-line granularity**, and `checkDiags` returns `List<String>`, not `List<Diagnostic>`. `Tok` carries only `line` — **no column, no byte offset.** No `FExpr`/`Decl` node carries any span. This is exactly the "spans baked into message strings" gap that Phase 0.5 opened but did not finish — and **a real LSP is the forcing function that makes us finish it**, because `publishDiagnostics` needs real ranges and hover needs offset→node lookup.
- **Checked products are thrown away and re-derived** (STDLIB-REDESIGN §3h): `checkDiags` re-parses; klower/codegen re-parse+re-infer independently. There is no retained typed AST / analysis object to query.
- **No stdin:** the floor has only `__argv`/`readFile`/`writeFile`/`eprint`/`eprintln`. LSP stdio transport is hard-blocked on this.
- **No JSON library:** the only JSON code is the ad-hoc `parseJson` in `examples/jq/jv_parse.kite`.
- Everything is whole-file; no incremental parse/check; no editor integration of any kind.

### 4.2 Design — `kite-lsp` over stdio JSON-RPC, on the kitefmt pattern

Tool `compiler/tools/kite-lsp.kite` (transport + JSON-RPC loop) + library `compiler/driver/klsp.kite` (server core) + a new `compiler/driver/kanalysis.kite` (the reusable analysis API), all importing `kfront.kite` + `kcheck.kite` + the Diagnostic substrate, kept OUT of `kitec`. JSON lives in `lib/std/json.kite`.

**Transport prerequisites (floor + lib).** LSP is JSON-RPC 2.0 with `Content-Length:`-framed bodies over stdin/stdout. Needs a blocking byte reader — new floor intrinsics `__stdinByte()`/`__stdinRead(buf, n)` (stopgap per STDLIB-REDESIGN §4, until `@extern` FFI) — and a raw `__stdoutWrite(buf, n)` (because `println` injects newlines and would corrupt the framing). `lib/std/json.kite`: `enum JsonValue { JNull; JBool; JInt; JStr; JArr; JObj }` + `jsonParse(s)` / `jsonStringify(v)`, bootstrappable by lifting `jv_parse.kite`; a minimal version works over `IntBuf`/`RawMap` today.

**The analysis API — the load-bearing new piece (`kanalysis.kite`).** `struct Analysis(src, toks, decls, lines, tenv, diags)` produced by one `analyze(src): Analysis` that runs lex → `parseProgramLn` → `resolveCheck` + `typecheckCheck` **once** and **retains every intermediate** (today discarded). This *is* the typed-AST/analysis channel STDLIB-REDESIGN §3h wants between checker/lowerer/codegen — building it here pays that debt down. Plus `offsetToLineCol(src, off)` / `lineColToOffset` and byte↔UTF-16 conversion (LSP positions are UTF-16 code units, unless we adopt UTF-8 — see §8).

**Features and their compiler needs:** `publishDiagnostics` (map each `Diagnostic`→LSP range — **requires the Phase-0.5 span actually populated**); `documentSymbols` (cheapest — walk `decls` + names + lines); `hover` (`infer` + `showTy` — needs offset→node, so `FExpr`/`Decl` must gain spans); `signatureHelp` (from `TEnv` `funP`/`funR`); `completion` (from `TEnv` `funN`/`structN`/`enumN` + locals + `preludeSigs()`; members via `structFN`/`structFT`); `go-to-definition`/`find-references`/`rename` (need a def-site `Span` index in the resolver + identifier-token→resolved-symbol matching; rename = a `WorkspaceEdit` guarded to a single resolved symbol); `formatting` (delegate straight to `zfFormat`).

**Incremental strategy:** v1 = whole-document re-analyze per `didChange`, debounced (~150 ms), with an open-doc store `Map<uri, DocState{version, text, Analysis}>`. Kite files are small; full re-check is acceptable first. Incremental relex of the edited range + Decl reuse is a later polish.

### 4.3 Decoupling + phases

`kite-lsp` reuses the shared front-end and stays out of `kitec` — so it cannot move the fixpoint and there is no parallel parser to drift. Four reinforcing wins: (1) `analyze()` **is** the typed-AST channel §3h recommends — the LSP is the forcing function that makes the compiler build it, benefiting the whole pipeline; (2) populating structured spans is the honest completion of Phase 0.5, serving compiler diagnostics and the LSP identically; (3) JSON + stdin/stdout belong in `lib/std` + the floor, consumed as an ordinary library client; (4) the LSP is the first real **external multi-file consumer** of the front-end, forcing a clean analysis boundary + cross-file import resolution (STDLIB-REDESIGN §3g) — directly readying modularization.

Phases: **L0** floor prerequisites (`__stdinByte`/`__stdinRead`/`__stdoutWrite` + `lib/std/json.kite`; byte-neutral to kitec). **L1** structured spans (`Tok` gains byte-off + col; parser threads a `Span` onto `FExpr`/`Decl`; checker emits `Diagnostic{span}`; `checkDiags` returns `List<Diagnostic>`; re-freeze parser/checker goldens for the new render shape) — **shared with the error framework's §3.5 location work.** **L2** analysis API (`kanalysis.kite`). **L3** LSP skeleton (framing, JSON-RPC dispatch, initialize/didOpen/didChange/didClose, `publishDiagnostics`). **L4** read-only intelligence (`documentSymbols`, hover, formatting, signatureHelp). **L5** resolution index (def-site spans → goto/references/rename/completion; needs cross-file import resolution). **L6** incremental + polish (debounced then incremental relex; semantic tokens; VS Code / Neovim client shims + a TextMate/tree-sitter grammar). Editor clients are thin config shims outside the repo; only the server is Kite. `editors/` already exists as its home.

---

## 5. Other Decoupled Frameworks

All follow the same template — a standalone binary reusing `kfront`/`kcheck`/`Diagnostic`, kept out of `kitec`, logic in `lib/`, distributed later as a toolchain package (§6).

- **Documentation generator (`kite-doc`).** Extract doc-comments + signatures from the kfront AST into Markdown/HTML, and crucially **doctests** (runnable example blocks compiled + run by `kitetest` — the test framework should be built to accept doctests as a discovery source). Note: kfront's `skipTrivia` **discards comments**, while kfmt already captures `//` and `/*` as first-class pieces (`zfLexLine`/`zfLexBlock`) — factor that comment-capture layer out of kfmt for reuse.
- **Linter (`kite-lint`).** AST-walking style/correctness lints (unused bindings, dead code, shadowing, non-exhaustive `when`, the `&&`-vs-`&` class of bugs the redesign fixes) over `Diagnostic`/`Span`; complements kitefmt (mechanical) with semantic rules.
- **REPL.** Hard on an AOT arm64 backend. The pragmatic path is a tree-walking interpreter over `FExpr` — klower's comptime `ceEval`/`ceExec` already tree-walks an Int subset and could grow into a REPL evaluator; a full REPL needs incremental compilation or JIT (out of near-term scope).
- **Debugger / disassembler bridge.** The arm64 backend already writes Mach-O binaries; a `kite-dis` (IR/asm dump) plus source-line debug-info emission would make failing tests introspectable. Needs DWARF line tables from the Mach-O writer + source-line mapping in codegen — the L1/§3.5 span work is the prerequisite; the debugger itself is a large, deferred effort (alongside the 2nd-backend / Phase-10 work).
- **Coverage / profiler pair.** Both share one codegen instrumentation pass (per-line counters + a profile-dump floor) — large, fixpoint-touching, Phase-10-class. The cheap interim (`--coverage` = which `@test` fns executed) is free in the test framework's phase 7.
- **Fuzzing / property-testing.** A `@property fun (n: Int)` form generating inputs, folding into the test framework as a third test kind beside `@test`/`@bench` — would have caught several of the parser-segfault bugs the project fixed by hand.
- **Unified diagnostics renderer upgrade.** Phase 0.5's `Diagnostic` already has byte-offset spans but `renderDiag` prints one line. A rustc-style caret renderer (source snippet + `^^^` underline + note/help) is a **pure library upgrade** to `renderDiag` reusing the same `Span` — shared by compiler errors, panics, the linter, and the LSP.

**Cross-cutting thread:** every one reuses the front-end (lexer/parser, checker, the Diagnostic sink, the annotation machinery) and ships as a separate binary — the discipline that keeps `kitec`'s fixpoint frozen while the platform grows around it. Two shared infrastructure items recur and should be landed once, not per-framework: **spans on the AST** (serves diagnostics, panics, LSP, linter, debugger) and **comment capture** (serves kitefmt, kite-doc, and any format-preserving rewrite).

---

## 6. Modularization + Dependency / Package Management — the endgame

### 6.1 Current state — a two-kind import system, an embryonic manifest, no package layer

- **The auto-injected prelude** is the manifest system in miniature: `compiler/prelude.conf` is pure data (five `kite::` module lines), read by `preludeConfPaths()` and consumed by **two** phase-agnostic readers — the lowerer's `injectHelpers` and the checker's `preludeSigs()`. One data file, two readers.
- **Quoted includes** (`import "path.kite"`) are flat textual inlining: `resolveImports`/`impProcLine` read + recurse + splice, with a shared `seen` list for transitive dedup. This is how `compiler/kitec.kite` (a five-line quoted-import manifest) assembles the compiler itself.
- **Namespace imports** (`import kite::a::b`) are the real module system: `impExtractPath` turns `::`→`/` and rewrites the `kite/` root to `lib/`; `collectModules` gathers the transitive set deps-before-dependents; `buildRen`/`mangleMod` rename each module's free functions to `mod__name`; `pub import` re-exports.

**Limits:** no versioning, no external deps/registry/lockfile/cache; cwd/path fragility (the `kite/`→`lib/` string rewrite is the sole hardcoded "package"); no package boundary or real manifest; **namespacing is incomplete** — only free functions are mangled, so types/enums/traits/impls/consts stay **global** and two packages defining `struct Node` collide; no separate compilation (flat textual re-inline re-parses every module every build).

### 6.2 Design — one new compiler seam; everything else in `kpkg`

The endgame is a package platform where the compiler gains **exactly one new coupling seam** — a resolved module→path map — and manifest parsing, dependency resolution, fetching, and the build graph all live in a standalone **`kpkg`** tool reusing `kfront.kite`, kept out of `kitec`.

- **Manifest — `kite.pkg`.** One file per package root, reusing the `prelude.conf` precedent (a simple line/section format a tiny hand-parser reads; no TOML parser exists in-tree). Sections: `[package]` (name, semver, min-compiler/edition, license), `[deps]` (`name = "^1.2" source = git:… | registry:… | path:… | vendor:…`), `[lib]` (the public root module(s) = export surface), `[[bin]]` (entry points, replacing the implicit `_main`), `[prelude]` (the auto-injected list — today's `prelude.conf`, so each package declares its *own* prelude; `std` carries the language default).
- **Real module system** — lift the two current limitations: **namespace types/enums/traits/impls/consts** (extend `mangleMod`/`renFunc`/`collectModuleDecls` to rename type/trait/const names per module, threading through `FTDecl`/`FTraitDecl`/`FConstDecl` and their reference sites — the single biggest front-end change, killing cross-package type collisions); **per-item visibility** (`pub fun`/`pub struct`/… default module-private; `exportSurface` includes only `pub`; package boundary = only a dep's `[lib]` public surface is importable); **versioned imports** (surface syntax stays version-free, Cargo-style; versions live in `kite.pkg`/`kite.lock`).
- **Resolution + fetching + lockfile — all in `kpkg`.** Generalize the existing `collectModImports` transitive-`seen` walk from path-dedup to **version-aware node identity `(name, version, hash)`**, run semver selection, fetch into a content-addressed cache (`$KITE_HOME/cache/<name>-<version>-<hash>/`), write **`kite.lock`** (exact versions + content hashes + the flattened module→path map the compiler consumes). The compiler never fetches; it only reads the lock's resolved map.
- **Stdlib as versioned packages.** `lib/core`/`lib/alloc`/`lib/std` each get a `kite.pkg` (`alloc` deps `core`, `std` deps `alloc`); `prelude.conf`'s lines move into `std`'s `[prelude]`; the existing `pub import` aggregators (`core.kite` etc.) become the `[lib]` surfaces — no structural rewrite. They ship with the toolchain, pinned by an implicit `std = "=<compiler-version>"` edition dep.
- **Frameworks ship as tool packages.** `kitefmt` (exists), `kitetest` (§2), `kite-lsp` (§4), `kite-doc`/`kite-lint` (§5), and `kpkg` itself — each a standalone binary reusing `kfront`, distributed as a toolchain package, never linked into `kitec`.
- **Build integration.** `kpkg build`/`test`/`gate` read `kite.pkg` + `kite.lock`, walk the DAG, and invoke the compiler per compile unit over the **compile-unit→object→link boundary** (STDLIB-REDESIGN §3h). `gate.sh`/`run-*.sh` become `kpkg gate` + `kpkg test`. Object caching keyed by content hash makes dependency builds tractable.
- **The one new seam.** Replace the hardwired `kite/`→`lib/` rewrite in `impExtractPath` with a lookup into the resolved module→path map `kpkg` produces from `kite.lock` (via `KITE_HOME`/an env-pointed lock, or `--module-map`). This mirrors `prelude.conf` as the compiler's single stdlib-knowledge point — one data-driven seam, everything else in the tool.

### 6.3 Why the decoupling foundation leads straight here

The package layer is the **same "roles/data, not names/hardcoding" move applied one level up**, and the groundwork already holds:

- `prelude.conf` + its two phase-agnostic readers is the manifest system in miniature; `kite.pkg` is the direct generalization (same reader shape, more fields).
- `isIntrinsic`/`roleSym`/`@lang`/`@arc` mean the stdlib is **already "just a package" semantically** — because the compiler couples to *roles* sourced from `@lang` annotations, which package provides a role is already a data decision. Swapping `std` v1 for v2 that relocates `list.new` is a manifest/annotation change with zero compiler edit — exactly the property versioned stdlib packages require.
- `kitefmt`-as-standalone-tool is the exact template for every framework here, `kpkg` included.
- `collectModules`/`collectModImports`'s transitive `seen`-dedup is the dependency-resolver skeleton (DAG walk, deps-before-dependents order, dedup already exist; the generalization is node identity + semver, a tool change).
- Phase-0.5's `Diagnostic`/`Span` + single stderr sink is the shared substrate every tool and the resolver report through.

**The true blocker is separate compilation, not the manifest.** Flat textual re-inline is O(total transitive source) per build; a dependency graph of versioned packages makes that untenable. The compile-unit→object→link boundary is the load-bearing prerequisite — sequence it before the resolver. Cross-package type checking also wants the checker's inferred `Ty` preserved across the object boundary (public-surface signatures in the "object"), which is why the typed-AST channel (§4's `analyze()`, §3h) intersects here.

Phases (all gated; kitec byte-frozen except where noted): **MP0** manifest reader + resolver seam (byte-neutral: compiler behavior unchanged when no map is supplied). **MP1** host/path robustness (install-relative root discovery, importing-file-relative quoted includes, drop hardcoded Homebrew PATH — STDLIB-REDESIGN §3e/§3g). **MP2** full namespacing + per-item visibility (biggest front-end change). **MP3** separate-compilation boundary (STDLIB-REDESIGN §3h; the real prerequisite for scaling). **MP4** `kpkg` resolver + lockfile (tool only). **MP5** build integration; retire shell harnesses (converges with §2's `kitetest`). **MP6** stdlib + frameworks as published versioned packages. **MP7 (deferred)** registry + `kpkg publish`/`add`.

---

## 7. Decoupling Architecture + Phased Sequence

### 7.1 The three-layer discipline every framework obeys

- **Compiler core (`kitec`) — frozen.** Front-end + sema + codegen + backend + its own module-inlining. Never gains a tool subcommand. Its knowledge of the world outside the machine floor is the three single-truth points STDLIB-REDESIGN established (`isIntrinsic`/`roleSym`/`isArcExempt`) plus the one new module→path resolver seam (§6). Every framework here adds **zero** to `kitec`.
- **The shared front-end, consumed as a library — the "analysis" boundary.** `kfront.kite` (the single lexer/parser), `kcheck.kite` (resolver/checker + `TEnv`), the `Diagnostic`/`Span` substrate, and the new `kanalysis.kite`'s `analyze(src): Analysis` (retaining toks/decls/tenv/diags, offset↔node lookup). This is the layer the LSP forces into existence and that the linter, doc tool, and cross-package type-checker all reuse — one parse, one check, many consumers, no re-inference (retiring the three-times-inferred String-vs-Int print bug of §3h). Every tool quoted-imports it; none reimplements it.
- **Tooling + stdlib.** Standalone tool binaries (`compiler/tools/*.kite` + `compiler/driver/*.kite`) over the analysis boundary, and pure Kite libraries (`lib/test/`, `lib/std/panic.kite`, `lib/std/json.kite`, `lib/std/io.kite`) any compiled program links. The floor grows only by the honest minimum: `__exec` + `__fileBytesEqual` (+ optional `__clockMs`) for testing; `__stdinByte`/`__stdinRead`/`__stdoutWrite` for the LSP — all labelled "process/host shim", all stopgaps until `@extern` FFI.

### 7.2 Shared infrastructure — land once, not per-framework

Two items recur across sections and must be built as shared infrastructure:

- **Structured spans on the AST** (LSP L1 / error-framework §3.5 / §3h). `Tok` gains byte-off + col; parser threads a `Span` onto `FExpr`/`Decl`; checker emits `Diagnostic{span}` not `linePrefix` strings; `checkDiags` returns `List<Diagnostic>`. This single deliverable serves compiler diagnostics, panic `file:line`, LSP ranges/hover, the linter, and debug-info — do it once.
- **Comment capture** (kite-doc / kite-lint / any format-preserving rewrite). Factor kfmt's `zfLexLine`/`zfLexBlock` comment-capture layer out of kfmt for reuse, since kfront's `skipTrivia` discards comments.

### 7.3 Cross-framework dependency order (honest)

```
Phase 0.5 substrate (done) ──► structured spans (shared) ──► LSP ranges/hover, panic file:line
error framework __panicAt ──► test framework @shouldAbort / assertThrows
__exec floor ──► test framework compiler-behavior kinds ──► retire gate.sh
stdin/stdout floor + JSON lib ──► LSP transport
analyze() boundary ──► LSP intelligence + cross-package type-check
compile-unit→object→link (§3h) ──► package manager scalability
```

### 7.4 Execution sequence (runs AFTER STDLIB-REDESIGN phases 0–10)

Each phase carries the full gate: test suite + parser/checker differentials + `kcc2==kcc3` (and the integrated compiler's fixpoint) + the new panic-corpus golden harness once it exists. The **never break `kcc2==kcc3`** discipline is absolute; frameworks are additive by construction (tools are separate binaries, libraries are linked only by programs that opt in), so the fixpoint holds trivially and is gated anyway.

| # | Phase | Depends on | New floor | Fixpoint impact |
|---|---|---|---|---|
| **F1** | Error framework R0–R1 (panic funnel, `?`, unwrap/expect) + shared span-threading | STDLIB Phase 0.5 | none (reserve `__panicAt`) | byte-neutral (span render re-freezes goldens) |
| **F2** | Test framework 1–3 (assert lib, `__exec`, kitetest, reporting) | F1 (for `@shouldAbort`) | `__exec`, `__fileBytesEqual` | one deliberate re-fixpoint (codegen lowering of `__exec`) |
| **F3** | Test framework 4–6 (compiler-behavior kinds, fixtures, migrate + retire shells) | F2 | — | byte-neutral |
| **F4** | Error framework R2–R4 (bounds checks, codegen guards, overflow family) | STDLIB Phase 7 (collections), Phase 3 (unsigned) | reserved overflow intrinsics | target-tier only; div-guard gated OFF for self-host |
| **F5** | LSP L0–L2 (stdin/stdout + JSON floor, structured spans finished, `analyze()` boundary) | F1 spans | `__stdinByte`/`__stdinRead`/`__stdoutWrite` | byte-neutral (new intrinsics unused by compiler) |
| **F6** | LSP L3–L5 (skeleton, read-only intelligence, resolution index) | F5, MP1 cross-file resolution | — | out of kitec entirely |
| **F7** | Modularization MP0–MP3 (manifest reader, resolver seam, namespacing, separate compilation) | STDLIB §3h | — | MP0 byte-neutral; MP3 is the pipeline refactor |
| **F8** | Packages MP4–MP6 (`kpkg` resolver, lockfile, build integration, versioned stdlib + tool packages) | F7, F3 (`kpkg test` = kitetest) | — | tool-only |
| **F9** | Other frameworks (kite-doc + doctests, kite-lint, caret renderer) + deferred (REPL, debugger/DWARF, coverage/profiler, fuzzing, registry MP7, R5 backtraces) | comment-capture shared infra; L1 spans | profile-dump floor (coverage) | out of kitec; coverage instrumentation is Phase-10-class |

---

## 8. Open Decisions

- **Index-assign `i >= n` semantics** (§3.4) — sequence index-set OOB panics vs auto-grows; map index-set inserts. Recommended split as stated, but flagged OPEN because it pre-commits the container API and interacts with whether `m[k]`-get on a miss returns `Option`/`getOr`/panics. Settle with the collections tier.
- **In-process panic catching** — a rich `assertThrows` needs `setjmp`/`longjmp` or a `Result`-unwinding discipline the runtime lacks. Recommend the `Result`-based `assertErr` in-process + subprocess `@shouldAbort` split; revisit only if a real unwinding mechanism ever lands.
- **LSP position encoding** — advertise LSP 3.17 `positionEncoding: "utf-8"` (Kite strings are UTF-8 bytes) to skip UTF-16 conversion entirely, or support default UTF-16 for older clients? Big simplification if UTF-8 is accepted.
- **stdin/stdout floor timing** — add the stopgap `__stdinByte`/`__stdoutWrite` intrinsics now (the LSP is hard-blocked either way), or wait for the `@extern` FFI? Likely land the stopgap early, labelled as such.
- **Span granularity for a v1 LSP** — ship decl-line-granularity diagnostics immediately (skip L1) as a poor-UX stopgap, or hold `publishDiagnostics` until real spans exist? Recommend doing L1 first since it is shared with the error framework anyway.
- **JSON library timing** — lift jq's parser into `lib/std/json.kite` now (works over `IntBuf`/`RawMap`), or wait for String T1 / target collections for a clean version?
- **Coverage / benchmark instrumentation** — real line/branch coverage and `@bench` profiling share one codegen instrumentation pass (per-line counters + profile-dump floor) — large, fixpoint-touching, Phase-10-class; defer. The cheap interims (test-inventory `--coverage`, `@bench` over `__clockMs`) ship without it. Note the `@bench` dead-code-elimination subtlety: a `blackBox()` sink may be needed to stop the peephole optimizer folding away the benchmarked expression.
- **Snapshot-testing depth** — file-level goldens with `--update` cover every current use; inline snapshots (rewriting the assertion literal in source) need byte-span source editing — defer.
- **Parallel test execution** — `__exec`-per-test could fork concurrently, but interleaved reporting + nondeterministic ordering complicate TAP/JUnit. Serial first, `--jobs=N` opt-in later.
- **Package distribution channel** — path + git-source + vendored deps first (no infra) vs a central registry (real infrastructure). Which is the intended "real" channel? Registry deferred to MP7.
- **Semver vs edition-pinning** — full semver (ranges, diamonds, yank) vs a lockfile + exact-version + compiler-edition pinning (Go-modules-lite / minimum-version-selection, far simpler in-tree). MVS vs SAT resolution?
- **Manifest format** — extend the `prelude.conf` line/section style with a tiny hand-parser (self-contained, awkward for nested deps) vs a Kite-syntax manifest parsed by `kfront` (dogfoods the lexer, couples manifest to grammar) vs vendoring a TOML/JSON parser. Recommend (a)→(b).
- **Where test files live + discovery scope** — a `tests/` convention vs `*_test.kite` glob vs both? This pre-decides the eventual `kite test` package-tool hook; settle it when package management is designed.
- **`kpkg` bootstrap chicken-and-egg** — `kpkg` needs the compiler; the compiler's stdlib is packaged by `kpkg`. The seed must bundle a pinned stdlib so a fresh checkout builds before `kpkg` runs; how does the reseed protocol (STDLIB-REDESIGN §3e) interact with stdlib versioning?

---

*Companion to `docs/STDLIB-REDESIGN.md`. Execution sequenced after that document's phases 0–10. The single invariant across all of it, unchanged: the compiler's own source stays 100% `Int` on `IntBuf`/`RawMap`, every tool is a separate binary reusing the shared front-end, and `kcc2 == kcc3` stays byte-identical at every step.*
