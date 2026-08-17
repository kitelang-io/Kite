# Kite — Language Sketch (bootstrap subset)

Kotlin-flavored surface, ARC memory, no GC. This is the *bootstrap subset* —
the minimum needed to write the compiler in the language itself. It will grow.

## Lexical

- Comments: `// line` and `/* nesting block */`.
- Identifiers: `[A-Za-z_][A-Za-z0-9_]*`.
- Int literals: `123`. Float: `1.5` (a `.` needs a following digit, so `1..5`
  lexes as range `1 .. 5`).
- Strings: `"..."` with escapes `\n \t \r \\ \" \0`.
- Keywords: `fun val var if else while for return when is in as struct enum
  import true false null this break continue`.

## Declarations

```kite
import std.io

struct Point {          // value type; ARC-managed when heap-allocated
    val x: Int
    val y: Int
}

fun distanceSquared(a: Point, b: Point): Int {
    val dx = a.x - b.x
    val dy = a.y - b.y
    return dx * dx + dy * dy
}
```

- `val` = immutable binding, `var` = mutable.
- Function: `fun name(params): ReturnType { ... }`. Return type omitted ⇒ `Unit`.

## Types & null-safety

- Primitives (planned): `Int`, `Long`, `Bool`, `Float`, `Double`, `String`, `Unit`.
- `T?` is a nullable type. Non-null `T` cannot hold `null`.
- Operators: `?.` safe call, `?:` elvis (default), `!!` non-null assertion.

## Expressions

- Arithmetic `+ - * / %`, comparison `== != < > <= >=`, logic `&& || !`.
- `when` as an expression:

```kite
fun describe(n: Int?): String =
    when {
        n == null -> "nothing"
        n < 0     -> "negative"
        else      -> "positive"
    }
```

- `if`/`else`, `while`, `for x in range`, ranges `a..b`.

## Memory model (ARC)

- Reference-typed values (structs on the heap, strings, arrays) are
  reference-counted. The compiler inserts `retain`/`release` at ownership
  transfer points; last release frees. No tracing GC, no stop-the-world.
- Value-typed primitives live in registers/stack; no refcount.
- (Later) `weak` references to break cycles; escape analysis to elide refcounting.

## Not in the bootstrap subset (yet)

Generics, traits/interfaces, closures capturing environment, exceptions,
concurrency, modules beyond flat `import`. Added post-M7 as the language matures.
