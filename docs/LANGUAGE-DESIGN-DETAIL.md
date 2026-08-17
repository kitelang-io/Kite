# Kite Language Design — Implementation Supplement (Areas 1–4, Reconciled)

This supplement merges the four deepened area specs, resolves every blocker/major raised by the integration and bootstrap-feasibility critiques, and fixes definite cross-cutting calls (naming, staging, ownership spelling) so the four areas can be implemented against one another and against the stage-0 (OCaml + hand-written AArch64) bootstrap. "B" = bootstrap subset; "M5+" = deferred.

---

## Pattern matching & when

`when` is Kite's single exhaustive, expression-oriented multi-way branch, in two shapes: subject form `when (subject) { pattern [if guard] -> body }` and subject-less `when { condition -> body }`. Arms are ATI-terminated (one per physical line), first-match, no fallthrough.

### Grammar (final)

```
WhenExpr    := "when" ( "(" Subject ")" )? "{" Arm+ "}"
Subject     := ( "val" Ident "=" )? "consuming"? Expr
Arm         := ArmLHS "->" ArmBody
ArmLHS      := "else"
             | PatternList ( "if" Expr )?     // subject form
             | Expr                           // subject-LESS form: boolean condition
PatternList := Pattern ( "|" Pattern )*       // or-pattern; alternatives bind identical names+types
Pattern     := "_"
             | Literal                        // 42 | "s" | true | 'c'
             | lowerIdent                     // fresh binding (lowercase-initial)
             | UpperIdent | Path              // unit variant / const  (None, Color::Red)
             | Ctor "(" ( PosArgs | RecordArgs ) ")"
             | "is" Type | "!is" Type         // B: enum/Option/Result tag only (see call)
             | "in" RangeOrOrd | "!in" RangeOrOrd
Ctor        := UpperIdent | Path
PosArgs     := ( Pattern ( "," Pattern )* )?
RecordArgs  := ( RecordField ( "," RecordField )* ( "," ".." )? ) | ".."
RecordField := Ident ( "=" Pattern )?         // punning, or rename via '='
RangeOrOrd  := RangeExpr | OrdExpr            // Ord/range membership in B
ArmBody     := Expr | Block
```

### Resolved calls

- **`is`/`!is` in B is tag discrimination only.** `is Circle` over a *class* subject needs runtime type descriptors — the `dyn`/descriptor machinery deferred to M5. In B, `is`/`!is` narrows **enum variants and `Option`/`Result`** only (the tag already exists). The self-hosting compiler models its AST/IR/types as **enums**, so `when (val n = node) { is Leaf -> …; is Branch -> … }` is written with enum variants, not a class hierarchy. Class-hierarchy / trait-object `is` is M5. *(Rejected: descriptor-based class `is` in B — requires the deferred type descriptor.)*
- **No tuples, no `(k,v)` for-headers in B.** `enumerate`/`zip`/`Map.entries` yield the named struct `Pair<USize, T>(val first, val second)`; consume via field access (`p.first`/`p.second`), not `for (k, v)`. Index type is uniformly **`USize`**. *(Rejected: lightweight tuple + irrefutable for-header destructuring in B — Area-1 no-tuples rule wins; both land at M5.)*
- **Variant patterns never use `is`.** Match `Some(v)`, `None`, `Ok(v)`, `Err(e)` as constructor patterns. `is Some(v)` is ungrammatical.
- **Unit arm body** is the empty block `{}` (yields the prelude value `unit`); never `()` (which would read as a nonexistent empty tuple).
- **`Range<Char>` in B:** constructing `'a'..'z'` and testing **Ord membership** (`in`) is B; *iterating* a Char range is M5. Membership lowers to two `Ord` comparisons and never touches the `Iterator` impl.
- **Binding modes (ARC):** matching **borrows** the subject → zero refcount. Copy payloads bit-copy; non-Copy value bindings borrow within the arm; `class`/ARC bindings retain **only on escape**. `when (consuming x)` moves payloads out (requires the stage-0 move/drop-flag elaboration pass, prioritized ahead of the stdlib). B uses naive scope-end release; the retain-elision optimizer is M5.
- **Exhaustiveness** enforced for `enum` and `Bool` when the value is used; open types (`Int`, `String`) require `else`. Guarded arms never contribute coverage. Provably-unreachable arms are a hard compile error.
- **LUB typing:** whole `when` = join of arm types; `Nothing` (diverging arms) absorbed; `T` and `T?` join to `T?`. `dyn`-boxing of heterogeneous arms is contextual-only and M5.
- **Literal patterns** desugar to `Eq`; B lowers to sequential equality tests (no jump table).

### Examples

```kite
when (expr) {                                 // enum, nested, guard (compiler-style)
    Lit(n)                         -> n
    Neg(Lit(n))                    -> -n
    Bin(op, l, r) if op == Op::Add -> eval(l) + eval(r)
    Bin(_, l, r)                   -> combine(eval(l), eval(r))
}

when (cache.get(k)) { Some(v) -> use(v); None -> reload(k) }   // Some/None are variant patterns

when (val n = node) { is Leaf -> n.value; is Branch -> n.left.sum() + n.right.sum() }  // enum tag narrow

when (p) {                                    // struct: pun, rename, literal, rest
    Point(x = 0, y = 0) -> "origin"
    Point(x = 0, y)     -> "on y-axis at ${y}"
    Point(x, ..)        -> "x = ${x}"
}

when (c) { in '0'..'9' -> Digit; in 'a'..'z' | in 'A'..'Z' -> Alpha; else -> Other }  // Ord membership

val tier = when { score >= 90 -> "A"; score >= 80 -> "B"; else -> "F" }   // subject-less
```

---

## Traits, generics & derives

Nominal traits + parametric generics; static dispatch by monomorphization (a type param is a comptime `Type`; monomorphization **is** comptime specialization). `dyn Trait` is opt-in and M5.

### Grammar (final)

```
TraitDecl   := "trait" Ident [GenericParams] [":" BoundList] [WhereClause] "{" TraitMember* "}"
TraitMember := AssocType | MethodSig | DefaultMethod        // AssocConst: M5
AssocType   := "type" Ident [":" BoundList]
MethodSig   := "fun" Ident [GenericParams] "(" [Receiver ["," ParamList] | ParamList] ")"
                        [":" Type] [WhereClause]
DefaultMethod := MethodSig ( "=" Expr | Block )
Receiver    := "self" | "mut" "self" | "consuming" "self"
ImplBlock   := "impl" [GenericParams] ( TraitRef "for" Type | Type ) [WhereClause] "{" ImplItem* "}"
TraitRef    := Path [ "<" TypeArgs ">" ]                    // TypeArgs may fix assoc types
FunDecl     := "fun" [GenericParams] Ident "(" [ParamList] ")" [":" Type] [WhereClause] ( "=" Expr | Block )
GenericParams := "<" GenericParam ("," GenericParam)* ">"
GenericParam  := Ident [":" BoundList] [ "=" Type ]         // default type param on traits
BoundList   := TraitRef ("+" TraitRef)*
WhereClause := "where" Type ":" BoundList ("," Type ":" BoundList)*
Projection  := TypeParamOrPath "::" Ident                   // I::Item
Param       := Ident ":" ["inout" | "consuming"] Type       // no bare "mut" on params
```

### Resolved calls

- **Generic-parameter placement — one rule.** **Types/enums/traits: after the name** (`struct List<T>`, `enum Option<T>`, `trait Add<Rhs = Self>`). **Functions and methods: `<…>` after the `fun`… for free functions, after the name for methods** — concretely, **method/trait signatures put generics after the identifier** (`fun map<U>(…)`, `fun fold<A, F>(…)`, `fun okOr<E>(…)`), and free functions may use `fun <T> name(…)`. This matches the mass of existing signatures and the turbofish call form `f::<T>()`. The MethodSig grammar above is fixed to after-name. *(Rejected: before-name for methods — would rewrite nearly every stdlib signature.)*
- **Parameter mutability is `inout`/`consuming`, never bare `mut`.** `mut` is a **receiver** mode (`mut self`) only. A mutable-borrow parameter is `inout`, ampersand at the call site: `fun read(mut self, buf: inout Slice<UInt8>)` called `f.read(&buf)`.
- **B solver = bounded recursive lookup + substitution over concrete impl heads.** Keyed on the impl head's outermost **type constructor**; substitute that impl's own generic params; discharge each `where`-bound by a further concrete-head lookup on the substituted type. **Recursion strictly decreases on substituted type structure; no search, no backtracking, no overlap/negative reasoning.** Generic **container** impls with parameter bounds are **in B** (`impl<T: Display> Display for List<T>`, `impl<I: Iterator, F> Iterator for MapIter<I, F>`) — the compiler cannot self-host without them. **Out of B:** bare-type-variable heads (`impl<T> Trait for T`), constrained blanket impls, auto-`Into`-from-`From`, associated-type equality (`where I::Item = U`), **bounds on projections** (`where I::Item: Display`), calling methods on projected values, multi-hop projections. `I::Item` is an opaque nominal type in B (name/store/return only).
- **Single `Range<T>`.** `a..b` (inclusive) and `a..<b` (half-open) both construct `Range<T>(start, end, inclusive: Bool)`; `Range<T>` impls `Iterator` for integer `T`. **Drop `RangeUntil`** from the operator-desugar table.
- **Formatting fmt keeps `Result<Unit, FmtError>` in B** (forward-compatible with the M5 streaming Formatter), but the B StringBuilder-backed Formatter's write methods always return `Ok`; interpolation lowering discards the always-`Ok` result with no user-visible `try`. *(Rejected: infallible `fmt(...) -> Unit` in B — would force a core-trait signature change at M5 that breaks every hand-written impl in the self-hosted compiler.)*
- **Element-bounded terminals (`sum`/`product`/`max`/`min`) are M5**, not on the B `Iterator` trait — they place a bound on the opaque projection `Self::Item` that the B solver cannot discharge. B provides concrete free functions at the needed types (`fun sumInts(it: inout ListIter<Int>): Int`).

### Core trait catalog (B)

```kite
enum Ordering { Less; Equal; Greater }
trait Eq  { fun eq(self, other: Self): Bool; fun ne(self, other: Self): Bool = !self.eq(other) }
trait Ord: Eq { fun cmp(self, other: Self): Ordering
                fun lt(self, other: Self): Bool = self.cmp(other) == Ordering::Less }   // le/gt/ge default
trait Hash  { fun hash(self, h: inout Hasher) }          // Hasher: concrete struct, FNV-1a in B, SipHash M8
trait Clone { fun clone(self): Self }
trait Copy: Clone {}                                     // marker: all fields Copy → memcpy + clone=*self
trait Default { fun default(): Self }                    // self-less; enums need one @default variant
trait Debug   { fun fmt(self, out: mut Formatter): Result<Unit, FmtError> }
trait Display { fun fmt(self, out: mut Formatter): Result<Unit, FmtError> }
trait Add<Rhs = Self> { type Output; fun add(self, rhs: Rhs): Output }   // Sub/Mul/Div/Rem identical; Neg unary
trait Index<Idx> { type Output; fun index(self, i: Idx): Output }        // Map: Output = V?
trait Iterator { type Item; fun next(mut self): Item? }
trait From<T> { fun from(value: T): Self }               // Into and cross-type From-conversion: M5
trait Sendable {}                                        // single auto-derived marker; enforcement M5
```

- Operator desugaring: `a+b→a.add(b)`, `-a→a.neg()`, `~a→a.not()`, `a&b→a.bitand(b)`, `a<<k→a.shl(k)`, `a==b→a.eq(b)`, `a<b→a.cmp(b)==Less`, `a[i]→a.index(i)`, `a[i]=v→a.set(i,v)` (inherent in B; `IndexSet` M5), `a in b→b.contains(a): Bool`, `a..b`/`a..<b`→`Range` constructor, `a += b→a = a + b`. Boolean `!`, `&&`, `||` are intrinsic on `Bool`.
- **Derives (B):** the seven built-ins `@derive(Eq, Ord, Hash, Clone, Copy, Debug, Default)` ship as compiler-internal comptime specializations over `TypeInfo`. `deinit { … }` is drop glue, **not** a trait. User-defined derives + the full comptime interpreter (`comptime val/fun/params`, `comptime for/if`, `quote`, reflective `TypeInfo`) are M5. `@derive(Error, From)`/`AnyError` are M5.
- **Coherence:** orphan (trait or head-constructor local) + no-overlap + no-specialization, enforced structurally by head-indexed lookup.

### Examples

```kite
impl Add for Vec2 { type Output = Vec2; fun add(self, rhs: Vec2): Vec2 = Vec2(self.x + rhs.x, self.y + rhs.y) }
fun <T: Ord> max(a: T, b: T): T = if a.cmp(b) == Ordering::Greater { a } else { b }
@derive(Eq, Ord, Hash, Clone, Copy, Debug) struct Point(val x: Int, val y: Int)
impl<T> Display for Boxed<T> where T: Display {                 // container-generic impl: in B
    fun fmt(self, out: mut Formatter): Result<Unit, FmtError> = self.value.fmt(out)
}
fun firstOf<I: Iterator>(it: inout I): I::Item? = it.next()    // projection named, opaque in B
```

---

## Closures, functions & iterators

One callable model — **no Fn/FnMut/FnOnce**, no user `Call` trait. A closure is `{code, env}`, capture-by-value + retain, **non-escaping in B**.

### Grammar (final)

```
Lambda      := "{" [LamParams "->"] StmtList "}"       // implicit `it` when head absent & arity 1
LamParams   := (LamParam ("," LamParam)*)?             // "{ -> body }" is zero-arg
LamParam    := Ident [":" Type]
FnType      := "(" [TypeList] ")" "->" Type            // "->" right-assoc in Result
NullableFn  := "(" FnType ")" "?"                      // ((A)->R)?  vs  (A)->R?
FnParamSugar:= Ident ":" FnType                        // f: (A)->R  ==>  fresh <F: (A)->R>, f: F  (intrinsic)
DynFnType   := "dyn" FnType                            // M5
FnRef       := "::" Ident                              // free-function reference (B)
ForLoop     := "for" Ident "in" Expr Block
Range       := Expr ".." Expr | Expr "..<" Expr        // Iterator, Item = Int
```

### Resolved calls

- **Function-type param `f: (A)->R` is sugar for a fresh intrinsic bound `<F: (A)->R>`**, resolved structurally by the compiler (never the user solver), so HOFs monomorphize to direct inlinable calls with no boxing. `dyn (A)->R` (boxed/erased) is M5.
- **Capture by value + retain; captured names are `val`** (assignment = compile error). Shared mutation via a captured `class`/`Box` cell; accumulation via `fold`. By-reference/`inout`/`var`-writeback capture is M5.
- **Non-escaping only in B**, enforced by a conservative escape checker (distinct from the M5 retain-elision optimizer). A lazy adapter chain must be **consumed by a terminal in the same function** — you cannot return a lazy adapter in B.
- **Adapter type names are canonical: `MapIter`, `FilterIter`, `Take`, `Drop`, `Zip`, `Enumerate`.** The collection name `Map` is **never** reused for an adapter. *(Rejected: closures-spec `Map`/`Filter` names — `Map` collides with `Map<K,V>`.)*
- **`chain` and `flatMap` are M5**, removed from the B `Iterator` trait (neither is needed to self-host; `flatMap`'s nested-iterator Item type is exactly the projection stress the lookup solver avoids). Also M5: `takeWhile`, `dropWhile`, `scan`, `flatten`, `windows`, `chunks`, `step`, `downTo`, `distinct`, `sorted`, `groupBy`, `sum`/`product`/`max`/`min`, generic `collect`, non-local/labeled returns, method references.
- **`enumerate`/`zip` yield `Pair<USize, T>`** (field access `.first`/`.second`), never `(A, B)` tuples in B.
- **Canonical B terminal-op list** (both this section and Core stdlib cite it verbatim): `fold(init){}`, `reduce{} → Item?`, `any{}`, `all{}`, `find{} → Item?`, `first() → Item?`, `count()`, `forEach{}`, `toList()`, `toMap()`. `reduce`/`find`/`first` return `Item?` (absence, not failure → never `try`).
- **Self-host guidance:** the stage-1 compiler writes its hot paths as explicit `for`/`while` loops with eager `List` building (and monomorphic helpers like `sumInts`), keeping deep closure-typed adapter chains off the bring-up critical path.

### Iterator trait (B)

```kite
trait Iterator {
  type Item
  fun next(mut self): Item?
  fun map<U, F>(consuming self, f: F): MapIter<Self, F>       = MapIter(self, f)
  fun filter<F>(consuming self, pred: F): FilterIter<Self, F> = FilterIter(self, pred)
  fun enumerate(consuming self): Enumerate<Self>                              // Item = Pair<USize, Item>
  fun zip<J: Iterator>(consuming self, other: J): Zip<Self, J>               // Item = Pair<Item, J::Item>
  fun take(consuming self, n: USize): Take<Self>
  fun drop(consuming self, n: USize): Drop<Self>
  // terminals (consume):
  fun fold<A, F>(consuming self, init: A, f: F): A
  fun reduce<F>(consuming self, f: F): Item?
  fun any<F>(consuming self, pred: F): Bool
  fun all<F>(consuming self, pred: F): Bool
  fun find<F>(consuming self, pred: F): Item?
  fun first(consuming self): Item?
  fun count(consuming self): USize
  fun forEach<F>(consuming self, f: F)
  fun toList(consuming self): List<Item>                       // uses opaque I::Item projection
}
```

`for x in e { body }` desugars to `{ var __it = <comptime: e if e: Iterator else e.iterator()>; while true { val x = __it.next() ?: break; body } }`. B has no `IntoIterator` trait (the comptime branch handles List/Map/Set/Slice/String/Range via concrete inherent `.iterator()`); the real `IntoIterator` + blanket impl arrive at M5. Nullable-element streams: `Item = T?` → `next(): T??`; the single `?: break` peels the outer optional, binding `x: T?`. `filterNotNull()` and `whileSome` handle explicit draining.

### Examples

```kite
val add = { a: Int, b: Int -> a + b }
val evensq = numbers.filter { it % 2 == 0 }.map { it * it }.toList()
for i in 0..<n { grid[i] = compute(i) }
for p in text.chars().enumerate() { print("${p.first}:${p.second}") }   // Pair, no (i,ch) sugar in B
val firstNeg = xs.iter().find { it < 0 }                                // Int?, short-circuits
val sum = xs.fold(0) { a, x -> a + x }                                  // accumulation, no captured var
val ys = xs.map(::square)                                               // free-fn reference
for x in parseAll(lines) { when (x) { Some(v) -> emit(v); None -> {} } } // x: T?, variant patterns
```

---

## Core stdlib & formatting

`String` is immutable UTF-8 over an ARC buffer; slicing yields zero-copy `Substr`; mutation via `StringBuilder`. `List<T>` is value-semantic CoW; `Map<K,V>` is open-addressing (indexing → `V?`); `Set<T>` is `Map<T, Unit>`.

### Resolved calls

- **`Str` is a bound, never a value type, in B.** Every borrowed-string parameter is typed **`Substr`** (a `String` coerces zero-copy to a full-range `Substr`); collections of views are `Slice<Substr>`. `Str` remains as a **static bound** (`<S: Str>`) only for the rare function genuinely generic over owned-vs-view. `impl Str` argument-position existentials (and any `dyn Str`) are M5. *(Rejected: `: Str` bare-trait parameters in B — a trait in value position is `dyn`, and `Slice<Str>` is a slice of unsized existentials, both M5.)*
- **`String.length` = O(1) UTF-8 **byte** count** (equals `byteLen()`), which is what compiler spans need; scalar count is the explicit O(n) `chars().count()`. Pattern/closure examples use `s.length` for strings and reserve `.len()` for collections.
- **List/Map index asymmetry is intentional:** `list[i]: T` and `get(i): T` **panic** OOB (`getOrNull`/`first`/`last` return `T?`); `map[k]: V?` and `set.contains` return Option/Bool. Assignment `list[i] = v`/`map[k] = v` desugars to `set`/`insert`.
- **Formatter is concrete over `StringBuilder` in B.** All formatted output builds into a `StringBuilder`/`String`, then writes via byte-level `writeFile`/stream write. The `dyn Write`-backed streaming Formatter (and "same fmt impl serves file output") is M5. `fmt` keeps the `Result<Unit, FmtError>` signature (§Traits); the B Formatter's writes are always `Ok`.
- **`Read` uses `inout`:** `fun read(mut self, buf: inout Slice<UInt8>): Result<USize, IoError>`, call site `r.read(&buf)`.
- **Universal conversion in B is the free fn `string<T: Display>(v: T): String`** (and interpolation `"$v"`); the M5 extension `fun <T: Display> T.toString(): String` supplies `.toString()` universally. Source standardizes on `string(v)` now to avoid churn.
- **Option/Result layout is plain tagged enums in B** (extra discriminant word). Niche / nullable-pointer packing is an M5 optimization; nothing on the self-host path depends on it.
- **`try` conversion is identity-only in B** (compiler special-case); cross-type widening uses explicit `.mapErr`. From-based auto-conversion + `try { }` blocks are M5.

### Key signatures

```kite
// --- text ---
struct String    { /* {ptr, byteLen, buf: Rc<Bytes>} immutable UTF-8; Clone = O(1) retain */ }
struct Substr    { /* {backing: String, start: USize, end: USize} zero-copy view */ }
trait  Str { fun byteLen(self): USize; fun asBytes(self): Slice<UInt8>; fun chars(self): Chars
             fun startsWith(self, prefix: Substr): Bool; fun contains(self, needle: Substr): Bool }  // bound only
// String extras: length: USize (O(1) bytes); indexOf(Char)->USize?; split(Char): Split (lazy Substr);
//   lines(): Lines; trim()->Substr; substr(start,end)->Substr; parseInt(): Result<Int, ParseIntError>;
//   toIntOrNull(): Int?; impl Add for String { type Output = String }
impl Char { fun isAsciiDigit(self): Bool; fun isAlphanumeric(self): Bool; fun isWhitespace(self): Bool
            fun toDigit(self, radix: Int): Int?; fun toUpper(self): Char; fun code(self): UInt32 }   // ASCII in B

struct StringBuilder { /* unique growable UInt8 buffer, not CoW */ }
impl StringBuilder {
  fun append<T: Display>(mut self, value: T)          // Display-driven; String impls Display
  fun appendChar(mut self, c: Char); fun appendBytes(mut self, bs: Slice<UInt8>)
  fun appendSpec<T: Display>(mut self, value: T, spec: FormatSpec)   // interpolation target
  fun len(self): USize; fun clear(mut self)
  fun toString(consuming self): String                // zero-copy handoff of the unique buffer
}

// --- collections ---
impl<T> List<T> {                                     // value-semantic CoW {ptr,len,cap}
  fun len(self): USize; fun get(self, i: USize): T; fun getOrNull(self, i: USize): T?
  fun set(mut self, i: USize, value: consuming T); fun push(mut self, value: consuming T); fun pop(mut self): T?
  fun first(self): T?; fun last(self): T?; fun contains(self, v: T): Bool where T: Eq
  fun sort(mut self) where T: Ord; fun append(mut self, other: List<T>)   // generic extend<I>: M5
  fun slice(self, r: Range<USize>): Slice<T>; fun iter(self): ListIter<T>
}
impl<K: Hash + Eq, V> Map<K, V> {                     // open addressing, FNV-1a (B), CoW
  fun get(self, k: K): V?                             // m[k] via Index also -> V?
  fun insert(mut self, k: consuming K, v: consuming V): V?; fun remove(mut self, k: K): V?
  fun contains(self, k: K): Bool; fun getOrInsert(mut self, k: K, make: () -> V): V
  fun keys(self): Keys<K>; fun values(self): Values<V>; fun entries(self): Entries<K, V>   // yields Pair<K,V>
}
impl<T: Hash + Eq> Set<T> {                           // Map<T, Unit>; no set literal; algebra M5
  fun insert(mut self, v: consuming T): Bool; fun contains(self, v: T): Bool; fun iter(self): SetIter<T>
}
struct Pair<A, B>(val first: A, val second: B)        // shared by entries/zip/enumerate

// --- Option / Result (kite::core) ---
enum Option<T> { Some(T); None }                      // null = None
impl<T> Option<T> {
  fun isSome(self): Bool; fun map<U>(consuming self, f: (T) -> U): U?
  fun flatMap<U>(consuming self, f: (T) -> U?): U?    // alias andThen
  fun filter(consuming self, pred: (T) -> Bool): T?; fun getOr(consuming self, default: T): T
  fun getOrElse(consuming self, f: () -> T): T; fun expect(consuming self, msg: Substr): T
  fun okOr<E>(consuming self, err: E): Result<T, E>; fun take(mut self): T?
}
enum Result<T, E> { Ok(T); Err(E) }                   // @mustUse
impl<T, E> Result<T, E> {
  fun isOk(self): Bool; fun map<U>(consuming self, f: (T) -> U): Result<U, E>
  fun mapErr<F>(consuming self, f: (E) -> F): Result<T, F>
  fun flatMap<U>(consuming self, f: (T) -> Result<U, E>): Result<U, E>   // alias andThen
  fun ok(consuming self): T?; fun err(consuming self): E?
  fun getOrElse(consuming self, f: (E) -> T): T; fun unwrap(consuming self): T
}

// --- formatting ---
struct Formatter { /* B: sink = mut StringBuilder; spec: FormatSpec. dyn Write sink: M5 */ }
impl Formatter {
  fun write(mut self, s: Substr): Result<Unit, FmtError>; fun writeChar(mut self, c: Char): Result<Unit, FmtError>
  fun writeInt(mut self, n: Int64, radix: Int, upper: Bool): Result<Unit, FmtError>
  fun width(self): USize?; fun precision(self): USize?; fun fill(self): Char; fun align(self): Align; fun radix(self): Int
}
struct FormatSpec { val fill: Char; val align: Align; val sign: Bool; val alt: Bool; val zero: Bool
                    val width: USize?; val precision: USize?; val kind: FmtKind }
enum Align { Left; Right; Center }
enum FmtKind { Default; Dec; Hex(upper: Bool); Oct; Bin; Sci(upper: Bool); Debug; StrK }

// --- io / sys (all blocking in B) ---
fun readFile(path: Substr): Result<String, IoError>
fun writeFile(path: Substr, contents: Substr): Result<Unit, IoError>
trait Write { fun write(mut self, bytes: Slice<UInt8>): Result<USize, IoError>
              fun writeStr(mut self, s: Substr): Result<Unit, IoError> }
trait Read  { fun read(mut self, buf: inout Slice<UInt8>): Result<USize, IoError> }
class File { /* File::open(path: Substr, mode: OpenMode): Result<File, IoError>; deinit closes fd */ }
enum OpenMode { Read; Write; Append; ReadWrite }
impl Process {
  fun run(cmd: Substr, args: Slice<Substr>): Result<Int32, IoError>
  fun runCaptured(cmd: Substr, args: Slice<Substr>): Result<Output, IoError>   // captures as/ld stderr
  fun exit(code: Int32): Nothing
}
struct Output(val exitCode: Int32, val stdout: String, val stderr: String)
enum IoError { NotFound; PermissionDenied; AlreadyExists; InvalidUtf8; UnexpectedEof;
               Subprocess(code: Int32); Errno(code: Int32); Other(msg: String) }
```

### Interpolation & spec

`"a=$x b=${f(y):>4}"` lowers at compile time to a `StringBuilder`: literal segments → `append`, holes → `appendSpec(expr, SPEC)` (a bare hole over a `String`/`Substr` fast-paths to a raw append). Spec grammar inside `${…}`: `[fill]? align? flags? width? ('.' precision)? type?` with `align = < > ^`, `flags = + # 0`, `type = d x X o b e E ? s` (`?` selects `Debug::fmt`). The spec is parsed once at compile time into a constant `FormatSpec`; comptime-specialized straight-line codegen for a literal spec is M5.

### Examples

```kite
val hi = "Hello, ${name}! len=${name.length}"          // length = O(1) byte count
val s  = "0x${addr:08x}"                                 // zero-padded width-8 lower hex
for p in symtab.entries() { println("${p.first} = ${p.second.addr:x}") }   // Pair fields, no (k,v)
var seen = Set<NodeId>(); if !seen.insert(id) { return } // skip already-visited
val cfg: Config = readConfig(p).ok() ?: default()
val src = try readFile("main.kite").mapErr { CErr::Io(it) }   // explicit widen in B (From-conversion M5)
val r = try Process::runCaptured("as", ["-arch", "arm64", "-o", obj, asm])
if r.exitCode != 0 { eprintln(r.stderr); return Err(IoError::Subprocess(r.exitCode)) }
```

---

## Bootstrap slice

Minimal subset of these four areas that stage-0 must emit and the self-hosted compiler is written against (B), versus deferred (M5+).

### In bootstrap (B)

**Pattern matching.** `when` subject + subject-less forms; `when (val s = …)` and `when (consuming …)`; patterns `_`, literals, lowercase bindings, capitalized/`::`-qualified unit variants, positional enum-payload destructuring (incl. `Some/None/Ok/Err`, arbitrary nesting), named-field struct destructuring (pun + `field = pat` + trailing `..`); guards; `is`/`!is` **enum/Option/Result tag** narrowing (locals-only smart-cast); `in`/`!in` **Ord/range** membership (incl. constructible `Range<Char>`); `|` or-patterns (identical bindings); enum/`Bool` exhaustiveness with `else`; first-match/no-fallthrough with dead-arm errors; ARC borrow/copy/consume binding modes under naive scope-end release + the move/drop-flag elaboration pass; LUB typing with `Nothing` absorption and `T`/`T?` join; literal-pattern `Eq` desugaring.

**Traits/generics/derives.** Trait decls with method sigs, default bodies, associated `type`, `Self`, supertraits; inherent + trait impls including generic container impls with parameter bounds; generics on fun/struct/enum/trait (after-name on methods) with inline bounds + `where`; **bounded recursive lookup+substitution solver** over concrete heads with opaque `I::Item`; monomorphization/static dispatch; full operator→trait desugaring; core traits `Eq, Ord (→Ordering), Hash (concrete Hasher/FNV-1a), Clone, Copy, Default, Debug, Display (+Formatter/FmtError), Add/Sub/Mul/Div/Rem/Neg, bitwise/shift, Index, Iterator, From`; single `Range<T>`; `for` over known collections via inherent `.iterator()`; `deinit` drop glue; structural `Sendable` auto-derive (no enforcement); built-in `@derive(Eq, Ord, Hash, Clone, Copy, Debug, Default)` as compiler-internal comptime specializations; coherence/orphan/no-overlap/no-specialization by head-indexed lookup.

**Closures/functions/iterators.** Brace-arrow lambdas, implicit `it`, trailing-lambda sugar; capture-by-value+retain, `val` captures, non-escaping (escape checker); function types + nullable `((A)->R)?`; `f:(A)->R` param sugar = intrinsic `<F:(A)->R>` bound → zero-cost monomorphized HOFs; free-fn refs `::f`; single callable model; `Iterator` trait + `next`; `for` desugar; integer ranges as iterators; lazy adapters **`map, filter, take, drop, zip, enumerate`** (yield `Pair<USize,T>`); terminals **`fold, reduce, any, all, find, first, count, forEach, toList, toMap`**; `filterNotNull`/`whileSome`; adapters generic over the concrete closure type (fused loops), consumed locally.

**Core stdlib/formatting.** `String`/`Substr`/`Char` (ASCII classification), `Str` as a **bound**, borrowed-string params typed `Substr`; `StringBuilder`; CoW `List` (index panics, `getOrNull`/Option), `Map` (index → `V?`), `Set`; full `Option`/`Result` surface (tagged-enum layout); `Display`/`Debug`/`Formatter` (concrete over `StringBuilder`) with compile-time `FormatSpec` parsing; interpolation lowering; free-fn `string(v)`; prelude; blocking `readFile`/`writeFile`, `File`/`OpenMode`, stdout/stderr; `Process::run`/`runCaptured`; `IoError`; concrete `parseInt`/`sumInts` and monomorphic helpers on hot paths.

### Deferred (M5+)

`dyn Trait` (object-safety, fat pointer, vtable/type-descriptor ABI) and all it gates: `dyn`-Write streaming Formatter, `dyn (A)->R` callables, `dyn Str` existential `impl Str` args, class-hierarchy/trait-object `is`. General `IntoIterator`; blanket + constrained impls (auto-`Into`); associated-type equality, projection bounds, method calls on projections, multi-hop projections; associated `const`s, `IndexSet`/compound-assign traits; `@derive(Error, From)`/`AnyError`/`try { }` blocks; user-defined derives + full comptime interpreter (`comptime val/fun/params`, `comptime for/if`, `quote`, `TypeInfo`); `Sendable` enforcement + atomic `Arc`/`Mutex`; extension functions/properties (`.toString()`), `out` variance; escaping/boxed closures, `inout`/`var`-writeback capture, non-local/labeled returns, method references; extended adapters (`chain, flatMap, flatten, takeWhile, dropWhile, scan, windows, chunks, step, downTo, Char-range iteration, distinct, sorted, groupBy`), element-bounded terminals (`sum, product, max, min`), generic `collect`/`FromIterator`; irrefutable `val`/`for`-header destructuring, lightweight tuples + `(k,v)` for-headers, `@`-as-patterns, general in-collection patterns; niche/nullable-pointer layout; retain-elision/region optimizer; comptime-specialized interpolation codegen; full-Unicode `Char` tables; `s[a..<b]` String range sugar; jump-table match lowering. M7+: async IO, `Future`/`Poll`, `suspend`/`Flow`. M8: SipHash, `Path`.