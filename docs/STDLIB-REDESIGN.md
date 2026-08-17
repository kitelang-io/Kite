# Kite Standard Library & Compiler-Boundary Redesign

**Status:** design proposal (execute-against). **Invariant that governs everything:** the self-hosting fixpoint `kcc2 == kcc3` stays byte-identical at every step. **Governing method:** two tiers — a *bootstrap tier* the compiler self-hosts on (frozen, Int-word, leak-managed) and a *target tier* for user code (generic, ARC-managed, trait-participating) — that never share a name, so the target tier can be built additively without moving a byte in the compiler until a single deliberate, separately-gated flip.

---

## 1. Executive Summary — the current state on one page

Kite today has a **library that does not match its own documentation and a compiler fused to that library by four hand-maintained name tables.** Concretely:

- **No primitive tower.** There is exactly one integer type at runtime: the 64-bit machine word (`Int` = `i64`). `Bool`, `Char`, `Long`, `Double`, and the entire named set `Int8..Int64`/`UInt8..UInt64`/`ISize`/`USize` are either aliases of that word or names the checker *accepts but never enforces* — `compatPrimR` treats "any numeric ≈ any numeric" (`kcheck.kite:386`), so `Int8` and `UInt64` are interchangeable and unchecked. There is no fixed-width layer, no unsigned semantics (division is always `SDIV`, `>>` always arithmetic `ASR`, compares always signed), no overflow discipline, no width conversions, no `as` cast, and no zero-size `Unit`. Memory access exists at only two widths — 1 byte and 8 bytes. `Float` is a heap-boxed, ref-counted `f64` whose literals are parsed at *runtime* via `strtod`; mixed `1 + 2.0` is **unsound** (the int operand is dereferenced as a double-pointer). `Char` is a single source byte in a word (ASCII escapes only). The docs (`LANGUAGE-DESIGN.md:156-157`) describe `Int=i32`/`Long=i64`/`f32`/1-byte-`Bool`/32-bit-`Char`/zero-size-`Unit` and a full wrapping/checked/saturating tower — **none of which exists.**

- **Int-only, type-erased collections in two ARC regimes.** `List` (the `[..]` literal type) and `Map` (the `{..}` literal type) are reference-semantics classes over raw word buffers with hand-strided `*8` offsets; they are **type-erased to `Int`** and **leak by design** (no `deinit`; excluded from auto-ARC because element type is unknown and lists nest, risking UAF). A parallel, incompatible clean pair — `Vec`, `IntMap`, `Str` — *is* ARC-clean via `deinit` but has no literal or index sugar. `Map` is O(n) linear-scan parallel arrays; there is no hashing, no `Set`, no `TreeMap`, no iterator protocol (`for` is hardcoded to `listGet`/`listLen` over `List`), no bounds checking (OOB is UB), and no `Option`-returning access. `listOf`/`mapOf`/`setOf` are **checker-blessed phantoms** — whitelisted but defined nowhere (`setOf` even names a nonexistent `Set`). String is a NUL-terminated C byte-string scattered across three files that leaks on every `concat`/`substr`/`intToStr`, has O(n) length, a dead-ended one-way builder (`Str` has no `finish()`), and no `split`/`trim`/`replace`/`parseInt`/`indexOf`.

- **Compiler↔stdlib coupling by four drift-prone name tables.** The compiler hardcodes stdlib details in four places that must agree by hand: **`isBuiltin`** (`kcheck.kite:46-62`), **`builtinRetTag`** (`klower.kite:57-62`), **`typeNameOf` + the `genCall` intrinsic switch** (`codegen.kite:225-236, 710-754`), plus two copies of the container ARC-exemption (**`isBuiltinNominal`** `klower.kite:154` and **`isRelField`** `codegen.kite:686`). The checker never parses the prelude (`injectHelpers` runs only in lowering), so `isBuiltin` is a hand-maintained shadow of it — and it drifts (phantoms above; `Some/None/Ok/Err` whitelisted but their module isn't even in `prelude.conf`). The klower lowerers bake concrete library *names* (`list`, `List_push`, `mapNewM`, `__mapGetS`, `concat`) into `[..]`/`{..}`/`m[k]`/interpolation/`for-in`, and `lowerMap` even hardcodes Map's internal two-parallel-list *representation*. The prelude itself is cwd-relative and one malformed line from a null-deref segfault.

- **The genuine irreducible floor** is small: the `__`-prefixed intrinsics (raw memory, the 16-byte ARC/type-id header geometry, closures, `toInt`), plus `print`/`println` (which need static-type info + the Apple variadic ABI). Everything the four tables call "builtin" at layer 3 (`list`/`concat`/`mapNewM`/…) is *already* stdlib-bodied in `lib/`; only its *emission* is hardwired. That is the primary thing this redesign lifts out.

**The three load-bearing moves of this document:** (1) couple the compiler to **roles, not names** (a Rust-style lang-item registry) so the four tables collapse into one manifest; (2) get value-semantics containers from **monomorphized generics** (the C++/Rust template model) — one specialized body per concrete `Vec<T>`/`Map<K,V>`, **packed inline storage** by `sizeOf<T>()`, direct element ops, zero-cost from the start — layered over **CoW-over-ARC** (Swift) for value semantics (a per-element *witness table* was considered and rejected, kept only as a fallback); (3) match the *scalar/trait* ambition to the erased-generics reality — **one `Int`, tiny trait set, operators/iteration by convention** (Kotlin/Go fork) — while the collections tier is monomorphized, making **monomorphization + a comptime `sizeOf<T>()` an early keystone** (landing before the target collections, not deferred) that the bootstrap fixpoint never blocks on.

---

## 2. The Redesigned Base Library

Layering discipline (Rust's `core`/`alloc`/`std` lesson, mapped onto Kite's existing `lib/core` vs `lib/alloc`):

- **`core`** — no allocation, no OS. Primitive registry, trait *declarations*, non-allocating string/char primitives, iterator decls. Embeddable subset.
- **`alloc`** — heap types: `Vec`/`HashMap`/`TreeMap`/`Set`/`StrBuilder`, allocating string transforms, heap `Clone`/`Display` impls.
- **`std`** — I/O, args, panic funnel, process.

### 2a. Primitives & the full numeric tower

**Two non-negotiable axioms.**

- **A1 — `Int = i64 = the machine word.** `Long` is an alias of `Int`. We *overrule the docs'* `Int=i32`/`Long=i64` split: adopting it would reclassify every one of the compiler's 2000+ `Int` sites as `i32` and force a self-host-breaking audit. The whole tower is **additive over the fact that compiler sources stay 100% `Int`.**
- **A2 — registers are always full 64-bit words; width lives in the type** and bites at only three boundaries: (1) sized memory load/store, (2) narrowing cast, (3) the `wrapping_/checked_` op families. Everywhere else a `U16` computes in an X-register exactly like an `Int` (how LLVM lowers `i8`/`i16` too).

**The integer tower.**

| Type | Storage | Signed | Notes |
|---|---|---|---|
| `Int` (`Long`) | 8 B | signed | **canonical word** |
| `I8` `I16` `I32` `I64` | 1/2/4/8 B | signed | `I64` == `Int`; sub-word normalize on cast/wrap |
| `U8`(`Byte`) `U16` `U32` `U64` | 1/2/4/8 B | **unsigned** | UDIV / LSR / unsigned-compare |
| `ISize` / `USize` | 8 B | signed / unsigned | index & length type; == `Int` / `U64` today |

`I128`/`U128` are **reserved names, rejected with "not yet implemented"** (they need register pairs + carry lowering; nothing in the value proposition needs them). Only four axes distinguish types at the machine level: **storage size**, **load extension** (signed sign-extend / unsigned zero-extend), **signed-vs-unsigned op selection** (`SDIV`/`UDIV`, `ASR`/`LSR`, signed/unsigned condition codes), and **normalization width**. The whole backend delta is: add `UDIV`, `LSRV`, sized/extending 16- and 32-bit loads/stores, and add-with-carry / high-multiply for full-word overflow. **Unsigned compare needs no new encoding** — reuse `CMP`, feed `CSET` the unsigned condition codes (`hs/lo/hi/ls`). It is a codegen *selection*, not a backend addition.

**Non-integer scalars.**

- **`Bool`** — 1-byte in storage, 0/1 in registers. **Fix the `&&`≡`&` / `||`≡`|` conflation:** `&&`/`||` become short-circuit `Bool`-only branches; `&`/`|`/`^` become bitwise-integer-only and the checker rejects them on `Bool`. (Grep `compiler/**` first to confirm no `&` stands in for boolean-and before flipping the checker — low risk, must verify.)
- **`Char`** — 32-bit Unicode scalar, 4-byte storage, `\xNN`/`\u{...}` escapes. **Decoupled from the compiler's byte string:** the compiler's `charAt`/string ops stay byte-oriented (`byteAt(s): U8`); `Char` is produced only by an explicit library `decodeUtf8`. Swift's grapheme `String` is the cautionary tale — never make the primitive the compiler self-hosts on expensive.
- **`Byte`** = `U8` (alias) — the network/binary-buffer element.
- **`Double` = `f64`** canonical (the currently-boxed float). **`Float` = `f32` reserved** (needs S-registers + `fcvt`). Fix the checker/klower name disagreement (`Double` vs `Float`) by making `Double` canonical. **Ban silent Int/Float mixing** — require `i.toDouble()`. Two deferred follow-ups: unbox `Double` into a D-register value; add `f32`.
- **`Unit`** — a real **zero-size** lang item (0 bytes in layout, not passed, materializes nothing). Finally makes the docs true.
- **`Never`** (`Nothing`) — uninhabited bottom, subtype of every type; return of `panic`/`abort`/`todo`/`unreachable`, so `val x: Int = if (c) 1 else panic("")` checks.

**Literals.** Bare integer = `Int`, bare float = `Double`. Add suffixes (`42u16`, `1.5f`), radices (`0b`, `0o`, `0x`), digit separators (`1_000_000`), and float exponent (`1e9` — today `e` starts an identifier, a real lexer bug). **Bidirectional expected-type propagation:** `val x: U16 = 300` adopts `U16` and range-checks at compile time (`= 70000` is an error); a checker-only change, no runtime cost. Suffixed literals fold through the existing comptime interpreter.

**Overflow policy.** Default arithmetic **wraps at the type's width, deterministically** (Go's choice — the self-host-safe one: no trap machinery, fully reproducible bytes). On top, provide the **explicit method families** (Rust/Swift's highest-value portable idea): `wrappingAdd`/`checkedAdd` (→`Option`)/`saturatingAdd`/`overflowingAdd` (→`(v, didOverflow)`). Sub-word widths need *no* new intrinsic (compute wide, then mask/range-check); only full-word `u64`/`i64` need the flag intrinsics `__addOverflow`/`__mulOverflow`. Optional `&+`/`&-`/`&*` wrapping-operator sugar. Debug-mode overflow *trapping* is a **later, flag-gated** option — and must be OFF for the self-host build so the fixpoint is flag-independent.

**Conversions & bit ops.** **No implicit numeric conversion of any kind** (kills today's permissive `compatPrimR`). Three explicit mechanisms: (1) **`as`** — new keyword + cast node, truncating/reinterpreting (`x as U8` masks, `y as I64` sign-extends, `f as Int` = `fcvtzs`); bit-pattern reinterpret is a distinct `bitcast` intrinsic. (2) **`From`/`Into`** for lossless widening (`U8: Into<U16>`) — each impl is a concrete monomorphic function, expressible under erasure. (3) **`TryFrom` → `Option`** for narrowing that may fail. Bit ops get real width semantics: `&|^` mask to width; `<<` is `LSL` then normalize; `>>` picks `ASR` (signed) vs `LSR` (unsigned) — fixing today's always-arithmetic `>>` — plus explicit `>>>` logical-shift.

**Every numeric type has a library home.** Each scalar is a first-class *library* citizen, not compiler magic. A canonical module **owns its surface** — `lib/core/int.kite` (with `uint`/`float`/`bool`/`char` siblings, or a single `lib/core/num.kite`) defines that type's **methods** (`abs`/`min`/`max`/`pow`/`countOnes`/`toString`, plus the `wrapping_`/`checked_`/`saturating_` families), its **associated constants** (`Int::MAX`/`Int::MIN`/`Int::BITS`), the width **conversions**, and the **trait impls** (`Eq`/`Ord`/`Hash`/`Display`/`Add`…) — all written in Kite. This is exactly Rust's `i64`: hundreds of library methods + `i64::MAX` + `impl` blocks, none of it primitive-magic. "Wrap `Int`/`i64` into the stdlib" **means** giving it a library-defined surface — so a scalar is ordinary lib as far as its API goes; only its machine representation and the arithmetic/compare hot-path (§2b, §3d) stay in the compiler.

### 2b. Core trait layer

**Design axioms** (dictated by the compiler's two existing dispatch modes): (a) *static-by-tag* — `lowerBin` emits a direct `<Tag>_<method>` call for concrete receivers, primitives fall through to machine ops at zero cost; (b) *dynamic-by-type-id* — `__dyn_<Trait>_<m>(obj,…)` switches on the header type-id. Primitives carry type-id `−1` and are **dispatch-invisible**, so every trait usable on primitives needs the static path (the four scalar tags are hardcoded for `Eq`/`Ord`/`Hash`). **`@derive` is a hand-rolled monomorphizer:** it emits a concrete `<Type>_<method>` by structural recursion over known field types — the *trait layer is monomorphized* by exactly the structural-specialization move that §2d now generalizes to full value-generic monomorphization. This is the load-bearing trick.

**The library impl is the source of truth; the tag path is an optimization over it.** Each scalar's `Eq`/`Ord`/`Hash` — and its operator/`Display` impls — is *written in Kite* in its `lib/core` home (§2a); that library impl is the canonical definition. The hardcoded static-by-tag fast path is the compiler's **zero-cost inline** of that truth for the hot cases: `a + b`/`a == b`/`a < b` on a scalar still lower straight to `ADD`/`CMP`/condition codes, never through the library call. Generics, reflection, and the trait-object / `Display` / `Hash` paths use the library impl. Exactly Rust's split — `+` inlines, but `impl` blocks and `i64::MAX` are library.

The small set (Kotlin/Go minimalism, not Rust's dozens):

```kite
// core (no allocation)
trait PartialEq            { fun eq(self, other: Self): Bool }     // NaN-honest, not reflexive
trait Eq: PartialEq        { }                                     // marker: total
trait PartialOrd: PartialEq { fun partialCmp(self, other: Self): Int } // -2 = incomparable
trait Ord: Eq, PartialOrd   { fun cmp(self, other: Self): Int }    // -1/0/1 ; alias Comparable
trait Hash                 { fun hash(self): Int }                 // FNV/mix; HashMap enabler
trait Copy                 { }                                     // MARKER: bitwise-copy, no deinit, no ARC
trait Clone                { fun clone(self): Self }               // decl core; heap impls alloc
trait Default              { fun default(): Self }                 // no self -> static-by-expected-type
trait From                 { fun from(x: Int): Self }              // Into deferred (needs blanket impl)
trait Neg{fun neg(self):Self}  trait Not{fun not(self):Self}
trait BitAnd{...} BitOr BitXor Shl Shr                            // complete the operator family
trait Index    { fun index(self, k: Int): Int }                   // a[k]
trait IndexSet { fun indexSet(self, k: Int, v: Int) }             // a[k]=v
// alloc (impls allocate)
trait Display { fun show(self): String }                          // NOT auto-derivable, NOT in prelude
trait Debug   { fun debug(self): String }                         // auto-derivable
trait Iterator     { fun next(self): Option }                     // Some(word)/None, element erased
trait IntoIterator { fun iterator(self): Iterator }
```

Existing operator traits (`Add Sub Mul Div Rem`) stay; the rest complete the family with the same static-by-tag desugar. `!=`→`not(eq)`, `< <= > >=`→`cmp`/`partialCmp`, all firing **only when the left tag has an impl** so the compiler's own Int/String comparisons keep the machine-op / `strEq` path unchanged.

**`@derive` expansion** (new klower phase-2 pass, right after trait-default synthesis): for each `@derive(Tr)` on a struct/enum, synthesize a concrete `impl` by structural recursion over fields (`sFN`/`sFT`, `variantN`/`variantTys`), registered exactly like a hand impl. Auto-derivable: `Eq PartialEq Ord PartialOrd Hash Clone Default Debug Copy`. Never auto-derivable (semantic): `Display From Iterator` + operator traits (requesting them is a checker error). Well-formedness: a derive is rejected if any field type lacks the same trait. Enums derive over tag + payloads. `Option`/`Result` ship `@derive(Eq, Clone, Debug)`. Recommend flipping the `__dyn` fall-through from `return 0` (silent-wrong) to `__abort("no impl for type-id")`.

**Prelude policy** (minimal, curated): auto-inject operator traits + `Eq` + `Ord` + `Option`/`Result` only. `Display`/`Debug`/`From`/`Hash`/`Iterator` are opt-in imports.

### 2c. String & text

**Two tiers.** **T0 (bootstrap, frozen):** `String` stays a NUL-terminated UTF-8 byte buffer = one `Int` pointer, so it puns cleanly into word `List`/`Map` keys. **T1 (target):** `String` becomes a real ARC heap object — `class String(val len: Int, val data: Int)` with `deinit { __rawFree(self.data) }` — giving **O(1) length**, legal embedded NULs, and **an end to the leak regime** (ARC frees the buffer). It is still one pointer word as a value, so key-punning survives. Because String is immutable, sharing is always a pure refcount bump — **no CoW is ever needed for String.** `substr` in T1 returns an O(1) `StrView` (retains parent) with `.toOwned()` to detach.

**Char & iteration, tiered so the compiler never depends on the expensive path.** `Char` is `Int` in both tiers. T0: byte iteration (`s.bytes()`, O(1)/step — what the compiler self-hosts on). T1: `s.chars()` decodes UTF-8 → 32-bit scalars. Graphemes are a *deferred separate view*, never the primitive.

**One builder, `StrBuilder`** (kill `strbuf.kite`): doubling growth (exists), plus the **missing `finish()`** (seal to a real `String`) and `pushStr`/`pushChar`/`pushInt`. `+` and interpolation lower onto **one amortized `StrBuilder`** instead of O(n²) leaking `concat` chains, and interpolation calls `show(...)` (any `Display`), not hardcoded `intToStr` — so floats/bools/structs interpolate.

**Method surface split:** core (non-allocating queries — `len`/`byteAt`/`eq`/`compare`/`hashCode`/`startsWith`/`indexOf`/`contains`, plus `concat`/`intToStr` which interpolation needs); alloc (allocating transforms — `substr`/`split`/`join`/`trim`/`replace`/`toUpper`/`padStart`/`parseInt`→`Option`). **File layout:** `lib/core/string.kite` (primitive + builder + trait impls), `lib/core/char.kite` (T1 scalar helpers), `lib/alloc/string.kite` (transforms); delete `lib/alloc/string/strbuf.kite`. String implements `Display`/`Eq`/`Ord`(lexicographic unsigned-byte)/`Hash`(FNV-1a, 64-bit wrap)/`Add`/`Seq` — `Hash`+`Eq` are exactly what a hashed `Map`/`Set` needs for String keys. **Self-host safety:** the compiler keeps calling the concrete free functions (`strEq`/`strLen`/`concat`/`intToStr`); it never depends on trait dispatch for its own strings.

### 2d. Collections (Vec + Map trait/HashMap/TreeMap + Set family + iterator protocol; the RawList rename)

**The rename that frees the names:** `class List` → **`class IntBuf`**, `class Map` → **`class RawMap`** (and their free fns). The compiler's own sources and the `[..]`/`{..}` lowering point at `IntBuf`/`RawMap` — frozen — until the whole compiler is migrated and re-fixpointed; only then does a *separate* gated step flip the literals to the target tier.

**Monomorphization — the chosen generic mechanism (C++/Rust templates):** a generic container is *instantiated per concrete `T`*. The compiler generates a specialized body in which storage is **packed inline** by `sizeOf<T>()` stride, every element op (retain/release/clone/hash/eq/cmp/show, plus the arithmetic/compare hot paths) is emitted *directly* for `T`, and all calls are direct — **zero-cost, the same code a programmer would hand-write per type.** `Vec<Point>` stores `Point`s contiguously, *not* pointers; scalars sit at their true width. This is the escape from the erasure blocker: the static type at each instantiation site fully determines layout and element behavior, so nothing is punned through a bare word.

*Considered and rejected — the per-element witness table (dictionary passing):* a `Witness` struct of function pointers, chosen for `T` at construction and dispatched through at every element op, would deliver generic element-ARC *without* monomorphization — but it forces every `T` into one machine word (scalars inline, everything else an ARC pointer, so `Vec<Point>` would hold pointers) and pays an indirect call per element op. We chose monomorphization for zero-cost inline-storage generics; the witness scheme survives only as a **fallback** if per-instantiation code size proves too costly.

**What monomorphization buys:** inline storage of differently-sized `T` (packed by `sizeOf<T>()`), direct specialized element ops, and generic element-ARC — deep-retain-on-copy (mirror of `___rel_<T>`) / deep-release-on-scope-exit emitted per instantiation — one specialized body per `(container, T)` pair. **The cost we accept, deliberately:** each instantiation is a separate code body (code-size growth), and the compiler feature is larger up-front, so the target collections land later than a witness scheme would allow. Container control flow, buffer growth, and CoW uniqueness are the shared skeleton the template specializes.

**Tiny trait tower** (Kotlin/Go fork): `Iterator`/`Iterable`/`Collection`/`Indexed`/`MutIndexed` — no associated-type `RandomAccessCollection` chain; this is a deliberate scalar/trait-layer minimalism, kept even though monomorphization is now on tap. **`for x in xs` is two-mode:** if the static type has `get`/`size` → **index loop** (byte-identical to today's `lowerForEach`, so the compiler's own loops don't change); else → **iterator loop** via dynamic-dispatched `next()`. `a[i]`/`a[i]=v`/`m[k]` become **operator-by-convention** — `get(self,i)`/`set(self,i,v)` mangled on the receiver, replacing the hardcoded switch (adopted incrementally: keep hardwired String/Map/List paths as default, consult convention only for other tags).

**`Vec<T>` — value semantics via CoW-over-ARC** (Swift's pattern, riding the refcount header Kite already has). The buffer is a distinct ARC object (`class RawBuf`) whose refcount is the uniqueness signal; the handle is a value struct. Mutators call `ensureUnique` (copy the buffer if `__refcount(buf) > 1`) before writing, retain elements via the instantiation's specialized retain, and **bounds-check with `panic`** (today's raw ops read arbitrary heap). Access is Option-returning where empty is valid (`pop`/`first`/`last`/`indexOf` → `Option`; `get(i)` panics on OOB), plus `getUnchecked` for hot compiler paths. `Array<T>` (fixed `len`, value+CoW) and `Deque<T>` (ring buffer, O(1) both ends) follow the same shape.

**Maps.** A `Map` **trait** (`size`/`has`/`get`→`Option`/`getOr`/`set`/`remove`/`keys`/`values`/`entries`/`iterator`) implemented by two concrete maps. **`HashMap<K,V>` — insertion-ordered by construction** (open-addressing bucket index + a parallel insertion-ordered entry vector; iteration walks the entries, so jq object round-trip preserves key order for free). Keys hash via the key type's `Hash` impl, **specialized per instantiation** from the concrete `K` — direct calls, no by-type-id dynamic dispatch and no witness. `get`→`Option` (miss = `None`, ending the silent `0`). **`TreeMap<K,V>`** — balanced BST (LLRB) ordered by the specialized `cmp`, in-order iteration = sorted, plus `floor`/`ceil`. **Sets:** `HashSet<T>` = `HashMap<T,Unit>`, `TreeSet<T>` = `TreeMap<T,Unit>` — thin wrappers, so `Hash`/`Ord` and Option semantics come free. This makes `setOf`/`listOf`/`mapOf` **real** (today phantoms).

**Compiler additions (all gated):** comptime `sizeOf<T>()`; template instantiation (one specialized body per concrete `Vec<T>`/`Map<K,V>` use); `mut self` value-receiver write-back; deep-retain-on-copy (mirror of `___rel_<T>`) + deep-release-on-scope-exit, emitted per instantiation. These dissolve the two historical blockers — *list-of-list UAF* (the specialized body knows its element type exactly; `ensureUnique` clones before aliased mutation) and *bare-Int-vs-pointer ambiguity* (resolved at instantiation, where the element type is fully known).

---

## 3. The Compiler–Stdlib Decoupling Design

**Thesis:** the compiler's only irreducible coupling should be a **small versioned intrinsic floor** plus a **role registry (lang-item table)** that maps compiler concepts (`add`, `index-get`, `list.new`, `string-type`, `release`) to library symbols *by role, not by name*. The four drift-prone tables collapse into (a) intrinsics resolved structurally and (b) one data manifest read by checker, lowerer, and codegen alike. This is a refactor of existing name-lists into a keyed table — **no new runtime semantics**, which is what keeps `kcc2==kcc3` safe.

### 3a. The intrinsic floor (the only names lowered to inline machine code)

An intrinsic earns its place *only* if it (a) needs a machine instruction with no Kite spelling, (b) needs the ARC header geometry, or (c) needs static-type/ABI knowledge at the call site.

- **Raw memory:** `__rawAlloc/__rawRealloc/__rawFree`, `__rawLoad/__rawStore` (8-byte), `__rawLoadByte/__rawStoreByte`. **Reserved for the width tower (named now to fix the ABI):** `__rawLoad16/__rawStore16`, `__rawLoad32/__rawStore32`.
- **ARC + header:** `__allocRC(size,typeId)` (the `genAllocHdr` funnel; refcount@`[obj-16]`, type-id@`[obj-8]`), `__retain`, `__release`, `__refcount`, `__decRefcount`, `__freeObj`, `__typeId`. **Reserved:** `__isUnique(obj)` (refcount==1 test) to enable CoW.
- **Control/diag:** `__abort`; `__argv(argv,i)`.
- **Closures:** `__funcAddr`, `__closNew`, `__closGet`, `__closCall`.
- **Scalar conversion:** `toInt(float)`; **new `toFloat(int)`** so mixed int/float stops being unsound.
- **Formatted output (must stay intrinsic):** `print`/`println`/`printF`/`printlnF` — need static-type `%s`/`%ld`/`%g` selection + the Apple variadic ABI; format bytes stay in the backend `__cstring`.

**Everything else leaves the floor:** `listNew/listPush/listGet/…`, `concat/substr/intToStr/strLen/charAt/strEq`, `mapNewM/__mapGetS/…`, `Some/None/Ok/Err`, `assert/panic/todo/unreachable`, and the phantoms `listOf/mapOf/setOf/string/unit/it` (define or delete). File I/O (`readFile/writeFile/fopenW/fputByte/fcloseF`) is kept as a **second, explicitly-labelled "libc-shim" intrinsic group** — honest about being a stopgap until an `@extern` FFI exists (§4).

### 3b. Kill `isBuiltin`

Root cause: the checker's resolver is fed only user source; `injectHelpers` runs solely in lowering. Fix: factor `preludeConfPaths`/`collectDecl` into a phase-agnostic **`preludeSigs()`** returning declared top-level names, and **seed the checker's globals with it** before resolving. `isBuiltin` then shrinks to exactly the §3a floor names, read from the *same manifest* the lowerer uses — one source of truth. Phantom cleanup falls out for free (unresolvable unless a prelude module defines them). **Self-host safety:** seeding from the same modules can only *add* resolvable names; a name the compiler used that lived *only* in `isBuiltin` and was defined nowhere now errors — exactly the drift we want surfaced, fixed by *defining* the symbol, not re-whitelisting.

### 3c. The literal / for-in binding protocol (lang-item roles)

Replace baked names in `lowerList`/`lowerMap`/`lowerIndex`/`lowerForEach`/`lowerIndexStore`/`interpPiece` with a **role table** populated from the prelude via `@lang("…")` annotations (the `annos` machinery already threads through `collectDecl`):

| Surface | Role key | Default symbol |
|---|---|---|
| `[e0,…]` | `list.new` / `list.push` | `list` / `List_push` |
| `xs[i]` / `xs[i]=v` (List) | `list.index-get` / `list.index-set` | `listGet` / `listSet` |
| `for x in xs` | `seq.len` / `seq.get` | `listLen` / `listGet` |
| `{k:v,…}` | `map.new` / `map.put` | `mapNewM` / `__mapSetS` (dedup) |
| `m[k]` / `m[k]=v` | `map.index-get/set(S/I)` | `__mapGetS/I` / `__mapSetS/I` |
| `s[i]` (String) | `string.index-get` | `charAt` |
| `"…$x…"` | `string.concat` / `string.show` | `concat` / `show` |
| `a+b`, `a==b`, `a<b` | `op.add` / `op.eq` / `op.cmp` | mangled method via `opMethodName` |

Recommend the **convention-by-name (Kotlin) binding**, not trait-binding: roles map to method/function names looked up in the manifest — cheapest, matches Kite's UFCS, stdlib swappable by editing the manifest. **`lowerMap` must stop touching `.keys`/`.vals`** (it calls only `map.new`/`map.put`), so `Map` can become hashed later without a compiler change. `for-in` binds to `seq.len`/`seq.get` (Go/Kotlin fork) so Vec/Str/String-chars opt in by providing two symbols — no associated-type protocol.

### 3d. Minimized compiler-known types

**Must stay structural:** the 16-byte header geometry + `__allocRC` funnel; struct/enum layout + field offsets + the type-id=`structIdx` dispatch table; `Bool` for branching (one reserved name); `String` recognized nominally *only* for `%s`-vs-`%ld` print selection (its representation is pure library). **Becomes ordinary lib types:** `List`/`Map`/`Vec`/`IntMap`/`Str`/`Option`/`Result` — **and the numeric scalars' *surface*** (their methods, constants, conversions, and trait impls; §2a). Once each scalar's surface is library-defined, the compiler's knowledge of a primitive shrinks to exactly three things — the machine representation (the `i64` word, sized loads), the arithmetic/compare hot-path lowering, and `Bool` for branching; everything else about a scalar is ordinary library. So "wrap `Int` into the stdlib" points the **same** direction as "fully decouple the compiler from the stdlib," not against it. **Unify the two ARC-exemption copies** (`isBuiltinNominal` + `isRelField`) into one declared **`@arc(manual)`** attribute on the type, read by both phases. The correct long-term fix is CoW-over-ARC via the reserved `__isUnique` intrinsic — a *library* change that retires `@arc(manual)`, landing after decoupling.

### 3e. Post-OCaml bootstrap contract

`bootstrap/kite-seed` (the self-built signed arm64 binary) is the **sole** bootstrap. **Reseed protocol:** seed compiles `compiler/` → `kc2`; `kc2` compiles `compiler/` → `kc3`; assert `kc2==kc3` byte-identical; promote `kite-seed := kc3`, version-tagged with the compiler commit (auditable, reversible — keep the prior seed to bisect a break). **Install-relative prelude (kill cwd fragility):** resolve the manifest and `lib/` modules from a root discovered at runtime — `KITE_HOME`, else the executable's own directory walked to a `lib/` marker, else a compiled-in prefix; `impExtractPath` gains a base-dir parameter. **Every prelude `readFile` null-checks** and emits a real diagnostic (closing the documented segfault class). **Oracle:** the OCaml *frontend* (Fledge) is retired to its own repo (`kitelang-io/fledge`); its parser/checker output is now captured as committed golden snapshots (`compiler/tests/{parser,check}/golden/`) that the harnesses diff against kcc — no live OCaml in the loop. Codegen's oracle is the fixpoint + a golden-binary stdout corpus. Regenerate a golden deliberately when adding syntax or checks; Fledge remains a standalone, independent frontend oracle to regenerate against.

---

## 4. What Is Missing / To Add

- **Error handling + `?`.** `Option`/`Result`/`Some/None/Ok/Err` exist but `kite::core::option` isn't in `prelude.conf` (add it). Add a **`?` postfix operator**, pure klower desugar: `e?` → `when(e){ Ok(v) -> v; Err(x) -> return Err(x) }` (and the `Option` analog), with a checker rule that the enclosing fn returns a matching `Result`/`Option`. No new intrinsic.
- **I/O beyond readFile/writeFile.** The real fix is a **minimal libc FFI** — an `@extern("fread") fun cFread(...)` decl form — so stdin/buffered I/O/args become *library* over declared externals. Add `stdin()` line reader, buffered `Reader`/`Writer` over `StrBuilder`, and `args() -> Vec<String>` (a library loop over `__argv`). Until FFI lands, add exactly the missing floor intrinsics (`stdinByte`, `stdoutFlush`), marked stopgap.
- **panic / assert / bounds-checks with location.** These leave the floor and become library over `__abort`, but the compiler must inject `file:line` at the call site: klower rewrites `assert(c)` → `if (!c) { __panicAt("<file>:<line>", "assertion failed") }` and `panic(msg)` → `__panicAt("<file>:<line>", msg)`, where `__panicAt(loc,msg)` is a library fn (prints via `eprintln`, calls `__abort`). `todo`/`unreachable` desugar the same. Container `get`/`set` bounds-check and `panic` (today OOB is UB).
- **Iterator-driven `for-in`** (the cheap Go/Kotlin fork) via `seq.len`/`seq.get` roles — immediately extends `for` beyond `List`.
- **Deep-research extras:** the overflow-method-family (portable without a width tower); `@repr`/newtypes and typed `RawPtr<T>`/`CStr` for FFI (deferred); byte-order/`bswap` helpers; string interning via comptime literal dedup (cheap win).

---

## 5. Phased Migration Plan (never breaks `kcc2==kcc3`)

**Hard prerequisites, called out:** the target-tier generic collections are **monomorphized with packed inline storage**, so **monomorphization + a comptime `sizeOf<T>()` is now an early keystone phase** that must land *before* the collections phase — not a deferred optimization. Consequences: (i) a packed `Vec<U16>` strides by `sizeOf<T>()` and stores elements inline; the interim before the keystone is the *non-generic concrete* packed arrays (`U16Array`) of the sized-memory phase. (ii) `HashMap<K,V>` specializes its hash/eq per instantiation from the concrete key type — direct calls, no by-type-id dynamic dispatch and no witness. (iii) Generic element-ARC (deep-retain-on-copy / deep-release-on-scope-exit) is emitted per instantiation inside the monomorphized body. *Witness / dictionary-passing* was the earlier plan; it is now the considered-and-rejected alternative, retained only as a fallback if per-instantiation code size proves too costly.

Each phase is independently gated: full test suite + parser/checker differentials + `kcc2==kcc3` (and `kcc2==kcc3` for the integrated compiler).

| Phase | Work | Prereq | Tier | Risk / Effort |
|---|---|---|---|---|
| **0. Decouple** | `preludeSigs()`; seed the checker; shrink `isBuiltin` to the floor; define/delete phantoms; add `kite::core::option` to prelude; role table + convert the six lowerers (lowerMap stops touching `.keys/.vals`); unify ARC-exemption into `@arc(manual)`. | none | bootstrap | **Low risk / med effort.** Refactor of name-lists; surfaces drift as errors to fix by defining symbols. Highest leverage. |
| **1. Numeric checker layer** | Primitive registry; literal suffixes/radices/exponent; `Never`/`Unit`-as-real; tighten `compatPrimR` to "same type or explicit conversion". No new codegen. | Phase 0 | bootstrap-safe (compiler is all `Int`) | **Low / low.** |
| **2. Sized memory + packed arrays** | `__load/store{8,16,32}` + signed forms; `U8Array`/`U16Array`/`U32Array` (concrete, non-generic) in `alloc`. | Phase 1 | target | **Med / med.** Delivers the user's `uint16` arrays. |
| **3. Unsigned + casts + overflow** | `UDIV`/`LSR`/unsigned cond-codes; `U8..U64` wired; `as`; `From/Into/TryFrom`; overflow method families; `toFloat` (fix mixed int/float). | Phase 2 | target | **Med / med.** Real unsigned semantics. |
| **4. Traits + derive** | `Eq/Ord` decls + static desugar + `@derive`; then `Clone/Copy/Default/Debug`; then `Hash`; `__dyn` fall-through → `__abort`. | Phase 0 | target | **Med / med-high.** Derive = phase-2 klower pass. |
| **5. String T0 refactor** | `StrBuilder`+`finish()`; `+`/interpolation onto one builder; core/alloc split; String trait impls; interpolation calls `show`. No representation/codegen change. | Phase 4 | bootstrap-safe | **Low / med.** Kills O(n²) + per-interpolation leaks. |
| **6. Monomorphization keystone** | Comptime `sizeOf<T>()`; template instantiation (one specialized body per concrete `Vec<T>`/`Map<K,V>` use); packed inline element storage by `sizeOf<T>()` stride; direct, non-erased element ops. The keystone the target collections build on. | Phases 1, 4 | target (bootstrap frozen) | **High / high.** New compiler capability; the biggest single addition, but it unlocks zero-cost inline-storage generics. |
| **7. Collections target tier** | Real monomorphized `Vec<T>` (CoW value semantics, **packed inline storage**, direct element ops) + `Array`/`Deque`; `HashMap<K,V>`(insertion-ordered, hash/eq specialized per instantiation)/`TreeMap<K,V>`; `HashSet`/`TreeSet`; `mut self` write-back; deep-retain/deep-release per instantiation; bounds-checks; Option access. Rename `List`→`IntBuf`, `Map`→`RawMap` (compiler stays on them). *(Witness/dictionary-passing was the rejected fallback.)* | Phases 6, 4, 0 | target (bootstrap frozen) | **High / high.** The big one; compiler untouched until the flip. |
| **8. Literal flip + `?` + panic loc + for-in** | Point `[..]`/`{..}`/`m[k]` at the target tier per the static element type; `?` operator; `__panicAt(loc,msg)`; `for-in` via `seq.len`/`seq.get`. | Phase 7 | target (one gated flip) | **Med / med.** Isolated commit with its own fixpoint check. |
| **9. String T1** | `class String(len,data)` + `deinit`; literal emission boxes `{len,data}`; `char.kite`/UTF-8 + `\u{}`/`\xNN`; `substr`→`StrView`. | Phase 8 | target (behind flag) | **Med-high / med.** Ends the String leak; touches codegen, goes last. |
| **10. Deferred** | `f32`, unboxed `Double`, `I128/U128`, CoW-over-ARC via `__isUnique` (retires `@arc(manual)`), libc `@extern` FFI, debug overflow-trap flag. | — | target | **Varies.** None block earlier phases. |

**The single invariant across all of it:** the compiler's own source stays 100% `Int` (the word) and stays on `IntBuf`/`RawMap` + concrete free functions. As long as that holds, every phase is additive and the fixpoint is untouched.

---

## 6. Locked Decisions

Every question this document opened is now resolved; the choices below are the design of record.

1. **Generic-collection strategy — RESOLVED: monomorphization / template-first** (overturns the earlier witness-first recommendation). Real `Vec<T>`/`Map<K,V>` are monomorphized — one specialized body per concrete instantiation, storage **packed inline** by `sizeOf<T>()` stride (`Vec<Point>` stores `Point`s contiguously, not pointers), element ops inlined, calls direct — zero-cost from the start (the C++/Rust template model). This makes **monomorphization + a comptime `sizeOf<T>()` an early keystone** that lands *before* the target-tier collections, not a deferred optimization. Rationale: the user chose zero-cost inline-storage generics over the smaller witness feature, accepting the larger up-front compiler work (so the target collections land later) and a separate code body per instantiation (code-size). *Witness / dictionary-passing* is the considered-and-rejected alternative — kept only as a possible fallback if monomorphization proves too costly.
2. **Bootstrap-type rename — RESOLVED: `List → IntBuf`, `Map → RawMap`.** The raw Int-buffer classes get names that say what they are, freeing `List`/`Map` for the target-tier value-semantics CoW types. Rationale: an unambiguous rename applied across compiler sources + free fns before the collections phase.
3. **Unsigned / fixed-width scope (first round) — RESOLVED: `U8`/`U16`/`U32`/`U64` + sized memory.** Ships fixed-width load/store (delivering the requested `uint16`-style arrays) and real unsigned semantics (UDIV/LSR/unsigned condition codes); `I128`/`U128` reserved, `f32` deferred. Rationale: covers the explicit width ask without register-pair or S-register work.
4. **Operator / index / literal binding — RESOLVED: name-convention (Kotlin-style), not operator traits.** Roles bind to method *names* via the manifest (`a+b → add`, `xs[i] → get`). Rationale: cheapest, matches Kite's UFCS, stdlib swappable by editing the manifest — confirms the §3c role-table recommendation.
5. **Integer-literal default — RESOLVED: bare int = `Int`, bare float = `Double`, with expected-type adoption.** `val x: U16 = 300` adopts `U16` and range-checks at compile time (`= 70000` errors). Rationale: ergonomic and checker-only, no runtime cost.
6. **Overflow default — RESOLVED: silent wrap-by-width + explicit `checked_`/`saturating_`/`wrapping_` families.** Rationale: deterministic and self-host-safe (no trap machinery); debug-mode overflow trapping is deferred and flag-gated, and must be off for the self-host build so the fixpoint is flag-independent.
7. **List value semantics — RESOLVED (user-confirmed): CoW value type.** `Vec<T>` = value semantics via CoW-over-ARC — the fix for the aliasing UAF/leak hazard. Rationale: needs `mut self` + deep-retain + the reserved `__isUnique` intrinsic, and the user confirmed the appetite for that compiler work.
8. **OCaml oracle — SETTLED: Fledge retired.** Extracted to its own repo (`kitelang-io/fledge`); the parser/checker regression net is now committed golden snapshots (`compiler/tests/{parser,check}/golden/`) diffed against kcc — no live OCaml in the loop. Fledge stays available as a standalone frontend oracle to regenerate goldens against.
9. **String T1 timing — RESOLVED: last (Phase 9, flag-gated).** It ends the String leak but touches codegen (literal emission), so it stays at the end where the fixpoint risk is isolated behind a flag.
