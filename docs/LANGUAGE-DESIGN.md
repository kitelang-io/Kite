# Kite Language Design

> **Companion:** implementation-level detail (pattern matching & `when`, traits/generics/derives, closures/functions/iterators, the core stdlib & formatting, and the bootstrap slice) lives in [`LANGUAGE-DESIGN-DETAIL.md`](LANGUAGE-DESIGN-DETAIL.md).
>
> **Explicit type arguments** use turbofish `f::<T>()` (confirmed 2026-08-16) — kept as a rare escape hatch so the hand-written self-hosting parser stays unambiguous; strong inference makes it almost never needed. `::` for paths is unchanged.

## Confirmed decisions

Every blocker and major conflict the critics raised was resolved and folded into the dimension sections. The three genuine value-forks the synthesis flagged were **confirmed by the user on 2026-08-16** (all three took the recommended option); they are settled, not open:

1. **Collections & `String` use value-semantic copy-on-write** — `List`/`Map` are value types over a single-owner ARC buffer (mutation copies only when not `isUniquelyReferenced`); `String` is immutable with shared-storage `Substr` slices. The stage-0 backend accepts the extra cost. *(Reference-semantic `class` collections rejected.)*
2. **Integer overflow is debug-trap / release-wrap**, with a per-compilation `-C overflow-checks=on|off` override and explicit `&+`/`checkedAdd`/`saturatingAdd` families. *(Always-trap rejected.)*
3. **`panic = unwind` is committed post-bootstrap** so RAII/`defer` cleanup is honest for long-lived servers/tests; bootstrap ships `panic = abort`. *(Abort-only-forever rejected.)*

The settled sigil scheme (`?`-family = nullability, `try`/`try!` = error propagation, `panic` = bugs) is likewise fixed.

**Wishlist additions (2026-08-16, from Nick):**
1. **Kotlin-style extension functions & properties** — added (see Generics & traits; staged M5).
2. **Concurrency switched to Kotlin-style `suspend`** with implicit suspension — call sites write **no `await`** (see Concurrency & async). This supersedes the earlier explicit-`async`/`await` default.
3. **Value-class transparency** via `@repr(transparent)` — added (see Type system core).
4. **Cold `Flow<T>` streams** — added to the concurrency roadmap (post-self-host).

Decided for v1; revisitable as implementation surfaces new constraints.

---

## At a glance

| Decision area | Kite's answer |
|---|---|
| Surface | Kotlin-flavored expressions over Rust-flavored nominal declarations; expression-oriented (`if`/`when`/`{}` yield values) |
| **Signature** | `comptime` (compile-time execution unifying generics/const/derive/macros, zero-cost) + **zero-ceremony ARC** (GC feel, manual perf, no borrow checker) |
| Value vs reference | `struct`/`enum`/primitives = value types (inline, copy); `class` = reference type (heap, ARC) |
| Memory | ARC + RAII, deterministic `deinit`, **no GC**; **non-atomic** refcounts by default, atomic via `Arc<T>` for cross-task |
| Collections/String | **Value-semantic copy-on-write** `List<T>`/`Map<K,V>`; immutable UTF-8 `String` with shared-storage `Substr` slices |
| Nullability | `T?` **is** `Option<T>`; `?.` `?:` `!!` `as?` desugar onto it; null-pointer niche makes `T?` of a reference zero-cost |
| Errors | `Result<T,E>` ordinary enum; `try`/`try!` prefix keywords; `panic` = abort (bugs); channels never overlap |
| Error conversion | `try` identity is a compiler special-case; cross-type conversion via `From` (no reflexive blanket → no coherence overlap) |
| Generics | Parametric + trait bounds, **no lifetimes**; static dispatch via monomorphization; `dyn` opt-in; invariant now, `out` covariance committed for v1 |
| Extensions | Kotlin-style extension functions & properties: static, zero-cost, member-wins; complement traits (traits = polymorphism, extensions = convenience) |
| Value classes | Single-field value `struct`; `@repr(transparent)` = identical ABI to the field (zero-cost typed units, FFI-safe) |
| Ownership vocabulary | Receivers `self`/`mut self`/`consuming self`; params `borrow`(default)/`inout` (`&x` call-site)/`consuming` |
| Dispatch/type info | One type descriptor `{size, align, copy, move, destroy, vtable}` shared by object header and `dyn` fat pointer |
| Concurrency | Kotlin-style `suspend` (implicit suspension, **no `await`**), poll-based coroutines, first-class `scope { }`, cold `Flow` streams; cooperative cancellation, no unwinder; `Sendable` marker |
| Paths | `::` for module paths / associated & static fns / enum-variant qualification / projection (`I::Item`) / turbofish; `.` for instance members |
| Visibility | `pub` (cross-package) / default (package-internal) / `private` (module-local) |
| Toolchain | OCaml stage-0 → self-hosting Kite; hand-written AArch64 + Mach-O backend; `panic=abort` in bootstrap |

---

## Signature identity

Beyond "native + no JVM," two pillars give Kite its own character — chosen so it is **not** a Kotlin clone, each serving one axis of the north star. (Confirmed 2026-08-16.)

**Why `comptime` leads.** In the `ARC × comptime` design space, that cell is the genuinely-unoccupied one: Swift is ARC with only weak compile-time execution, Zig is comptime with manual memory, and no shipping language pairs strong comptime *with* ARC. ARC **alone** is Swift's crowded home turf and the hardest axis to win outright — so `comptime`, the one pillar with **no direct competitor**, is presented as the **primary differentiator**, and zero-ceremony ARC as the **second** pillar that makes the combination pay off. Both are kept; the order reflects where the daylight is.

### Pillar 1 — `comptime` (compile-time execution)

One mechanism for **running ordinary Kite code at compile time** and baking the result into the program. `comptime` **unifies what other languages split into four features — generics, `const`, `@derive`, and macros are all just comptime** — so there is one concept to learn, and every abstraction it produces is **zero runtime cost**.

- `comptime val T = …` computes a value/table at compile time (`comptime val CRC = buildCrcTable()`), baked in as data.
- `comptime fun` runs during compilation; a `comptime` **parameter** is a compile-time-known argument, so helpers specialize away — `fun pow(base: Int, comptime exp: Int)` makes `pow(x, 3)` compile to `x*x*x`. This is the engine behind "little helpers are free."
- **Generics are comptime:** a type parameter `<T>` is a comptime value of type `Type`; monomorphization *is* comptime specialization. The familiar `<T>` surface stays; explicit `comptime` params are the power-user escape hatch.
- **Derives are comptime functions:** built-in `@derive(Eq, Hash, …)` are stdlib comptime functions that inspect a type and generate its `impl`; **user-defined derives are the same** — hygienic, no separate macro language.
- `comptime for` / `comptime if` run at compile time (loop unrolling, conditional codegen); `comptime assert` checks invariants at build time.
- **Force multiplier:** contracts/refinement checks, data-oriented layout transforms (SoA/AoS), and small DSLs are later *comptime features*, not new language machinery — which is why effects and contracts stayed off the v1 signature list.

Serves **expressiveness** (write abstractions and codegen in plain Kite) and **performance** (it all evaporates at compile time). Nothing like it exists in Kotlin/Swift.

*Staging:* the framing (generics = comptime) holds from day one; monomorphization + built-in `@derive` are bootstrap-B. Full `comptime val`/`fun`/params, `comptime for`/`if`, and user-defined derives land at **M5** (needs the compile-time interpreter over the typed AST).

### Pillar 2 — ARC as a feature: zero-ceremony memory

Kite's memory model is a **selling point, not a tax: the ergonomics of a GC language, the performance of manual memory, and none of the borrow-checker ceremony.** This is the existing ARC pushed to a quality bar, not a new mechanism.

- **Ownership is mostly invisible.** `borrow`-by-default calling plus `self`/`consuming`/`inout` are there when you want control, but the common case needs no annotations.
- **Refcount traffic is *elided*, not merely emitted:** escape analysis + region/lifetime inference remove `retain`/`release` pairs and promote non-escaping allocations to the stack, so idiomatic high-level code compiles to what you would hand-write.
- **No borrow checker to fight** (Kite has no lifetimes); ARC + `weak`/`unowned` handle aliasing and cycles, and the compiler proves the counting away where it can.
- Deterministic `deinit`, value-semantic CoW collections, and `unsafe`/`RawPtr` as the escape hatch complete the picture.

Serves **performance** (predictable, zero-cost) and **expressiveness** (no ceremony). Distinct from Kotlin (GC), Rust (borrow-checker ceremony), and Swift (the retain/release overhead Kite aims to elide harder).

*Staging:* baseline ARC (non-atomic, borrow-default, `deinit`) is bootstrap-B; the elision / region-inference **optimizer** is **M5**.

**One-line pitch:** *write high-level, comptime-powered abstractions that compile to tight native code, with automatic memory that is invisible by default and zero-cost — GC feel, manual performance, no borrow-checker ceremony.*

> **Honest staging caveat.** Both pillars' *differentiating* form lands at **M5**, not in bootstrap: the zero-ceremony ARC **optimizer** (retain/release elision, coalescing, hoisting; escape + region inference; stack promotion) and the **full `comptime` interpreter** (const-eval, `comptime` params/specialization, `comptime for`/`if`, user-defined derives) are the two rows marked **M5 / No** in the Staging table. **Before M5, Kite is effectively "Kotlin syntax + Swift-style ARC + Rust-style traits"** — the very thing this section argues it is *not* — so the signature identity is **not truly tested until M5.** And the two M5 rows are **not equal in difficulty:** the ARC-elision optimizer is a **decade-hard** problem (Swift has invested ~10 years and retain/release traffic is *still* a common complaint), so it must **not** be weighted like a one-line feature such as "implement `defer`." The Staging table's uniform one-row-per-feature format hides exactly this difference in cost — read those two rows as programs, not checkboxes.

---

## Sigil, operator & keyword table

### Sigils and operators

| Token | Meaning | Channel |
|---|---|---|
| `T?` | Nullable type = `Option<T>` | Nullability |
| `?.` | Safe call (flatMap-flattening) | Nullability |
| `?:` | Elvis / default | Nullability |
| `!!` | Non-null assertion (panics on `null`) | Nullability |
| `as?` | Safe cast → `T?` | Nullability |
| `as` | Checked cast (panics on failure) | Casts |
| `is` / `!is` | Type test | Casts |
| `try expr` | Propagate `Err` (prefix keyword) | Errors |
| `try! expr` | Force-unwrap `Result`, panic on `Err` | Errors |
| `try { … }` | Try-block: scopes propagation, tail auto-`Ok` | Errors |
| `panic(msg)` / `abort()` | Unrecoverable bug → abort | Bugs |
| `!` | Boolean not | — |
| `~` | Bitwise not | — |
| `&+ &- &*` | Wrapping arithmetic (also `.checkedX`/`.saturatingX`) | Numerics |
| `&x` | `inout` argument marker (call site) | Ownership |
| `::` | Module path, static/associated fn, enum-variant qualifier, projection `I::Item`, turbofish `f::<T>()` | Paths |
| `.` | Instance member access | — |
| `..` / `..<` | Inclusive / half-open range | — |
| `...xs` | Spread in call args | — |
| `->` | Lambda arrow / `when` arm / function-type arrow | — |
| `@name(args)` | Annotation (`@derive`, `@extern`, `@inline`, `@repr`, `@file:`) | — |
| `$name` / `${expr}` | String interpolation | — |
| `[a, b]` / `["k": v]` | List literal / map literal | Literals |
| `=` / `+= …` | Binding & assignment — **statement, never an expression** | — |

`?` **never** appears in an error-handling position. `&` means only the `inout` call-site marker — it is never a reference-type constructor.

### Keywords

`fun val var` · `if else when for while` · `in !in is !is as` · `return break continue` · `struct enum trait impl where typealias` · `self mut consuming inout borrow` · `pub private` · `dyn` · `comptime` · `suspend spawn scope defer flow` · `unsafe extern` · `import package` · `unowned` · `true false null` · `Self Nothing Unit`

**Reserved (unimplemented in bootstrap):** `move unique weak const yield match do infix`.

### Operator precedence (highest → lowest)

1. postfix `.` `?.` `::` `f()` `a[i]` `!!`
2. prefix `-` `+` `!` `~` `try` `try!` — **right-associative** (so `try f()` groups the call under `try`; suspension is implicit, no `await` keyword)
3. `* / %`
4. `+ -`
5. shifts `<< >>`
6. `&`
7. `^`
8. `|`
9. range `.. ..<`
10. elvis `?:`
11. `in !in is !is as as?`
12. comparison `< > <= >=`
13. equality `== !=`
14. `&&`
15. `||`

Bitwise tiers (6–8) sit **above** comparison, so `a & b == c` parses as `(a & b) == c`. Assignment is statement-level and not part of the expression grammar (kills `if (x = y)`).

---

## Type system core

**Decisions (v1)**

- **Primitives** are register/inline value types with machine-honest sizes: `Int`=i32, `Long`=i64, `Float`=f32, `Double`=f64, `Bool`=1 byte, `Char`=32-bit Unicode scalar, `Unit`=zero-sized, `Nothing`=bottom. `String` = immutable UTF-8 ARC buffer (see Stdlib).
- **Fixed-width integer family is in the bootstrap subset** (resolves the FFI dependency): `Int8/16/32/64`, `UInt8/16/32/64`, and one pointer-width pair **`ISize`/`USize`**. *Rejected:* deferring these — the self-hosting compiler cannot bind libc or drive `as`/`ld` without them.
- **String iterates `Char`** (the primitive). *Rejected:* a separate `Rune` scalar type — one scalar concept only.
- **`struct` = value type** (inline, copy semantics, ARC glue only if it transitively holds references); **`class` = reference type** (heap, ARC). Compiler computes **trivial (memcpy)** vs **non-trivial (copy-retains / drop-releases in reverse field order)** by a transitive whole-type walk. `Copy` marker trait = trivially bit-copyable.
- **Local bidirectional inference only.** `val`/`var` and single-expression `fun` bodies infer; params, fields, and block-body returns require annotations. Numeric literals are polymorphic against the expected type, defaulting to `Int`/`Double`; literal defaulting is resolved **before** trait-constraint solving. No implicit value-level widening (`i.toLong()` is explicit).
- **Overflow:** two's-complement, **debug-trap / release-wrap** (see Open Decision 2), plus `&+`/`checkedAdd`/`saturatingAdd`.
- **Narrow subtyping only:** `Nothing <: T`, `T <: T?` widening, and explicit `T:Trait -> dyn Trait` coercion. Generics **invariant by default**; **declaration-site `out` (covariance) committed for v1** to remove producer-collection and covariant-`dyn` papercuts (`in`/contravariance stays deferred). Transparent `typealias`; newtype = single-field `struct`.
- **Value classes / transparent newtypes** *(wishlist)*: a single-field value `struct` is already unboxed; **`@repr(transparent)`** guarantees identical layout/ABI to its one field — a zero-cost typed unit that is *literally* the underlying value at runtime yet distinct in the type system, and safe across `extern "C"`. E.g. `@repr(transparent) struct Meters(val v: Int32)`.

```
val n = 42            // Int (i32)
val pi = 3.14159      // Double
val name = "Kite"
val hi = "Hello, ${name}! len=${name.length}"

fun scale(x: Double) = x * 2.0          // expr body: return inferred
fun add(a: Int, b: Int): Int { a + b }  // block body: return type required

struct Point(val x: Double, val y: Double)          // trivial value type: memcpy
class Node(val value: Int) { var next: Node? = null } // reference type: ARC

val l1: Long = 100        // literal coerces
val l2: Long = n.toLong() // value conversion is explicit
```

---

## Null-safety & flow typing

**Decisions (v1)**

- **Non-nullable by default;** `T?` opts in and **is literally `Option<T> { Some(T), None }`**, with `null` = `None`. `T??` nests honestly (`Option<Option<T>>`) — no Kotlin-style collapse — so it composes with generics without a special rule.
- **Sigils desugar onto `Option`:** `a?.b` = flatMap/map (chains stay `R?`), `a ?: d` = getOrElse, `a!!` = unwrap-or-`panic`.
- **Mandatory niche layout:** `T?` of a reference/ARC pointer uses the null pointer as `None` (one word, no tag); `retain`/`release` treat null as a no-op. Types that saturate all bit patterns fall back to a tag byte.
- **Flow narrowing** over structured control flow, restricted to **stable bindings** (immutable `val` always; `var` only with no intervening reassignment/mutable-or-`suspend` capture): `if (x != null) { … }`, early-exit `if (x == null) return`, `&&` chains, and `?:`-with-diverging-RHS (`val u = x ?: return`). **Committed for v1:** narrowing extends to `val`-property chains rooted in `val` receivers (Kotlin's stable-path envelope); bootstrap ships locals-only.
- **`null` has type `Nothing?`;** diverging expressions have type `Nothing`, which powers `x ?: return`.
- **Absence ≠ failure.** `Option` = reason-less absence; `Result` = failure with a payload. `try` never accepts `Option`. Explicit zero-cost bridges: `opt.okOr(e)`, `res.ok(): T?`, `res.err(): E?`.

```
fun greet(u: User?): String {
    val user = u ?: return "anon"   // guard-let ergonomics; user: User below
    return user.displayName
}

val len: Int  = nick?.length ?: 0
val cfg: Config = readConfig(p).ok() ?: default()   // Result→Option, then elvis
val hit: (User?)? = cache.get(k)                    // T?? nests: absent vs present-but-null
```

---

## Error handling model

**Decisions (v1)**

- **`Result<T,E>`** is a std lang-item enum, value type, monomorphized, niche-laid-out, `@mustUse`. Pattern-matches with `when`/`is Ok(v)`.
- **`try expr`** propagates: `Ok(v) → v`; `Err(e)` early-returns from the enclosing `Result`-returning function. **`try! expr`** unwraps or `panic`s. **`try { … }`** is a try-block (inner `try`s short-circuit to the block; tail auto-`Ok`; disambiguated by `try` immediately followed by `{`).
- **Error conversion without coherence conflict** *(resolves the blanket-impl overlap):* `try`'s **identity conversion is a compiler special-case** (same `E` passes through with no impl). Cross-type conversion goes through an ordinary `From` trait with **no reflexive blanket impl**, so `impl<E: Error> From<E> for AnyError` never overlaps a reflexive `From`. *Rejected:* Rust's `impl<E> From<E> for E` blanket, which would collide.
- **Typed errors by default;** `@derive(Error, From)` generates the `Error` impl and per-variant `From`. **`AnyError`** = `Arc<dyn Error>` for app-level "propagate anything," paid only on the cold error path. Std `trait Error { fun message(self): String; fun cause(self): Error? = null }` (note `cause` uses the nullability channel).
- **`panic` = abort, NO unwinding** in bootstrap. `Drop`/`deinit` and `defer` run on normal and `try`-early-return paths (the same drop-insertion pass ARC needs), **not** on panic. `try!`, `assert`, debug overflow, bounds, `todo()`, `unreachable()` all funnel to `bl abort`. *Rejected:* stage-0 unwinding machinery (DWARF/EH landing pads). **`panic=unwind` is committed post-bootstrap** (Open Decision 3).
- **`defer { }`** for non-RAII cleanup (reverse order at scope exit, including `try`-return, skipped on panic; `try` inside `defer` is disallowed). Channel bridges `.ok`/`.okOr`/`.err`; `?`-family never touches `Result`.

```
@derive(Error, From)
enum ConfigError { Io(IoError); Parse(ParseError) }

fun readConfig(path: String): Result<Config, ConfigError> {
    val text = try readFile(path)     // IoError → ConfigError via From
    val cfg  = try parse(text)
    Ok(cfg)
}

fun main(): Result<Unit, AnyError> {  // erased errors at app level, boxed only on Err
    val cfg = try readConfig("app.toml")
    Ok(unit)
}
```

---

## Generics & traits

**Decisions (v1)**

- **Nominal traits, separate `impl Trait for Type` blocks**, with default bodies, associated `type` members, and `Self`. **No lifetimes** — ARC is the reference story; bounds are trait-only.
- **Ownership vocabulary (unified across all dimensions):** receivers `self` (shared borrow, no retain) / `mut self` / `consuming self`; parameters default to `borrow`, with `inout` (mutable borrow, `&x` at call site) and `consuming` (owned). *Rejected:* `own self`, `mut Slice<T>` params, and Rust `&mut Self`/`&T` type notation — none of which exist elsewhere in Kite.
- **Bounds:** inline `fun <T: Ord + Hash> …` plus `where`. **Associated-type projection** via `::` → `I::Item`.
- **Dispatch:** static via monomorphization by default (direct calls, statically-emitted ARC); **`dyn Trait`** opt-in fat pointer for object-safe traits.
- **One type descriptor** `{size, align, copy, move, destroy, vtable}` is referenced by both the object header and the `dyn` fat pointer — all dimensions mean the same record.
- **Coherence:** orphan rule (trait or type head must be local), no overlap, no specialization; newtype workaround for foreign-on-foreign.
- **Operators desugar to core traits** (`Add`/`Ord`→`cmp: Ordering`/`Index`/…); arithmetic traits carry `type Output` and default `Rhs`. `@derive(Eq, Ord, Hash, Clone, Copy, Debug, Default)`. **Formatting is `Display` + `Debug`** (`Display` drives interpolation); *rejected:* `Show`.
- **Extension functions & properties (Kotlin-style)** *(added from Nick's wishlist)*: free-standing `fun Receiver.name(...)` and extension properties add methods to types you do **not** own, **without** a trait/`impl`. **Statically dispatched** on the receiver's static type (zero-cost, inlinable); **members always win** over extensions on a name clash; extensions cannot be `override`n and do not join `dyn` dispatch. Traits stay for polymorphism; extensions are for convenience (and to give `dyn`-free zero-cost helpers, per the "free little helpers" goal). Slotted at M5, out of bootstrap.
- **Sendability is a single `Sendable` marker trait** (auto-derived). *Rejected:* separate `Send`/`Sync`.
- **Iterator** uses nullability for end-of-stream: `fun next(mut self): Item?`. Nullable-element iterators must return `Item??`; a std `whileSome`/`for x in it` handles the nesting so the common loop never reasons about it.
- **No HKT.** **Bootstrap trait solver is a lookup-plus-substitution engine, not a search** *(resolves the self-contradictory bootstrap):* concrete impl heads only (including fully-applied constructors and associated-type bindings, e.g. `impl Iterator for TokenIter { type Item = Token }`), and abstract projection `I::Item` treated as an opaque nominal type constrained by `where I: Iterator`. **Deferred:** blanket/constrained impls, associated-type **equality** constraints (`I::Item::Output = I::Item`), and multi-hop projection normalization.

```
trait Iterator { type Item; fun next(mut self): Item? }

fun <I: Iterator> count(it: mut I): Int {
    var n = 0
    while true { val x = it.next() ?: break; n = n + 1 }
    n
}

trait Add<Rhs = Self> { type Output; fun add(self, rhs: Rhs): Output }
impl Add for Vec2 { type Output = Vec2; fun add(self, rhs: Vec2): Vec2 = Vec2(x+rhs.x, y+rhs.y) }

fun render<T: Drawable>(t: T) = t.draw()       // static
val shapes: List<dyn Drawable> = listOf(c, s)  // dynamic via vtable

fun String.shout(): String = this + "!"        // extension fn: static, zero-cost
val Int.isEven: Bool get() = this % 2 == 0     // extension property
```

> **NEEDS DECISION (mutable-borrow param mode).** The ownership vocabulary gives *parameters* only `borrow` (default) / `inout` / `consuming`, and reserves `mut` for **receivers** (`mut self`) — `mut Slice<T>` params are explicitly *Rejected*. Yet two signatures above are already reaching for a mode that isn't spelled out and are informally writing it as `mut`: **`count(it: mut I)`** (a *mutable* `Iterator` — `next(mut self)` mutates it) and **`out: mut Formatter`** in the trait/Display sigs (a sink the impl drives via `out.write(...)`). Both want a **mutable-borrow** param — a `&mut`-equivalent: a parameter the callee may mutate in place, does not own, and may not let escape. `inout` *nearly* fits (it is spelled "mutable borrow, `&x` at call site"), but it is specified as **single-storage write-back** (`bump(inout n); bump(&count)` reassigns `n`), not the "hand the callee a mutable view it drives through `mut self` methods" shape a Formatter/Iterator needs.
>
> **Options:** **(i)** adopt an explicit mutable-borrow param mode — either by specifying that `inout` covers method-driven mutation of the borrowed object (not just scalar write-back) or by adding a distinct fourth mode — and spell these params with it instead of the illegal `mut`; **(ii)** make them *receivers* (turn free `count` into a `mut self` method `I::count`; thread the Formatter as `mut self`). **Recommendation: (i)** — forcing every sink/driver to a receiver distorts APIs, and the trait signatures need *one* agreed spelling. **Resolve before bootstrap freezes `mut Formatter` into every `Display`/`Debug`/`Iterator` signature in the self-hosted compiler.**

---

## Memory model & ARC

**Decisions (v1)**

- **Value/reference split** as in Type-core; `Copy` marks trivial POD.
- **Borrow-by-default calling convention** (semantic, not an optimizer): passing a value emits **no** retain/release; `inout` (`&x`) mutates, `consuming` transfers. A borrowed param may not escape without becoming `consuming`.
- **Non-atomic refcounts by default** *(resolves the atomicity inversion):* `class` instances use plain load/add/store counts and are **not `Sendable`**. Cross-task sharing uses **atomic `Arc<T>`** (`Sendable` when `T` is); cross-task mutation via `Mutex<T>`. Object header = `{strong, weak, typeDescriptor*}`. *Rejected:* atomic-always default — it taxes the single-threaded bootstrap compiler for sharing that cannot occur.
- **Two shared-heap mechanisms, cleanly separated** *(resolves the overlap):* a **`class` pointer IS the strong reference** — no wrapper. `Rc<T>` (non-atomic, task-local) and `Arc<T>` (atomic, `Sendable`) exist **only** to put *value types* on the shared heap. `Box<T>` = unique owning heap indirection. *Rejected:* three names for the atomic type — it is **`Arc<T>`** everywhere (drop `Shared`).
- **`deinit`** deterministic destructors (run at strong-count-zero / scope end; fields released after the body, reverse order). RAII is primary; `defer` for ad-hoc cleanup.
- **Collections are value-semantic copy-on-write** (Open Decision 1): `List<T>`/`Map<K,V>` are value types over a single-owner ARC buffer; mutation copies only if `isUniquelyReferenced(&buf)`. `String` immutable with shared-storage `Substr` slices. *Rejected:* reference-semantic collections (a minimalism-first tradeoff).
- **Cycle breaking:** bootstrap ships **non-zeroing `unowned`** only; the compiler's own back-edges use **arena allocation + integer node IDs**. **Zeroing `weak` is deferred** post-self-host *(removes the trickiest runtime mechanism from stage-0)*.
- **Move-only `unique` types, implicit last-use-move elision, and the linearity checker are deferred out of bootstrap** *(borrow-default already makes calls cheap semantically).* Bootstrap keeps borrow-default, explicit `consuming`, `deinit`, `defer`, and naive scope-end release; OS resources are ordinary ARC `class` + `deinit`.
- **`unsafe { }`** blocks with `RawPtr<T>` (Copy, unmanaged) and `Unmanaged<T>` (manual ARC for FFI). ARC across a suspension point: live values retained into a compile-time-sized coroutine frame. `try`-error path runs reverse-order `deinit`.

```
struct Point(val x: Int, val y: Int)          // value, Copy
class Node(var value: Int) { var next: Node? } // reference, ARC (non-atomic)

fun area(p: Point): Int { p.x * p.y }          // p borrowed, no refcount traffic
fun bump(inout n: Int) { n = n + 1 };  bump(&count)
fun push(consuming node: Node) { node.next = head; head = node }

var a = [1, 2, 3]; var b = a   // value semantics: O(1) share
b.push(4)                       // buffer not unique → copy; a stays [1,2,3]
```

---

## Syntax, grammar & sigils

**Decisions (v1)**

- **Kotlin-flavored expressions over Rust-flavored nominal declarations.** `fun`, `val`/`var`, `if`/`when`/`for`/`while`, trailing lambdas; `struct`/`enum`/`trait`/`impl … for`.
- **`::` for paths / static & associated fns / enum-variant qualification / projection / turbofish; `.` for instance members only** *(resolves the path-sigil contradiction — every stdlib/error/generics example uses `::`).* Root namespace is **`kite`** (e.g. `kite::io`). This keeps the parser resolution-free and kills the `<` generics-vs-less-than ambiguity via `f::<T>()`.
- **Automatic terminator insertion** (Go-style, single-token lookahead) with leading-dot chaining; a trailing lambda must be on the call's physical line.
- **No brace struct literals — construction is a call:** `Point(x = 1, y = 2)`. So `{}` always means block/lambda. **Struct declaration is a Kotlin paren primary constructor with an optional brace body** for methods/`deinit` *(resolves the paren-vs-brace contradiction):*

  ```
  struct Point(pub val x: Int, pub val y: Int)
  unique struct File(val fd: Int32) { deinit { sysClose(fd) } }   // (unique deferred)
  ```
  Field visibility and `val`/`var` are written in the constructor list and standardized across all examples.
- **Visibility (unified with Stdlib):** `pub` (cross-package) / default (**package**-internal) / **`private`** (module-local). *Rejected:* `priv` and module-scoped default.
- **List/map literals:** `[1, 2, 3]` → `List<T>`; `["a": 1, "b": 2]` → `Map<K,V>` (colon disambiguates; empty forms need annotation). Ranges `..`/`..<`; spread `...xs`.
- Closures `{ x, y -> … }`, implicit `it`, trailing-lambda sugar; function types `(Int) -> Int`. String interpolation `"$x ${y}"` + triple-quoted raw strings. `if`/`when` are expressions (`when`-as-expression must be exhaustive). Casts `is`/`as`/`as?`. `@name(args)` annotations. Nestable block comments; `///` doc.
- **`try` precedence:** the single right-associative prefix tier (tier 2 above) is the source of truth; suspension is implicit (no `await`), so `try f()` groups the suspend call under `try`.

```
pub struct Token(pub val kind: TokenKind, pub val span: Span)

impl Display for Point { fun fmt(self, out: mut Formatter): Result<Unit, FmtError> =
    out.write("(${self.x}, ${self.y})") }   // no `try`: write already returns Result; tail-auto-`Ok` is `try { }`-block-only

val evens = numbers.filter { it % 2 == 0 }.map { it * it }.fold(0) { a, x -> a + x }

import kite::collections::{List, Map}
val xs = parse::<Int>(input)   // turbofish; no '<' ambiguity
```

---

## Concurrency & async

**Decisions (v1)** *(revised 2026-08-16 to the Kotlin-style `suspend` model)*

- **Kotlin-style `suspend fun` with implicit suspension.** A `suspend` function is called like an ordinary function — **no `await` at call sites**; the compiler infers suspension points and tooling marks them in the gutter. `suspend` still colors functions (a `suspend fun` is only callable from a `suspend` context). *Rejected:* explicit `async`/`await` (visible suspension) — the user chose Kotlin ergonomics over Rust-style visibility for suspension (while keeping `try` visible for errors).
- **Lowering unchanged:** `suspend` functions compile to **poll-based state machines** with compile-time-sized heap frames (one allocation per task). Destructors are synchronous (no async-drop). The `Future`/`Poll` machinery stays as the *implementation* vocabulary, not the surface:

  ```
  trait Future { type Output; fun poll(mut self, cx: Context): Poll<Self::Output> }
  enum Poll<T> { Ready(T); Pending }
  ```
  Suspend functions return ordinary values / `Result<T,E>`; error handling composes as plain `try fetchUser()` (a `suspend` call returning a `Result`).
- **Structured concurrency is a first-class `suspend scope { s -> … }`** — not a library call, not a destructor. It cannot exit until every `s.spawn { }` child completes or is cancelled+joined. `Task<T>` handles; `try t.join()` is a suspend call. No detached tasks in v1.
- **Cold `Flow<T>` streams** *(added from Nick's wishlist)* — Kotlin-style cold asynchronous streams over `suspend`: `flow { emit(x) }` with `map`/`filter`/`collect`; `collect` is a suspend call. This completes the "coroutines + flows" combo, at stdlib level, post-self-host.
- **Cooperative cancellation via the coroutine `Context`** (`isActive`/`isCancelled`); at a suspension point a cancelled task runs its current-state drop path using the same per-suspension liveness ARC computes — **no unwinder**, consistent with `panic=abort`. `defer` runs on cancellation cleanup too.
- **Timeouts:** `withTimeoutOrNull(d) { }: T?` (the **one sanctioned "failure-as-None" convenience**); use `withTimeout(): Result<_, Timeout>` when the reason matters.
- **Data-race safety via the single `Sendable` marker trait** (auto-derived); `spawn` captures must be `Sendable`. Non-atomic `class`/`Rc` are not `Sendable`; `Arc<T>`/immutable data are. No actors in v1; no effect-polymorphism (`suspend` is a function color). `dyn Future<Output=T>` boxes for erasure.
- **Executor semantics fixed** (cooperative, poll-driven task tree, work-stealing, no preemption); implementation deferred. **All of `suspend`/coroutines/`Flow` is excluded from the bootstrap subset** — `suspend`/`scope`/`spawn`/`flow` reserved, the coroutine transform lands post-self-host.

```
suspend fun loadDashboard(id: UserId): Result<Dashboard, ApiError> = scope { s ->
    val user = s.spawn { try fetchUser(id) }   // no `await` at the call site
    val feed = s.spawn { try fetchFeed(id) }
    Ok(Dashboard(try user.join(), try feed.join()))
}   // if either child errs, the scope cancels the other before returning Err
```

---

## Dimension-crossing invariants (single owner)

Every section above was decided on its own axis. The holes in a memory-plus-concurrency language hide **at the intersections** — the Cartesian product of dimensions no single section owns. This section **single-owns** the interaction of `Sendable` × ARC refcount atomicity × CoW collections × the work-stealing executor's task migration × `T? == Option<T>` inside `Iterator`. It states the invariants once, so they cannot fall between sections again.

**Core rule (already decided; restated as the anchor).** Non-atomic refcounts ⟹ **not `Sendable`**. A plain `class`/`Rc<T>` uses load/add/store counting and is task-local; only atomic **`Arc<T>`** (and immutable data) is `Sendable`; cross-task mutation goes through `Mutex<T>`. **This is exactly Rust's `Rc`/`Arc` split** — the non-atomic/atomic boundary *is* the `Sendable` boundary — and Kite adopts it deliberately. It follows directly that a **mutable CoW `List`/`Map`, whose single-owner buffer is `Rc`-counted, is task-local (not `Sendable`)**, so a `List` can never be observed mid-copy from two tasks: **cross-task CoW corruption is structurally prevented, not merely avoided by convention.** Nothing new is required for that case.

**GAP TO CLOSE 1 — Sendable shared types must carry atomic backing refcounts.** `String` and immutable-shared collections are declared `Sendable` (immutable data), but the memory model says "non-atomic refcounts by default" and `String`'s buffer is spelled `Rc<Bytes>` (non-atomic). Those two statements are in tension: an immutable `String` handed to another task is retained/released on *both* threads, which is a data race on a non-atomic count. **Invariant to adopt:** *any refcounted type that is `Sendable` uses **atomic** retain/release on its backing buffer* — i.e. a `Sendable` `String`/immutable collection is backed by an `Arc`-class (atomic) count, not `Rc`. `Sendable` is precisely the predicate that flips the backing count from non-atomic to atomic. (Enforcement is M5 with the rest of `Sendable`, but the rule must be written now so the two layouts don't diverge.)

**GAP TO CLOSE 2 — task migration is an explicit executor happens-before constraint, not an assumption.** The executor is *work-stealing*: a task may be resumed on a **different** worker thread than the one it suspended on. So even a non-atomic, task-**local** `Rc`'s retain/release can execute on two different threads over the task's lifetime. This is sound **only if** every task migration establishes a **happens-before** edge between the releasing worker and the acquiring worker (a correctly-built work-stealing deque does — the steal synchronizes-with the push). **Invariant to adopt, as an executor obligation:** *the executor MUST publish a happens-before edge across any task migration (suspend-on-A → resume-on-B), so that non-atomic task-local refcount traffic before the suspension is visible after the resumption.* This is a **constraint on the executor implementation**, written down here rather than left implicit in "work-stealing," because the safety of the entire non-atomic-`Rc`-is-fine story rests on it.

**KNOWN LIMITATION (residual) — `T? == Option<T>` vs `Iterator::next(): Item?`.** Because `T?` *is* `Option<T>`, an iterator of nullable elements collides with the end-of-stream sentinel: `next(mut self): Item?` over `Item = T?` needs `T??` (outer `None` = stream done, inner `None` = a present-but-null element). The common paths are handled — `for x in it` and the `?: break` desugar **peel the outer optional** (binding `x: T?`), and `filterNotNull`/`whileSome` drain explicitly — so ordinary loops never reason about the nesting. **But generic code over `I: Iterator` with a nullable `I::Item` still faces `Item??` directly** and must peel it by hand; the sugar only covers the concrete-loop case. This is a **known limitation** with the above mitigation. The eventual clean fix is to **decouple iteration-termination from element-nullability** — a distinct done-signal (e.g. `next(): Step<Item>` with `Yield(Item)`/`Done`, or an explicit `hasNext`) instead of overloading `Item?` — so the sentinel never competes with a nullable element. Deferred, but flagged so it is chosen deliberately rather than by omission.

---

## Modules & core stdlib

**Decisions (v1)**

- **Module = directory;** all `.kite` files in a directory merge into one flat namespace; module path mirrors the directory path under the package root. A file may carry an optional top-of-file `package myapp::lexer` **assertion** for Kotlin-style familiarity — it must match the file's directory (assert-only: it *names*, never relocates; a mismatch is a compile error). **Absolute imports** with `::`, brace-grouping, glob, and `as`: `import kite::collections::{List, Map}`, `import kite::io::*`, `import myapp::lexer::Token as Tok`. *(Confirmed 2026-08-16: `::` over `.` to keep generics unambiguous; directory-as-module over Kotlin's dir-decoupled per-file package.)*
- **Package** = source tree named by a minimal `package.kite` manifest; bootstrap has the stdlib as an implicit dependency and no external resolver.
- **Prelude** is two separate things: (1) the compiler auto-injects the language primitives (List/Map + the nominal methods behind `[..]`/`{..}`) via `compiler/prelude.conf`, a config that NAMES stdlib modules (see ARCHITECTURE) — this is the only *automatic* availability; (2) `kite::std::all` is an optional convenience module re-exporting all three layers, imported **explicitly** (not auto). *(Supersedes the earlier single auto-imported `kite::prelude` + `@file:NoPrelude` design.)*
- **`T?` is `Option<T>`; `Result`/`Option` are plain enums in `kite::core`.** `try` is Result-only.
- **String** = immutable UTF-8 ARC buffer; slicing yields zero-copy `Substr` (retains backing storage); mutation via `StringBuilder`; iteration yields **`Char`**; no O(1) char indexing.
- **Collections are value-semantic CoW** (Open Decision 1): `List<T>` = `{ptr,len,cap}` handle over a CoW buffer; `Map<K,V>` = open-addressing (FNV-1a bootstrap hash, `Map[k]: V?`), requiring `Hash + Eq`. Single canonical growable name **`List`**; general slice **`Slice<T>`**, string slice **`Substr`**.
- **Standard I/O error type is `IoError`** everywhere (fix casing).
- **FFI:** `extern "C" { … }` import blocks and `@extern("C")` exports over FFI-safe types (`Int32`, `UInt8`, `USize`/`ISize`, `RawPtr<T>`, `CStr`, `@repr(C)` structs); every FFI call / raw deref inside `unsafe { }`. **No variadic FFI in bootstrap** (Darwin AArch64 passes varargs on the stack — Kite formats natively instead). **Internal calling convention is distinct from AAPCS64** *(resolves the ABI over-scoping):* scalars in x0–x7/d0–d7, **all aggregates by hidden pointer** (natural under borrow-default), by-value returns via `sret`. Full AAPCS64 aggregate classification is confined to the `extern "C"` boundary and `@repr(C)`.
- **Toolchain driven via `kite::sys::Process.run(cmd, args): Result<Int32, IoError>`** over fixed-arity POSIX bindings (`posix_spawn`, `pipe`, `read`, `write`, `waitpid`, `open`, `close`, `mmap`); no shell `system()`.
- **Interpolation lowers to `StringBuilder` appends via `Display`**; `Display` (user-facing) + `Debug` (diagnostics) are the two formatting traits.
- **Named/default args:** bootstrap lowers defaults as caller-side fill and **restricts default values to constant/literal expressions** *(avoids mid-call ARC-cleanup ordering in the earliest front end)*; arbitrary-expression defaults deferred.
- **Layering (bootstraps in order):** `kite::core` → `kite::alloc` (`Box`, `Rc`, `Arc`, `RawPtr`) → `kite::collections` (`List`, `Map`, `StringBuilder`) → `kite::text` (`String`, `Substr`, `Char`) → `kite::io` → `kite::ffi`/`kite::sys`.

```
import kite::sys::Process
fun assemble(asm: String, obj: String): Result<Unit, IoError> {
    val code = try Process.run("as", ["-arch", "arm64", "-o", obj, asm])
    if code == 0 { Ok(unit) } else { Err(IoError::Subprocess(code)) }
}
```

---

## Staging

Milestones: **B** = minimal bootstrap subset (OCaml stage-0 must emit it; earliest stage-1 modules are written in it) · **M2** type-check · **M3** IR + ARC · **M4** AArch64 backend · **M5** language-complete-enough · **M7** self-host · **M8** multi-platform.

The bootstrap **build ladder** ("Kite-minus" floor first): primitives + payloaded enums + `when` → ARC classes + `deinit` → compiler-intrinsic (non-user-generic) `List`/`Map` → `extern "C"`/`Process` → then user generics/traits/closures. The earliest stage-1 modules deliberately avoid user-defined generics and closures.

| Feature | Milestone | In bootstrap (B)? |
|---|---|---|
| Primitives incl. **fixed-width ints `Int8..64`/`UInt8..64`/`ISize`/`USize`**, `Char`, `Unit`, `Nothing` | B / M2 | **Yes** |
| Local bidirectional inference; literal defaulting | B / M2 | **Yes** |
| `struct`(value)/`class`(reference)/payloaded `enum`; trivial vs non-trivial glue | B / M3 | **Yes** |
| `Option`/`T?` niche layout; `?.` `?:` `!!` `as?`; locals-only flow narrowing | B / M2–M3 | **Yes** |
| `Result` + `try`/`try!`; identity conversion (same `E`); `when`/`is Ok(v)` | B / M2–M3 | **Yes** |
| `panic = abort` (`bl abort`); `Drop`/`deinit`; `defer`; `try`-path reverse-order cleanup | B / M3–M4 | **Yes** |
| ARC runtime `{strong,weak,typeDesc*}`, **non-atomic** retain/release; borrow-default; `inout`/`consuming` | B / M3–M4 | **Yes** |
| **`unowned`** + arena/index back-edges | B / M3 | **Yes** |
| Value-semantic CoW `List`/`Map` + `isUniquelyReferenced`; immutable `String`/`Substr`; `Box`/`Rc` | B / M3–M4 | **Yes** |
| Trait solver: **concrete impl heads only**; opaque `I::Item` projection; associated types + `Self`; monomorphization | B / M2–M4 | **Yes** |
| Operator→trait desugar; `@derive(Eq,Ord,Hash,Clone,Copy,Debug,Default)`; `Display`/`Debug` | B / M2 | **Yes** |
| One closure form `{code,env}` (non-escaping, capture-by-value + retain), threaded through HOF generics | B / M3–M4 | **Yes** |
| Syntax: ATI, `::`/`.` split, turbofish, trailing lambdas, interpolation, list/map literals, named/const-default args | B / M2 | **Yes** |
| Visibility `pub`/default/`private`; directory modules; absolute imports; prelude; `@file:NoPrelude` | B / M2 | **Yes** |
| `unsafe`/`RawPtr`/`Unmanaged`; `extern "C"` (fixed-arity); `@repr(C)`; internal-vs-AAPCS64 conventions; `Process` | B / M4 | **Yes** |
| Debug overflow trapping; `&+`/`checked`/`saturating` families | M5 | No |
| Declaration-site **`out` covariance**; smart-cast on stable `val`-property chains | M5 | No |
| `From`-based cross-type error conversion; `@derive(Error, From)`; `AnyError`/`dyn Error`; `try { }` blocks | M5 | No |
| `dyn` dynamic dispatch, object-safety, vtable ABI; shared type descriptor for erased ARC | M5 | No |
| **Extension functions & properties** (static, zero-cost, member-wins) | M5 | No |
| **Zeroing `weak`**; move-only `unique` types; last-use-move elision + linearity checker | M5 | No |
| **Zero-ceremony ARC optimizer** (retain/release elision/coalescing/hoisting; escape + region inference; stack promotion) — **signature pillar 2** | M5 | No |
| **Full `comptime`** (const-eval, `comptime` params/specialization, `comptime for`/`if`, user-defined derives) — **signature pillar 1**; generics-as-monomorphization + built-in `@derive` already in B | M5 | No |
| `Sendable` enforcement; `Arc<T>`/`Mutex<T>` atomic path | M5 | No |
| `suspend`/`scope`/`spawn` coroutines + cold `Flow` streams; coroutine transform; executor/reactor; cancellation; `withTimeout` | M7+ | No |
| `panic = unwind` mode (Drop/`defer` on panic) | M7+ | No |
| Package manager, semver, multi-package + relative imports; SipHash; own assembler/linker for **new** targets (x86-64/ELF, WASM) | M8 | No |
<!-- note: the AArch64 Mach-O emitter + self-linker is already DONE and in daily use (stage-0 Fledge); only additional-target backends remain. -->

| Const generics, HKT/GATs, specialization, variadic FFI | Post-M8 / rejected-for-now | No |

---

## Temporary bootstrap constraints (and when they lift)

Some restrictions below exist **only** because they made the stage-0 bootstrap tractable — not because they are the language we want. Each risks silently fossilizing into "design" once code and docs settle around it. They are listed here with the condition that should trigger revisiting them, so a bootstrap convenience is never mistaken for a decision.

| Constraint (bootstrap-only) | Why it exists (bootstrap convenience) | What unblocks removing it |
|---|---|---|
| **Default parameter values restricted to constant/literal expressions** | Arbitrary-expression defaults are filled caller-side; evaluating them mid-call would force ARC-cleanup ordering the earliest front end doesn't yet have. | The move/drop-flag elaboration pass that already sequences cleanup on the `try`/return paths — once it lands, defaults can be arbitrary expressions. |
| **Deferred zeroing `weak`** (bootstrap ships non-zeroing `unowned` only) | The trickiest runtime mechanism (a zeroing side-table) is kept out of stage-0; the compiler's own back-edges use **arena allocation + integer node IDs** instead of weak references, so it needs none. | Post-self-host runtime support for the zeroing-`weak` side table (Staging: M5); until then arena+IDs cover the compiler's cyclic structures. |
| **Fixed-arity POSIX / `Process::run` bindings; no variadic FFI** | Darwin AArch64 passes varargs on the stack; a general variadic-FFI marshaller is real work, and Kite formats natively rather than calling `printf(...)`. Fixed-arity `posix_spawn`/`pipe`/`read`/`write`/`waitpid`/`open`/`close`/`mmap` are all the toolchain driver needs. | An FFI layer that implements AArch64 varargs stack marshalling (Staging: variadic FFI is Post-M8/rejected-for-now) — only needed if a genuine C variadic entry point becomes unavoidable. |
| **Fixed-width, machine-honest integers pulled *into* the bootstrap subset** (`Int8..64`/`UInt8..64`/`ISize`/`USize`; `Int`=i32 default) | *Inverse* of a deferral: these were brought forward because the self-hosting compiler cannot bind libc or drive `as`/`ld` without exact-width and pointer-width integers (the FFI dependency). | The set itself is likely permanent; what should be *revisited* once FFI is no longer the forcing function is whether the **default** numeric surface (`Int`=i32) and the absence of any wider/arbitrary-precision default are the right long-term choice. *(Flagged: this row is more "settled by need" than temporary — see report.)* |
| **`panic = abort`, no unwinding, in bootstrap** | Stage-0 avoids the DWARF/EH landing-pad machinery; `deinit`/`defer` still run on normal and `try`-return paths, just not on panic. | `panic = unwind` is committed post-bootstrap (Open Decision 3; Staging: M7+) — running `Drop`/`defer` on panic needs the unwinder. |
| **Closures are non-escaping only in bootstrap** | The conservative escape checker keeps closures on the stack / inlined and off the retain-elision critical path; a lazy adapter chain must be consumed by a terminal in the same function. | Escaping/boxed closures + `inout`/`var`-writeback capture (Staging: M5), once the retain-elision optimizer and boxed-closure ABI exist. |