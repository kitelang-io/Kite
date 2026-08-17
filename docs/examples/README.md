# Spec examples (CI harness intent)

Every code block in the design docs (`../LANGUAGE-DESIGN.md`,
`../LANGUAGE-DESIGN-DETAIL.md`) should *eventually* be extracted and
CI-tested against the real compiler:

- **`valid/`** — must **compile clean** (`kitec check` reports `ok`).
- **`invalid/`** — must be **rejected with the named error** (the file's header
  comment states the exact diagnostic we expect).

This is precisely the harness that would have caught the two bugs fixed in
step 1 of the docs pass: the erroneous `try` in the `Display` example (a type
error — `= expr` body evaluates to `Unit`, not `Result`) and the `mut`
*parameter* usages (an illegal param mode). A spec whose examples are never
run drifts from the compiler that implements it.

## Reality: only a small bootstrap subset is checkable today

The stage-0 compiler `kitec` is built and driven as:

```sh
dune build
dune exec bin/main.exe -- check <file.kite>     # parse + name resolution + type check (M2)
```

Today `check` implements only the **earliest bootstrap subset**. Most spec
examples exercise **M5+** features it cannot parse or type yet, so **full
spec-example CI is gated on M5 feature completeness.** Do **not** try to make
M5 examples compile — seed only what the current front end accepts, and grow
the corpus as features land.

### Checkable today (used by the seeded `valid/` files)

- `fun` with block **and** single-expression (`= expr`) bodies; `val` / `var`
- `if` / `else`, `while`, `return`, assignment, integer/boolean arithmetic
- `struct` (paren primary constructor, `val`/`var`/`pub` fields)
- `enum` (unit, positional-payload, and named-field variants)
- `when` — subject-less (`when { cond -> ... }`) and subject form
  (`when (e) { Lit(n) -> ...; Bin(op, l, r) -> ... }`) with enum-payload
  destructuring and `Op::Add` variant qualification
- `T?` nullable types and `null`; comparisons; string literals
- calls to seeded builtins (`println`, `print`, `intToStr`, `strLen`,
  `charAt`, `substr`, `concat`, `Some`/`None`/`Ok`/`Err`, …)

### Deferred (NOT checkable yet — do not add to `valid/`)

- traits / `impl … for` / associated `type` / generics / `where` bounds
- `try` / `try!` / `Result` propagation; `Formatter`; string interpolation `${…}`
- char-range membership patterns (`in '0'..'9'`) — currently a parse error
- `deinit` bodies referencing FFI intrinsics (e.g. `sysClose`) — unresolved names
- closures / lambdas as HOF arguments, iterators/adapters, `for … in`
- extensions, `comptime`, `suspend`/`scope`/`spawn`/`flow`, the ARC optimizer

The two files in `invalid/` are themselves M5-level snippets: they are checked
in by design as **documentation of the expected error**, to be wired into CI
once M5 semantics exist. Their headers name the diagnostic the compiler must
eventually emit.

Note the *current* front end rejects both earlier than that, with a **parse
error** (`expected a type`) on the `mut`-as-parameter usage — which is itself
partial evidence for bug 1b: today's parser already refuses `mut I` /
`mut Formatter` in parameter position. The intended *semantic* diagnostics
(the `Unit`-vs-`Result` type error for 1a; "`mut` is not a param mode" for 1b)
land with M5.

## Current seed status

| File | Kind | `check` result |
|---|---|---|
| `valid/geometry.kite` | struct, fun (expr+block body), arithmetic | ok |
| `valid/factorial.kite` | var, while, if, assignment | ok |
| `valid/classify.kite` | `Int?`, subject-less `when`, null | ok |
| `valid/enum_eval.kite` | enum, `when (subject)`, variant qual, recursion | ok |
| `invalid/display-try-type-error.kite` | bug 1a — erroneous `try` | expected: `Unit` vs `Result` type error (M5) |
| `invalid/mut-param-mode.kite` | bug 1b — `mut` param mode | expected: `mut` not a param mode (M5) |
