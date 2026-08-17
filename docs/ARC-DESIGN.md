# Kite ARC — Design & Implementation Plan

Kite's signature memory model is **ARC (automatic reference counting) + no GC**. This document is the
design and the staged plan.

**Status (2026-08-16):**
- ✅ **Step 0 — runtime primitives**: `__allocRC`/`__retain`/`__release`/`__refcount` at header `[obj-8]`.
- ✅ **Step 1 — universal headers**: every aggregate allocation (struct, enum variant, list header, closure,
  boxed double) funnels through `genAllocHdr` → every heap object is ref-countable. Field offsets unchanged.
  Verified: a plain `struct` reports `__refcount == 1`, retain→2, release→1.
- ✅ **Step 2 — recursive (deep) release for structs**: `__release` is type-directed. A struct with
  reference (struct-typed) fields dispatches to a generated `___rel_<T>(p)` routine that, on the last
  reference, releases each struct field (re-dispatching by that field's static type, so the whole graph is
  freed depth-first) then frees. Verified: releasing an outer struct drops its inner fields' refcounts.
- ⏳ **Step 3 — automatic retain/release insertion**: the remaining work; deliberately deferred as a
  **supervised** step (a mis-analysis would corrupt the self-hosting compiler — see below).

Enum-variant payloads, `List` elements, and generic (erased) fields are **not** recursively released yet
(no static payload/element type is tracked), and `String` fields are intentionally left shallow so a static
literal is never freed. These are safe leaks, documented per type.

## Object header

Every reference-counted heap object carries a **hidden refcount word** immediately *before* its data:

```
   malloc'd block:   [ refcount(8) | ...object data... ]
                                    ^
   object pointer  = base + 8  ──────┘        (so field offsets are UNCHANGED: field i at obj + 8*i)
   refcount word   = *(obj - 8)
```

Putting the refcount at `obj-8` means all existing field access (`obj + offset`) is unchanged, so ARC can
be introduced without touching struct/list/enum field codegen.

## Runtime primitives — IMPLEMENTED (codegen.kite genCall)

Tested end-to-end (`compiler/tests/programs/arc-refcount.kite`, `arc-free.kite`):
- `__allocRC(size)` → `malloc(size+8)`, refcount = 1 at `[base]`, returns `base+8`.
- `__retain(p)` → `*(p-8) += 1`, returns `p`.
- `__release(p)` → `*(p-8) -= 1`; if it reached 0, `free(p-8)`. **Currently SHALLOW** (frees the object but
  does not recursively release the references it holds — see step 2 below).
- `__refcount(p)` → `*(p-8)` (for tests/introspection).

These use only existing IR ops (`ILoadOff`/`IStoreOff`/`IAddImm`/`ISubImm`/`ICmp`/`IJmpCondL`/`ICallSym`), so
no backend change was needed, and both self-hosting fixpoints stay byte-identical.

## Remaining work (staged)

**Step 1 — route all allocations through the header path.** Today `__allocRC` is a *separate* path; the real
struct/list/enum/string/closure/boxed-float allocations still use bare `malloc` (and leak). Integrate the
header into `genStructNew`, `genVariantNew`, `genListNew`, `genConcat`/`genSubstr`/`genIntToStr`,
`genBoxDouble`, `genClosNew`, `genReadFile` (list *data* arrays stay header-less — they are internal, not
objects). Field offsets are unchanged, so this is mechanical; **verify both fixpoints after** (the compiler's
own objects will then carry headers — must still self-host byte-identically).

**Step 2 — per-type ref-field layout for recursive release.** `__release` on refcount→0 must release the
references the object holds, else nested objects leak. The compiler already knows each struct's field types
(`structFT`) and each enum variant's payload types; from these, emit for each type a **release routine** (or a
static layout bitmap of which fields are references vs primitives) so `__release` can recurse. Primitives
(Int/Bool/Char/Float-as-boxed?) are not released; references (structs/enums/lists/strings/closures) are.
Note Float is boxed here → a Float field IS a reference; decide boxing vs value for Float.

**Step 3 — automatic retain/release insertion (ownership analysis). THE REMAINING WORK — supervised.**
Why supervised and not done autonomously: auto-insertion rewrites the emitted code of *every* program,
**including the compiler itself**. The compiler stores AST nodes into lists and returns them everywhere, so a
single ownership mis-analysis (releasing a value that is still live) produces a use-after-free *inside the
compiler as it compiles itself* — silently corrupting the self-hosting fixpoint. This is exactly the crown
jewel we refuse to gamble unsupervised. It wants the IR-dataflow pass below plus incremental gating.
Rules of thumb:
- a freshly-allocated value is *owned* (refcount 1 from alloc) — no retain on bind;
- copying a reference (`val y = x`, storing into a field/list, capturing into a closure) → `retain`;
- a local reference is *released* at scope exit — **except** the one being returned (ownership transfers);
- field store `obj.f = v` → `retain(v)` then `release(old obj.f)`;
- call arguments: choose a convention — *borrow* (caller keeps ownership, callee doesn't release) is simplest
  and avoids retain/release churn at every call.
- optimization: elide retain/release pairs on a value's *last use* (move semantics); this is where an IR +
  dataflow pass pays off (see docs/ARCHITECTURE.md — ARC insertion is a natural IR pass).

**Step 4 — cycles.** Refcounting leaks reference cycles. Acceptable for v1; add `weak`/`unowned` references
(Kite design) later, or a cycle collector.

## Where it lives

- Runtime primitives + header: `codegen.kite` (target-independent — the header math is IR ops).
- Recursive-release routines: generated per type in `codegen.kite`.
- Insertion pass: best as an **IR-level pass** once the optimizer IR exists, or in `klower` as an AST pass
  (less precise). This is why the IR/optimizer and ARC are sequenced together in the roadmap.

## Kite value vs reference semantics

Design: `struct`/`enum` are value types, `class` is a reference type (ARC). In the current boxed model
everything is heap-allocated, so ARC can be applied uniformly (all boxed) as an interim; true value semantics
(copy structs, ARC only classes) is a later refinement that also reduces refcount traffic.
