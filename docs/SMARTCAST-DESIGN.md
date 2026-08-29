# Kite `is` Expressions & Smart-Cast — Design & Staged Plan

Kite has type patterns (`when (x) { is Foo -> … }`) in its grammar but **no** expression-level
`x is T`, and **no** flow-narrowing anywhere. This document designs three linked features:

1. **`is` as a first-class boolean expression** — `e is T` / `e !is T`.
2. **A dedicated smart-cast subsystem** — a reusable flow-narrowing department, not a `when`-only hack.
3. **Unifying `when`** on top of (1)+(2) — one lowering path, guards and `|`-alternation fixed for free.

**Status (2026-08-21): DESIGN ONLY.** No compiler/lib code changed. This doc specifies the exact
lexer/parser/AST/checker/codegen deltas, the subsystem's module boundary + API, the self-host risk, and a
gate-able phased rollout. Design decisions left open are collected at the end.

---

## 0. Current state (verified against the code)

All line numbers are from this worktree.

### 0.1 `is` today — a pattern that never lowers

- **Lexer**: `"is"` → token **59** (`kfront.kite:259`). `!` is token **44**; `in` is token **53**.
  `!is`/`!in` are lexed as two tokens (`44` then `59`/`53`) and recombined by the parser.
- **AST**: `FPat` (`kfront.kite:435`) has `FPIsP(String, Int)` (`:439`) — a *pattern*: the type string
  plus a negation flag. `FExpr` (`kfront.kite:418`) has **32 variants; none is `FEIs`** — `x is Int` in
  expression position is a parse error.
- **Parser**: `parsePattern` (`:705`) produces `FPIsP(parseTy(p), 0)` for `is T` (`:720`) and
  `FPIsP(parseTy(p), 1)` for `!is T` (`:722`). Only reachable inside a `when`-subject arm.
- **Lowering**: `klower` has a namespacing pass `renTy` for `FPIsP` (`:6047–6052`) — **but `lowerPat`
  (`:2896`) has no `FPIsP` case**, so it hits `else -> { lowFail("pattern"); PWild }` (`:2906`).
  Since Phase 0.5, `lowFail` **hard-aborts** (exit 134, no binary). **`is` therefore never compiles today.**
  `compiler/tests/parser/07-patterns.kite:28` and `99-stress.kite:40` use `is Int` and are parser-only
  fixtures — they are never lowered.

### 0.2 `when` today

`FEWhen(Int hasSubj, String bindStr, FExpr subj, IntBuf arms)` (`kfront.kite:426`), arms are
`FArm(Int kind, FExpr lhs, IntBuf pats, FExpr guard, FExpr body)` (`:448`):

- **Subject form** `when (subj) { pat -> … }` (`parseWhen` `:776`, arm `kind == 2`). Value patterns:
  int/char/bool/null literals, enum variant `V` (`FPPath`), variant + payload bind `Some(x)` (`FPCtor`),
  record/named `Some(x = p)` (`FPRecord`), bare-ident catch-all (`FPBind`), `_` (`FPWild`).
- **Subjectless form** `when { cond -> … }` (arm `kind == 0`) — parses, but `lowerArm` (`:2954`) does
  `lowFail("subjectless when arm")`. **Dead today.**
- **Semantics**: first-match top-to-bottom; it is an expression; no-match + no-`else` yields `0`
  (`genWhenE` `codegen.kite:566`); **no exhaustiveness check**.
- **Two silent footguns**:
  - **Guards dropped.** The parser captures `if guard` into `FArm.guard` (`:809`) and the *checker*
    resolves/type-checks it (`rWhen` `kcheck.kite:331`, `inferWhen` `:2025`) — but the **lowered `Arm`
    IR has no guard field** (`Arm(isElse, pat, body)`, `codegen.kite:71`) and `lowerArm` (`:2957`) simply
    ignores it. A guard silently has no runtime effect.
  - **`|`-alternation drops all but the first.** `lowerArm` (`:2955`) takes `a.pats.get(0)` only. `A | B ->`
    matches only `A` at runtime (again, the checker sees all alternatives; codegen sees one).

### 0.3 Runtime object model (what `is` can actually test)

`genAllocHdr` (`codegen.kite:914`) gives every heap object a 16-byte header: refcount at `[obj-16]`,
**runtime TYPE-ID at `[obj-8]`**. `genTypeId` (`:927`) reads `[obj-8]`. The type-id is:

- **structs and classes** → `structIdx(name)` (`genStructNew` `:434`; classes register in the same
  `structN` table). So each struct/class has a **distinct** type-id.
- **enum values** → **`-1`** (`genVariantNew` `:475`). Every enum of every type shares type-id `-1`; the
  discriminator is the **tag word at `[obj+0]`** (`variantTag`, `:464`, `:476`).
- closures, boxed doubles, raw buffers → `-1`.
- **primitives (Int/Double/Char/Bool)** → unboxed raw words, **no header at all**. `__typeId` on a
  primitive reads `[word-8]` = garbage.

Dynamic trait dispatch already exploits the type-id: `buildDispatcher` (`klower.kite:3391`) generates
`__dyn_<Trait>_<m>(obj, …) { val __t = __typeId(obj); if (__t == id(Ty0)) return Ty0_m(…); … }`. **This is
the exact template an `is <Trait>` membership predicate will reuse.**

**Consequence for `is T` — the target kind decides the test:**

| `T` is a…      | runtime test                                              |
|----------------|----------------------------------------------------------|
| struct / class | `__typeId(x) == structIdx(T)`                            |
| trait          | generated `__is_<Trait>(x)`: `__typeId(x) ∈ impls(Trait)`|
| enum **variant** (`Some`) | tag compare `__loadOff(x,0) == variantTag(Some)` (the `PVarP` test) |
| whole enum type (`Option`) | **not runtime-distinguishable** — all enums are `-1` |
| primitive (`Int`) | **static / compile-time only** — no runtime tag         |

This table corrects the task's "compare the header type-id for … enum-variant types": enum variants are
matched by the **tag at `[obj+0]`**, not the header type-id. That is also exactly what makes the `when`
unification (§3) free — `is Some` and the `Some(..)` pattern share one codegen path.

### 0.4 The narrowing sites already have scoped binding tables

Every pass that needs narrowing already owns a scoped name→type table. Smart-cast plugs into these; it
does **not** invent a parallel environment.

- **Checker (type-inference pass)** — `TEnv.locals` (`kcheck.kite:1216`) is a stack of scopes of
  `Binding(name, Ty)`. `tPush`/`tPop` (`:1248`/`:1258`), `tBind` (`:1260`), `tLocal` (`:1266`, searches
  **innermost-first**). Narrowing = `tBind(name, narrowedTy)` in a `tPush`'d branch scope; `tLocal`
  naturally shadows the outer, wider type. `inferWhen` (`:2014`) and `inferIf` (`:1985`) are the hook sites.
- **Checker (resolution pass)** — `RCtx.scopes` (`:115`), names only. Guards/alternatives are already
  resolved here (`rWhen` `:321`). No type info; smart-cast needs nothing new here.
- **Lowerer** — `Lo.locN`/`Lo.locT` (`klower.kite:28`), `bindLoc(lo, name, tag)` (`:57`), `localTag`
  (`:94`). Narrowing = `bindLoc(name, narrowedTag)` in a saved/restored region.
- **Codegen** — `Ctx.ltyN`/`Ctx.ltyV`, `setLty(ctx, name, ty)` (`codegen.kite:361`). `genField`/method
  dispatch resolve field offsets via `typeNameOf` off this table. `genCtorPat` (`:523`/`:533`) already
  writes a payload var's static type here — this is smart-cast for `V(x)` in miniature.

**No pass tracks `val` vs `var` past the parser.** `FSLet(isVar, …)` carries it (`kfront.kite:457`) but
`bindLoc`, `Binding`, and `setLty` all drop it. The soundness rule (§2.3) needs it back — a small additive
delta.

---

## 1. `is` as a first-class boolean expression

### 1.1 AST delta

Add one `FExpr` variant (`kfront.kite:418`), appended **before `FENoRes`** to minimise tag churn:

```
FEIs(FExpr, String, Int)   // FEIs(subject, typeString, neg)   neg: 0 = `is`, 1 = `!is`
```

`typeString` is the raw `parseTy` string (`"Circle"`, `"Shape"`, `"Some"`, `"Int"`, `"Vec<Int>"`), matching
how `FPIsP`, `FECast`, and every type annotation are stored. Reusing a string (not a parsed `Ty`) keeps
`FEIs` uniform with the rest of the AST and lets the existing `renTy` namespacing pass touch it.

The printer (`kprint.kite` / `kfront.kite:1711` printExpr) gains an `FEIs` case (`neg ? "!is" : "is"`),
mirroring `FPIsP`'s printer at `:1765`.

### 1.2 Lexer delta

**None.** Tokens 59/44/53 already exist.

### 1.3 Parser delta — one new precedence rung

`is`/`!is` are relational-flavoured tests that must bind **tighter than `&&`/`||`** (so `x is T && x.f`
parses as `(x is T) && x.f`) and produce a `Bool`. Kite's ladder is C-like (`?:` loosest), so the natural
slot is next to the relational operators. Add a rung `parseIsCheck` **between `parseEq` (`:1096`) and
`parseRel` (`:1090`)** — i.e. `is` binds looser than `< > <= >=` and tighter than `== !=`:

```
fun parseIsCheck(p: P): FExpr {
  var e = parseRel(p)
  while (pk(p) == 59 || (pk(p) == 44 && pk1(p) == 59)) {   // `is`  or  `!is`
    var neg = 0
    if (pk(p) == 44) { eat(p); neg = 1 }
    eat(p)                                                 // 'is'
    e = FEIs(e, parseTy(p), neg)
  }
  return e
}
```

and change `parseEq` to call `parseIsCheck` instead of `parseRel`. `parseIsCheck` uses `pk1` (`:558`) to
distinguish `!is` (token 44 then 59) from unary `!`. The loop is written left-associative but chaining
(`x is A is B`) is nonsense; the checker rejects it because the LHS of the second `is` is `Bool` (§1.4).

Precedence is an **open decision** (§7-Q1). The recommendation above matches "near equality/comparison" and
satisfies every motivating example. `in`/`!in` as an expression operator (needed by the `when` `in r` arm,
§3) can be added at the same rung symmetrically, or kept pattern-only and desugared in `when` — see §3.4.

### 1.4 Checker delta

`infer` (`kcheck.kite:2043`) gains `FEIs(a, ty, neg) -> inferIs(env, a, ty, neg)`; `rExpr`
(`:196`) gains `FEIs(a, ty, neg) -> rExpr(ctx, a)` (the type name is resolved by the type machinery, not
the name resolver — same as `FECast`).

```
fun inferIs(env, a, tyStr, neg): Ty {
  val src = infer(env, a)                 // also type-checks the subject
  val tgt = parseTyStr(env.prim, tyStr)
  reservedTyErr(env, tgt)
  // primitive target: unboxed, no runtime tag → must be statically decidable (§1.5)
  if (isPrimitiveTarget(env, tgt)) { checkStaticIs(env, src, tgt) }  // else diagnostic
  // structurally impossible tests can warn (src is a final struct ≠ tgt) — optional
  return TPrim("Bool")
}
```

`inferIs` always yields `Bool`; its value to the *subsystem* is the fact it publishes (§2). The checker
does not itself narrow here — narrowing happens at the branch owner (`inferIf`/`inferWhen`/`&&`), which
asks the subsystem what facts the condition establishes.

### 1.5 Codegen delta — target-kind dispatch

`lowerExpr` (`klower.kite:2528`-area) lowers `FEIs` by classifying the target and emitting the right test.
Cleanest is an **AST→IR** lowering that reuses existing `Expr` nodes so no new backend op is needed:

```
fun classifyIsTarget(lo, tyStr) -> one of: STRUCT | TRAIT | VARIANT | ENUM | PRIM | UNKNOWN
```

- **STRUCT / CLASS** → `EBin("==", ECall("__typeId", [x]), EInt(structIdx))`. `__typeId` is already a
  codegen builtin (`codegen.kite:1171`, `genTypeId` `:927`).
- **TRAIT** → `ECall("__is_" + Trait, [x])`, and synthesise the predicate once per trait (mirror
  `buildDispatcher`, `klower.kite:3391`):
  ```
  fun __is_Shape(obj): Bool { val __t = __typeId(obj)
    if (__t == id(Circle)) return true ; if (__t == id(Square)) return true ; return false }
  ```
  Generated alongside the `__dyn_` dispatchers, from the same `implTypesOf` (`klower.kite:3373`) list.
- **VARIANT** (`is Some`) → the `PVarP` test as an expression:
  `EBin("==", ECall("__loadTag", [x]), EInt(variantTag(Some)))`, i.e. load `[obj+0]` and compare the tag.
  (Either add a tiny `__loadTag`/`__rawLoad(x,0)` builtin, or a dedicated `EIsVariant(x, tag)` IR node
  lowered exactly like `PVarP` at `codegen.kite:544`.) This is the node the `when` unification reuses.
- **ENUM (whole type)** → not runtime-distinguishable. Fold to a static answer when `src`'s static type
  proves it, else `lowFail("`is` on a whole enum type is not runtime-decidable — match a variant (`is Some`) instead")`.
- **PRIM** (`is Int`) → **constant-fold** from the subject's static type: `EInt("1")`/`EInt("0")` when the
  static type is known; `lowFail(…)` when it is erased/unknown (a primitive can never sit behind an erased
  reference, so an unknown here is a real "can't decide" — a loud diagnostic, never a garbage read).
- **`neg == 1`** wraps the whole thing in `EUnary("not !", …)` (logical-not now works correctly since the
  `EUnary("not !")` → `cmp+cset eq` fix).

`x` must be evaluated once when it has side effects; bind it to a fresh temp (`freshName`, as
`lowerNotNull` `:2558` already does) before the compare.

**No `arm64.kite` change** — everything reuses `__typeId`, `==`, `not`, and a tag load that already exist.

---

## 2. The smart-cast subsystem (the centerpiece)

A dedicated flow-narrowing **department**, isolated in its own module, that any narrowing site plugs into
without bespoke logic. It has two responsibilities, cleanly split:

1. **Analysis (pure, shared):** given a boolean condition and a sense (then/else branch), compute the set
   of narrowing **facts** it establishes. This is the reusable brain. It is total and side-effect-free.
2. **Application (per-pass, thin):** each pass takes those facts and writes them into *its own* scoped
   binding table (`TEnv.locals` / `Lo.locN` / `Ctx.ltyN`), then restores on scope exit.

Splitting it this way means the hard part — understanding `is` / `!= null` / `&&` / `!` — lives once, and
adding a new narrowing site (a future `while (x is T)`, a `require(x is T)`, a `?.let {}`) is a few lines
of "call `narrowFacts`, apply, recurse, restore".

### 2.1 Where it lives

New module **`compiler/sema/smartcast.kite`**, added to the manifest `compiler/kitec.kite` after
`kfront.kite` (so it sees `FExpr`) and before `kcheck.kite`/`klower.kite` (so both use it). Because the
manifest uses **quoted (flat-include) imports** and Kite allows forward references, placement is free; put
it early for readability. It depends only on `FExpr` + a handful of type predicates — no dependency on
`TEnv`/`Lo`/`Ctx`, which keeps it a leaf module usable by all three.

### 2.2 The API

```
// A single narrowing fact: within this branch, `name` may be treated as type `ty`.
// kind 0 = IS (narrow to a concrete/trait/variant type)   kind 1 = NONNULL (strip `?`)
struct Fact(val name: String, val ty: String, val kind: Int)

// The pure analyzer. `cond` is the branch condition; sense 1 = facts true on the THEN path,
// sense 0 = facts true on the ELSE / fall-through path. Returns the facts that HOLD on that path.
fun narrowFacts(cond: FExpr, sense: Int): IntBuf     // IntBuf<Fact>

// Is `e` a narrowable reference? Only a bare, stable name qualifies (§2.3). Returns "" if not.
fun narrowTarget(e: FExpr): String
```

`narrowFacts` recurses structurally over the condition:

| condition (`sense = 1`, then-branch)   | facts produced |
|----------------------------------------|----------------|
| `x is T`  (`FEIs(x,T,0)`)              | `[Fact(x, T, IS)]` if `narrowTarget(x) != ""` |
| `x !is T` (`FEIs(x,T,1)`)             | none on then; on `sense=0` → `[Fact(x, T, IS)]` |
| `x != null` (`FEBin("!=", x, FENull)`) | `[Fact(x, "", NONNULL)]` |
| `x == null` (`FEBin("==", x, FENull)`) | none on then; on `sense=0` → NONNULL |
| `a && b` (`FEBin("&&", a, b)`)        | `narrowFacts(a,1) ++ narrowFacts(b,1)` (both hold) |
| `a \|\| b`                             | none on then (neither is guaranteed); on `sense=0` → `narrowFacts(a,0) ++ narrowFacts(b,0)` (De Morgan) |
| `!c` (`FEUnary("not !", c)`)          | `narrowFacts(c, 1 - sense)` |
| anything else                          | none |

The `sense` flip on `!`, `!is`, `== null`, and `\|\|` is what makes `if (x !is T) return` narrow the
**fall-through** and `x ?: return` / `!!` narrow the continuation. The `&&` rule is what makes
`x is T && x.f` narrow `x` inside the RHS.

### 2.3 The stability rule (soundness)

**Only a stable binding may be narrowed. A stable binding is a `val` local (or a value-parameter) whose
name is not reassigned between the check and the use.** A `var` is unsound — it can be reassigned to a
different runtime type between `x is T` and `x.f`, so `narrowTarget` returns `""` for any `var`.

Concretely `narrowTarget(e)`:
- `FEIdent(name)` → `name` **iff** `name` is a `val`/immutable local; else `""`.
- everything else (`this.field`, `a.b`, index, call) → `""` in v1. (Kotlin narrows stable `val`
  properties too; deferred — see §7-Q4. Narrowing `this.field` is unsound under ARC aliasing anyway.)

This requires the mutability bit to survive into each pass:

- **Parser:** already there (`FSLet.isVar`).
- **Checker:** add a `mut: Int` to `Binding` (`kcheck.kite`), set from `checkLet` (`:2105`). `narrowTarget`
  consults `tLocal`'s binding.
- **Lowerer:** add a parallel `Lo.locMut: IntBuf` beside `locN`/`locT`; `bindLoc` gains a mut arg (or a
  `bindLocMut`). `localMut(lo, name)` mirrors `localTag` (`:94`).
- **Codegen:** add `Ctx.ltyMut` beside `ltyN`/`ltyV`.

This is additive: existing call sites pass "immutable" for `val`-bound names and function params, "mutable"
for `var`. Byte-inert to programs that never narrow.

### 2.4 Application in each pass

Each pass wraps a narrowed branch in **save → apply facts → recurse → restore**. The facts are applied to
the pass's *own* table, so downstream lookups (`tLocal` / `localTag` / `typeNameOf`) transparently see the
narrower type.

**Checker** (`inferIf`, `inferWhen`, and `&&` in `inferBinary`):

```
fun applyFacts(env, facts): Int {                       // into a freshly tPush'd scope
  var i = 0
  while (i < facts.size()) { val f: Fact = facts.get(i)
    if (f.kind == NONNULL) { tBind(env, f.name, stripNull(tLocal(env, f.name).ty)) }
    else { tBind(env, f.name, parseTyStr(env.prim, f.ty)) }
    i = i + 1 }
  return 0
}
```
`inferIf` (`:1985`) becomes: infer `c`; `tPush`; `applyFacts(env, narrowFacts(c,1))`; infer then-branch;
`tPop`; `tPush`; `applyFacts(env, narrowFacts(c,0))`; infer else-branch; `tPop`; join. The else-facts are
what make `if (x !is T) { … } else { /* x : T here */ }` work. Early-return narrowing (`if (x !is T)
return; x.f`) is the block-level generalisation (§7-Q3): after a `then` that provably diverges (ends in
`return`/`throw`/`break`), the fall-through inherits `narrowFacts(c,0)`.

**Lowerer** (`lowerExpr` for `FEIf`, and the unified `when`): identical shape against
`bindLoc`/save-restore of `locN`/`locT` length. The lowerer must narrow too so that method dispatch
(`methodCallee` `:623`) and field access resolve against the narrowed type — e.g. `x.area()` on a
`Shape`-typed `x` narrowed to `Circle` mangles to `Circle_area`, not `__dyn_Shape_area`.

**Codegen** (`genExpr` for `EIf`/`EWhen`): narrowing rebinds `Ctx.ltyN` for the branch and restores after,
so `genField` (`:444`) computes the concrete offset. The `save = ctx.ltyN.size()` / truncate-back idiom
scopes it; note codegen does **not** scope `ltyV` today (payload types leak across arms harmlessly because
slot names differ) — the narrowing region must snapshot and restore length to avoid leaking a narrowed type
past its branch.

### 2.5 Null-narrowing ties into the existing `?.`/`?:`/`!!` machinery

Nullable narrowing (`Fact.kind == NONNULL`) rides the same subsystem:

- `if (x != null) { x.f }` → `narrowFacts` yields `NONNULL x` on the then-path; `applyFacts` strips the `?`
  (`stripNull`, `kcheck.kite:1088`).
- `x ?: return e` and `x!!` — after these, `x` is non-null on the continuation. `lowerElvis` (`:2565`) and
  `lowerNotNull` (`:2558`) already bind the tested value to a temp and branch on `== 0`; the subsystem adds
  a `NONNULL` fact for the continuation so the *result* is typed `T` not `T?`. `inferNotNull` (`:1394`)
  already returns the stripped type for the expression value; the subsystem generalises that to the *name*
  when the operand is a stable ident.
- `x?.f` stays as-is (`FESafeField`); it is already null-safe per-access and needs no name-narrowing.

Because null-narrowing is just a second `Fact` kind, the `&&` / `!` / else-branch plumbing is shared with
`is` for free: `if (x != null && x is T)` narrows `x` to non-null **and** to `T`.

---

## 3. Unifying `when` on top of §1 + §2

Today `when` has its own IR (`Arm`/`Pat`) and its own matcher (`genWhenE`). The unification makes a
subject-`when` **desugar to a boolean if/else-if chain over `is`/`==`/`in`**, reusing §1's tests and §2's
narrowing — one lowering path. The destructuring arm form is kept as sugar on the same spine.

### 3.1 A `when` arm is (condition, bindings, body)

Generalise every arm to a triple:

- **condition** — a `Bool` `FExpr` over the (once-bound) subject `s`:
  - `is T`            → `s is T`            (`FEIs`)
  - literal `42`/`'c'`/`true`/`null` → `s == 42` (`FEBin("==", …)`)
  - bare variant `None` → `s is None`      (tag compare, §1.5 VARIANT)
  - `in r`           → `s in r`            (§3.4)
  - `if guard`       → `… && guard`        (**footgun #1 fixed** — the guard finally participates)
  - `p1 | p2`        → `cond(p1) || cond(p2)` (**footgun #2 fixed** — every alternative participates)
  - `_` / bare ident / `else` → `true`     (catch-all)
- **bindings** — names the arm introduces, each with a narrowed type:
  - `is T` / literal / bare variant → none, but the **body is narrowed** via §2 (`s` is `T`/variant in the body)
  - `V(a, b)` (`FPCtor`) / `V(x = p)` (`FPRecord`) → payload binds (§3.3)
  - bare ident catch-all `name ->` → `val name = s`
  - `when (val n = subj)` → `val n = s` in every arm (the existing `bindStr` form, `parseWhen:784`)
- **body** — unchanged.

The whole `when` becomes:

```
val s = <subj>                       // evaluate ONCE (fresh, stable ⇒ narrowable)
if (cond0) { <binds0> ; body0 }
else if (cond1) { <binds1> ; body1 }
…
else { <else body>  |  0 }           // no-else keeps today's `0` fallthrough (genWhenE:566)
```

This is a pure **AST→AST** desugar in `klower`, emitting `FEIf`/`FEBlock`/`FEIs`/`FEBin` — nodes the
checker and lowerer already handle. The subject-once binding `val s` is a fresh `val`, hence stable, so §2
narrows it in each arm's condition and body.

### 3.2 Both arm forms coexist

`is T` / literal / bare-variant arms become boolean conditions (concise, no binds). `V(a, b)` stays because
it is the terse way to pull multiple payloads. They are **the same mechanism**: `V(a,b)` = the boolean test
`s is V` **plus** a binding preamble that reads the payloads off the now-narrowed `s`. So:

```
when (j) {
  JNull          -> …        =>  if (j is JNull) { … }
  JNum(n)        -> n + 1    =>  else if (j is JNum) { val n = j.<pay0> ; n + 1 }
  JObj(k = key)  -> key      =>  else if (j is JObj) { val key = j.key ; key }
  else           -> …        =>  else { … }
}
```

### 3.3 Named-variant-field access on a smart-cast value

`FVariant.payKind == 2` (`kfront.kite:471`) records **named** payload fields, so `JObj(val t: …)` has a
real field name `t`. Once `s` is narrowed to `JObj` in an arm, `s.t` should load that payload slot.

- Positional payloads (`payKind == 1`): `V(a, b)`'s preamble is `val a = <payload 0>`, `val b = <payload
  1>`, where "payload j" is the slot at `[obj + 8 + 8j]` — exactly what `genCtorPat` (`codegen.kite:533`)
  loads today. Expose it as a synthetic accessor (`__payload(s, j)`, a typed `__rawLoad(s, 8+8j)`) or keep
  a small `PCtorP` binding step. The declared payload type comes from `ctorPayloadTys`
  (`klower.kite:2911`), so the bound var carries the right static type (as `bindPatVars` `:2929` already
  does).
- Named payloads (`payKind == 2`): register each named field as a field of the *variant* in `structFN`/
  `structFT` (or a variant-field table) so `fieldOff`/`typeNameOf` resolve `s.t` after narrowing. Then
  `V(t = p)` is just `val p_bind = s.t`, and free-standing `s.t` (outside a destructuring arm) works too —
  the payoff of doing this through smart-cast rather than only inside the pattern matcher.

### 3.4 `in r` arms

`when` `in r` needs `s in r` as a boolean. Two options (§7-Q2):
- **A (recommended):** add `in`/`!in` as an expression operator at the same rung as `is` (§1.3), lowering
  to the range/collection `contains` role (`roleSym`), so `s in a..b` and `s in coll` both
  work everywhere, not just in `when`.
- **B (minimal):** keep `in` pattern-only (`FPInP`) and have the `when` desugar special-case an `in` arm to
  the contains-call directly. Less general; no new expression syntax.

### 3.5 Retiring `Arm`/`Pat`/`genWhenE`

Once every `when` desugars to `if/else`, the `Arm`/`Pat` IR (`codegen.kite:69–71`), `lowerArm`/`lowerPat`/
`lowerArms` (`klower.kite:2896–2965`), and `genWhenE`/`testAndBind`/`genCtorPat` (`codegen.kite:539–567`)
become dead and can be deleted — a net simplification. **Do this only after the desugar is proven at the
fixpoint** (§5, Phase 3), because the compiler's own 272 `when`s all run through this path. Deleting early
would be a flag day; deleting last is a clean subtraction with the byte count as witness.

---

## 4. Interaction with the two silent footguns

Both are **fixed as a side effect** of §3, and could even be fixed independently earlier:

- **Guard dropped** → the desugar folds `if guard` into the arm condition as `cond && guard` (§3.1). The
  guard was already checked (`inferWhen:2025`); now it also executes. If §3 is deferred, the same fix lands
  by adding a `guard` field to the `Arm` IR and emitting it in `genWhenE` before the body — but the desugar
  removes the IR entirely, so prefer the desugar.
- **`|`-alternation drops all but first** → the desugar `||`s every alternative's condition (§3.1). If §3
  is deferred, `lowerArm` (`:2955`) would need to loop all `a.pats` and OR their tests — but only
  binding-free alternatives can be OR'd safely (two alternatives binding different names is ill-formed),
  which the desugar makes obvious. Add a checker diagnostic: an alternative arm whose alternatives bind
  names is rejected (Kotlin/Rust both forbid differing bindings across `|`).

---

## 5. Phased rollout (each phase independently gate-able)

Every phase must pass `gate.sh` (suite + **`kcc2 == kcc3`**) before landing. Ordered by risk, lowest first.
The compiler's own source stays in the seed-parseable subset until the syntax it uses is bootstrapped
(bootstrap-minimalism): **do not use `is`-expr / unified-`when` niceties in `compiler/*.kite` until the
phase that introduces them has already reached a fixpoint.**

**Phase 1 — `is` expression, alone (no narrowing).**
`FEIs` AST + `parseIsCheck` + `inferIs` (→ `Bool`) + `FEIs` codegen for STRUCT/TRAIT/VARIANT/PRIM (§1).
Also generate `__is_<Trait>` predicates. No smart-cast yet: `x is T` is a usable boolean, `x` is not
narrowed. Ship value: `if (x is Circle) { (x as Circle).area() }`-style code compiles.
*Gate risk: low.* New AST variant + new parser rung + new lowering case; the compiler's own code does not
yet use `x is T`, so the seed still parses `kitec.kite`, and the new paths are inert at the fixpoint.
Fixtures: `is` on each target kind, `!is`, precedence (`a is T && b`), the primitive diagnostic.

**Phase 2 — the smart-cast subsystem + `if`/`&&`/null narrowing.**
New `compiler/sema/smartcast.kite` (`Fact`, `narrowFacts`, `narrowTarget`) + the `mut` bit threaded into
`Binding`/`Lo.locMut`/`Ctx.ltyMut` + `applyFacts` in checker `inferIf`, lowerer `FEIf`, codegen `EIf`, and
the `&&` RHS. Null-narrowing (`!= null`, `?:`, `!!`) as the `NONNULL` fact kind (§2.5).
Ship value: `if (x is T) x.f` and `if (x != null) x.f` work with no cast.
*Gate risk: medium.* Touches `if` lowering, which the compiler uses everywhere — but narrowing only fires
when a condition is a recognised `is`/null form over a stable name, so ordinary `if`s are byte-inert.
Verify by diffing per-file emitted code before/after on all 141 files (as Phase 1 numeric did).

**Phase 3 — unify `when` + named-field access, then retire the old IR.**
Desugar `FEWhen` (subject form) → if/else-if chain (§3), keeping `V(a,b)` as sugar; wire guards and
`|`-alternation through the boolean spine (§4); enable variant named-field access `s.t` (§3.3);
enable subjectless `when` (falls out — it is already an if/else-if chain). **Only after the fixpoint is
green**, delete `Arm`/`Pat`/`genWhenE`/`lowerArm`/`lowerPat` (§3.5).
*Gate risk: high.* All 272 compiler `when`s re-lower. The binary **will** change size (fixpoint invariant
is self-reproduction, not constancy). Land the desugar first (both paths available is impossible — the
desugar replaces `lowerArms`), so this is a single atomic swap gated hard. Sub-stage it: (3a) desugar with
old IR still present but unused → gate; (3b) delete old IR → gate (byte count drops = witness).

Optional **Phase 4 — else-branch & early-return narrowing** (§2.4, §7-Q3), stable `this.field`/property
narrowing (§7-Q4), `in`-expression (§3.4-A). Each independent, low-risk, additive.

---

## 6. Self-host risk analysis

The compiler is written in Kite and self-hosts: seed → `k1`, `k1` → `k2`, `k2` → `k3`; the invariant is
**`k2 == k3`** (`gate.sh:20–24`), currently **660882 bytes**. `k1` is produced by the *fixed* seed and may
legitimately differ. Two distinct risks:

**(a) Seed-parseability (reseed trigger).** The seed is a frozen binary; it must still parse `kitec.kite`.
- Adding the `FEIs` *variant*, `parseIsCheck`, `inferIs`, `smartcast.kite`, and new `when` lowering to the
  compiler **source** is fine — the seed parses enum decls, new functions, and new `when` cases.
- The seed **cannot** parse `x is T` as an *expression* or any unified-`when`-only syntax. Therefore
  **`compiler/*.kite` must not *use* `is`-expr / new `when` features until after the introducing phase has
  self-reproduced.** This is the standing bootstrap-minimalism rule; every phase above respects it. No
  reseed is required for any phase, because no phase forces new *surface syntax into the compiler's own
  source* before that syntax can compile itself.

**(b) Fixpoint correctness (miscompile trigger).** Changing lowering/codegen changes emitted bytes; that is
allowed as long as the new compiler compiles itself reproducibly.
- **Phase 1** is byte-inert to the compiler's own compilation: the compiler contains no `x is T`
  expression, so `FEIs` codegen is never exercised while compiling `kitec.kite`. `k2 == k3` should hold at
  the *current* size (a strong, cheap check that Phase 1 didn't disturb existing paths). The FExpr enum
  gains a variant — append `FEIs` **before `FENoRes`** (or at the very end) so existing variant tags are
  unchanged; a mid-enum insertion would renumber tags and force every `when (e: FExpr)` in the compiler to
  recompile differently (still correct, but needless churn — avoid it).
- **Phase 2** fires narrowing only on recognised conditions; the compiler *does* use `if (x != null)` and
  will start using `is` internally only *after* Phase 2 self-reproduces. Until then, Phase 2 changes the
  compiler's bytes only where an existing `if` condition happens to be a narrowable form over a stable name
  — audit these (grep the compiler for `if (… != null)` over `val`s). Expect a small, deliberate byte
  drift; new fixpoint size, `k2 == k3` must hold.
- **Phase 3 is the dangerous one.** Every `when` in `klower`/`kcheck`/`codegen` (97/67/19) re-lowers
  through the desugar. A single miscompiled `when` corrupts `k1` → cascades to `k2 ≠ k3` or a crash. Two
  concrete hazards: (i) the desugar must preserve **first-match, top-to-bottom** semantics and the
  **no-match → 0** fallthrough exactly (`genWhenE:566`); (ii) bare-variant arms (`None ->`) must lower to
  the **tag** compare, not a struct type-id compare (§0.3) — getting this wrong silently matches nothing.
  Mitigation: sub-stage 3a/3b (§5), keep the old `genWhenE` path in the tree until 3b, and add a
  differential fixture that compiles a representative enum-`when` and checks runtime output before trusting
  the fixpoint. **This phase is a supervised landing.**

**Verdict:** Phases 1–2 are low/medium risk and cannot break the fixpoint if the bootstrap-minimalism rule
is followed (no new surface syntax in the compiler's own source until it self-reproduces). Phase 3 is high
risk purely because it rewrites the lowering of a construct the compiler uses 272 times; it is safe *if*
sub-staged and gated with a runtime differential, not the byte check alone. No phase requires a reseed.

---

## 7. Open decisions (for the user)

- **Q1 — `is` precedence.** Recommendation: a dedicated rung between `==` and relational (`is` looser than
  `< >`, tighter than `==`, tighter than `&&`). Alternative: fold into the relational rung (same level as
  `< >`). Either satisfies the motivating cases; pick one and it is frozen by fixtures.
- **Q2 — `in` as an expression.** Add `in`/`!in` at the `is` rung (general, recommended) or keep it
  pattern-only and special-case the `when` `in r` arm (minimal). Affects only how §3.4 is spelled.
- **Q3 — early-return / else narrowing depth.** v1 narrows the then-branch and (via sense-flip) the
  else-branch. Do we also want "`if (x !is T) return; x.f`" fall-through narrowing (needs a
  "then-branch provably diverges" analysis)? Recommended as Phase 4, not v1.
- **Q4 — what is "stable"?** v1 = `val` locals + value params only. Extend to stable `val` properties
  (`this.field`, `a.b` where every link is `val`) later? Kotlin does; under ARC aliasing it is subtler.
  Recommend deferring.
- **Q5 — whole-enum `is` (`x is Option`).** Reject with a diagnostic (recommended — all enums share
  type-id `-1`, so it is undecidable), or fold to a static answer only when the static type already proves
  it? Variant-level `is Some` covers the real need.
- **Q6 — exhaustiveness.** The unification makes an exhaustiveness/`else`-required check natural (it is just
  "does the if/else-if chain cover every variant of the subject's enum?"). In scope now, or a separate
  follow-up? Recommend follow-up — it is a checker-only addition once §3 lands.
- **Q7 — `as` smart-cast.** With narrowing, an explicit `x as Circle` (currently numeric-only, `FECast`
  `kcheck.kite:1408`) inside a narrowed branch could become a checked/free reference cast. Out of scope
  here; note the interaction so `as` and `is` stay coherent.

---

## 8. Where it lives (summary of touch points)

| Concern | File · function |
|---|---|
| `FEIs` AST variant, printer | `frontend/kfront.kite` (`FExpr` `:418`; printExpr `:1711`) |
| `is`/`!is` parse rung | `frontend/kfront.kite` (`parseIsCheck`, new; `parseEq` `:1096`) |
| **Smart-cast subsystem** | **`sema/smartcast.kite`** (new: `Fact`, `narrowFacts`, `narrowTarget`) |
| `is` type-check, `Bool` result | `sema/kcheck.kite` (`infer` `:2043`; `inferIs`, new) |
| Narrowing in checker | `sema/kcheck.kite` (`inferIf` `:1985`, `inferWhen` `:2014`, `inferBinary`/`&&` `:1367`; `Binding` +`mut`) |
| `is` lowering + target classify | `driver/klower.kite` (`lowerExpr` `:2528`; `classifyIsTarget`, new) |
| `__is_<Trait>` predicate gen | `driver/klower.kite` (beside `buildDispatcher` `:3391`) |
| Narrowing in lowerer | `driver/klower.kite` (`bindLoc` `:57` +`locMut`; `FEIf` lowering `:2527`) |
| `when` → if/else desugar | `driver/klower.kite` (replaces `lowerArm`/`lowerArms` `:2952`) |
| Variant named-field access | `driver/klower.kite` + `codegen.kite` (variant field table; `genCtorPat` `:533`) |
| Narrowing in codegen | `codegen/codegen.kite` (`setLty` `:361` +`ltyMut`; `EIf`/`EWhen` gen) |
| Tag/type-id tests reused | `codegen/codegen.kite` (`genTypeId` `:927`, `variantTag` `:464`, `structIdx` `:329`) |
| Old IR to retire (Phase 3b) | `codegen.kite` `Pat`/`Arm` `:69–71`, `genWhenE` `:550`; `klower` `lowerPat`/`lowerArm` |

No `backend/arm64/arm64.kite` change is required at any phase — every new test reuses `__typeId`, `==`,
`not`, and a raw tag load that already exist.
