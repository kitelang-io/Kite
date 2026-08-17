# Kite — Code Conventions

Kite is **module-oriented** (like Rust/Go), not class-oriented (like Java). These conventions keep the
standard library and user code idiomatic and consistent.

## 1. A file is a module, not a class

Do **not** adopt "one file = one class." A `.kite` file is a **module** (a namespace) that may hold
top-level functions *and* types together. Forcing every function into a class fights Kite's design
(`struct`/`enum` are value types; not everything is a `class`) and loses the ergonomics of top-level
functions.

Note this is also Kotlin's *real* practice: Kotlin added top-level functions precisely to escape Java's
one-class-per-file rule. Utility functions live at the top level; classes are for stateful/reference things.

## 2. Organize a file around one cohesive concept

A module usually centers on a **primary type + its operations**, and is named after it:

```
lib/alloc/collections/vec.kite   → the Vec type + vecNew factory
lib/alloc/string/strbuf.kite     → the Str type + strNew/strFrom
lib/core/math.kite               → integer math (a cohesive group of top-level functions, no type)
```

A module with only related free functions (e.g. `math`) is perfectly fine — cohesion matters, not "a class."

## 3. Operations on a type are METHODS; utilities are top-level functions

If a function's first job is to act on a value of type `T`, make it a **method** on `T` (in the class/struct
body or an `impl` block), called `v.op(...)`. Reserve top-level functions for factories and utilities.

```kite
class Vec(var n: Int, var cap: Int, var data: Int) {
  fun push(self, x: Int): Int { ... }     // v.push(x)
  fun get(self, i: Int): Int  { ... }     // v.get(i)   (or v[i])
  fun len(self): Int          { ... }     // v.len()
  deinit { __rawFree(self.data) }
}
fun vecNew(): Vec { return Vec(0, 4, __rawAlloc(4 * 8)) }   // factory: a top-level function
```

Method calls resolve by the receiver's type (`v.push(x)` → `Vec_push(v, x)`), so `Vec.get` and `IntMap.get`
never collide. This matches the built-in nominal methods (`xs.push(x)`, `s.len()`). Method names may reuse a
field name (`len()` method vs a `n` field is clearer than a `len` field + `len()` method — prefer distinct
field names).

## 4. Packages: three top-level, nest the rest

The `kite` standard library has exactly **three** top-level packages — `kite::core`, `kite::alloc`,
`kite::std` — and everything else nests under them (`kite::alloc::collections::vec`, `kite::std::io`), never
as a new top-level sibling. A package is a `.kite` file whose same-name directory holds its sub-modules
(Rust-2018 style: `lib/alloc/collections.kite` + `lib/alloc/collections/`).

Layer by capability: `core` = depends only on compiler intrinsics (no *library* dependency), `alloc` =
builds library abstractions over the allocator, `std` = needs the OS. Import the lowest layer you need.
Layer by what a module *needs*, not by which mechanism it uses: owning a heap allocation is an `alloc`
concern even when built on the raw-memory intrinsics. So the language-primitive `List`/`Map` that backs
`[..]`/`{..}` lives at `kite::alloc::collections::list` — a sibling of the `vec`/`map` containers, not in
`core`. The richer ARC'd `Vec` is a higher-level library abstraction in the same neighborhood.

**Syntax-sugar landing points live WITH their type — there is no separate "sugar" package.** This is
Kotlin's model: an operator/convention method (`a[i]`→`get`, `1..b`→`rangeTo`) is a **member on its
receiver type**, not a symbol in some sugar library. So Kite's desugar targets sit next to the type they
belong to: `xs.push(x)`→`List_push`, `m.size()`→`Map_size`, and the `[..]`/`{..}` constructors
`list()`/`map()` all live in `kite::alloc::collections::list` (with List/Map); `s.charAt(i)`→
`String_charAt` lives in `kite::core::string` (with the built-in String). The `[..]`/`{..}` constructors
are top-level functions, exactly like Kotlin's `listOf()`/`mapOf()` reached via default imports.

The default prelude (auto-included into every program) is **configuration**, listed in
`compiler/prelude.conf` — a list of default-imported stdlib modules, Kotlin-style. The compiler holds no
prelude code and is not coupled to lib/.

## 5. Visibility: `pub import` re-exports; plain `import` is private

Name visibility follows `pub import` edges (see docs/ARCHITECTURE.md). A package root **explicitly**
`pub import`s each sub-module it wants to re-export — this is manual (Rust's `pub mod`), so a sub-module can
stay private (a plain `import`, or simply not re-exported). A dependency a module needs only internally is a
plain `import` (e.g. `collections` privately `import`s `core::option` for the `Option` it returns — that does
not leak `optGetOr` to `import kite::alloc`).
