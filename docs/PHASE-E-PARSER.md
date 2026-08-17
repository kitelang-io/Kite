# Phase E — The Full-Language Kite Parser (in Kite)

**Status:** implementation-ready plan. Synthesis of five verified area analyses
(declarations, expression-sugar, patterns, types, architecture), reconciled and
re-verified against the OCaml oracle on 2026-08-16.

**Target file:** `stage1/kparse.kite` (currently 765 lines, plain bootstrap subset).
**Oracle:** `lib/parser.ml` (grammar) + `lib/ast.ml` (AST) + `lib/printer.ml` (diff-target text).
**Goal in one line:** grow `kparse.kite` from the subset it parses today into the *full*
Kite surface grammar, emitting `kitec parse` (printer.ml) output **byte-for-byte**.

Every PRINTER FORMAT in this doc was captured from live `main.exe parse` runs during
synthesis; the trickier ones (float `%g`, `char`, function types, `subject ` trailing
space, record-pattern `..`-last, trailing lambdas, turbofish, interpolation, trait
`(signature)`, impl heads, annotations) are reproduced verbatim in §7 as frozen references.

---

## 1. GOAL & CONSTRAINTS

1. **Full surface grammar, all sugar.** Everything `lib/parser.ml` accepts:
   `fun`/`struct`/`class`/`enum`/`trait`/`impl`/`import`; generics `<T: A + B, U = D>`;
   `where` clauses; receivers (`self`/`mut self`/`consuming self`) and param modes
   (`inout`/`consuming`); annotations `@name(args)`; struct/class brace bodies (`deinit`
   + methods); enum named-field payloads; lambdas (`{x -> …}`, trailing-lambda, implicit
   `it`); named call args; turbofish `::<T>`; list/map literals; indexing `e[i]`;
   null-safety `?.`/`?:`/`!!`; ranges; char literals; function types `(A,B)->R`; and
   string interpolation.

2. **Byte-for-byte output.** The only success criterion is
   `diff <(kitec parse F) <(kparse F)` empty, for every probe **and** the entire
   `stage1/*.kite` regression corpus. Indentation unit = 2 spaces. Each top-level decl is
   followed by exactly one blank line (`printer.ml` L264); members inside a body get **no**
   trailing blank line. Note the printer's deliberate spacing asymmetries — reproduce them
   exactly: return type uses **` : `** (spaces both sides); generic/where/assoc bounds use
   **`: `** (colon glued to the name); trait supers use **` : `** (space before colon);
   the `when` subject label always carries a **trailing space** (`subject ` even with no
   binding).

3. **Implementation stays in the kc-compilable bootstrap subset, but tidy.** `kparse.kite`
   is compiled to native by `main.exe run` via the OCaml `codegen_arm64.ml` backend (and,
   equivalently, by the self-hosted `kc`). So **all new code must remain within the codegen
   subset**: `fun`/`val`/`var`/`struct`/`enum`/`when`/`if`/`while`/`for`/field-access/
   recursion, `List`/`String`/`Int`/`Bool`, and the existing builtins
   (`concat`, `strEq`, `strLen`, `charAt`, `substr`, `listNew`/`listPush`/`listGet`/`listLen`,
   `readFile`, `println`, `intToStr`). **No** lambdas, generics, traits, method-call syntax,
   `?:`/`?.`/`!!`, or interpolation *in the implementation itself*. (We are writing the parser
   for those features in the plain subset.) `intToStr` is a confirmed builtin — used by
   `stage1/kmacho.kite`, which compiles and runs.

4. **Non-goals (verified NOT in the surface grammar — must stay rejected, never emitted):**
   `as`-casts (`x as Int` → parse error), `=>`/FATARROW (lexed by oracle, never parsed),
   `@file:` annotation targets, named annotation args (`@cfg(x = 1)`), import grouping
   `{A, B}` / glob `*` / `as`-rename, type grouping parens `((Int)->Int)`, `where` on `enum`,
   top-level `val`/`var`, standalone properties in a type body, and a `consuming` `when`
   subject (`ws_consuming` is hardwired `false`). Matching the oracle means rejecting these
   too — do not implement code paths for them.

---

## 2. TARGET ARCHITECTURE

**Recommendation: EXTEND IN PLACE. Do not restructure, do not rewrite.**

`kparse.kite` is *already* the tidy architecture the brief asks us to reach: it is a
**persistent-AST + separate-printer** design (NOT inline-print). Three cleanly separated
phases already exist:

```
source String  ──lex──▶  List<Tok>  ──parse*──▶  AST (enum/struct values)  ──print*──▶  stdout
```

The full parser is therefore an **extension of the same three layers**, not a new design.
A rewrite would throw away a byte-exact, working self-host round-trip. Grow it as:

- **Lexer layer** — add the char literal, the interpolated-string tag, and the missing
  operator/keyword tokens (§3 token table). **Keep the "newlines are trivia, separate
  structurally" strategy** — `skipTrivia` discards `\n`/`\r`/`;`, so there is **no NEWLINE /
  no ATI** in kparse. Statement and `when`-arm boundaries are detected purely from
  structural tokens (`}`, `)`, `,`, keyword-lookahead). This already works for the whole
  corpus and must be preserved; do **not** port the oracle's Go-style token insertion.
- **AST layer** — widen `enum Expr` / `enum Pat` and add decl structs, mirroring `ast.ml`.
- **Printer layer** — one `print*` per node, reproducing §3's table.

**Type representation — keep type-as-`String` (do NOT introduce a `Ty` enum).**
`printer.ml`'s `string_of_ty`/`string_of_generics`/`string_of_where`/`bounds_str` are pure
string flatteners with no indentation, so `parseTy` already correctly models a type as the
finished `string_of_ty` text. The only gap is the function-type form `(A,B)->R`, handled by
extending `parseTy` (Slice 1). A real `Ty` enum was considered and **declined**: it buys
nothing (types never nest as indented nodes) and adds surface area. Generics, where-clauses,
receivers, and param modes likewise flatten to strings baked into the decl-head line.

**Backtracking pattern.** `P.pos` is a mutable field, so save/restore is trivial
(`val save = p.pos … p.pos = save`). Needed in exactly one place: `tryLambdaParams` (Slice 6).

**Optional tidiness step (after fixpoint, not required):** `main.exe`'s `parse_files`
concatenates multiple `.kite` files into one program, so the single 765→~1600-line file may
later be split into `klex2 / kast / kparse2 / kprint / kmain`. Defer until green.

---

## 3. UNIFIED TOKEN TABLE + AST/PRINTER REFERENCE

### 3.1 Unified token-kind table (single source of truth)

The five area analyses proposed **conflicting** kind numbers for the new tokens (e.g.
expr-sugar used `9`=INTERP, `64`=`[`, `66`=`?.`; declarations used `64`=`where`, `65`=`class`;
types used `65`=`@`). **All conflicts are resolved here. Use these numbers everywhere; ignore
the per-area numbers in the source analyses.**

Existing (unchanged):

```
 0 EOF   1 IDENT  2 INT   3 FLOAT  4 STRING  5 TRUE  6 FALSE  7 NULL  8 THIS
10 fun  11 val   12 var  13 return 14 while
20 (    21 )     22 {    23 }     24 ,     25 :    26 ::   27 .    28 ..
30 +    31 -     32 *    33 /     34 %     35 ==   36 !=   37 <    38 >   39 <=  40 >=  41 &&  42 ||
43 =    44 !     45 ?
50 if   51 else  52 for  53 in    54 struct 55 enum 56 pub  57 when 58 import 59 is
60 ->   61 |     62 break 63 continue
```

New (reconciled — the canonical assignment):

```
 9 CHAR      char literal          text = decimal code point (e.g. 'A' -> "65")
15 INTERP    interpolated string   text = raw body incl. $ / ${…}   (Slice 14)
64 where     keyword
65 class     keyword
66 trait     keyword
67 impl      keyword
68 deinit    keyword
69 self      keyword               (also a primary expression -> prints "this")
70 mut       keyword
71 inout     keyword
72 consuming keyword
73 @         punctuation           annotation marker
74 [         punctuation
75 ]         punctuation
76 ?.        operator              safe field
77 ?:        operator              elvis
78 !!        operator              non-null assertion
```

`type` stays an **IDENT** (kind 1), matched by text (`strEq(ptext(p),"type")`) — exactly as
`lib/parser.ml` does — so it remains usable as an ordinary identifier. `as` and `=>` are
**not** tokenized (not in the grammar); `as` harmlessly lexes as IDENT and never appears in
valid input. kparse never merges `>>` (the oracle merges it to SHR); this is harmless because
valid oracle input never contains adjacent `>>` (it is written `List<Int> >`).

**Lexer edits (all in `lex` / `kw` / `lexOp`):**
- `kw()`: add `where`=64, `class`=65, `trait`=66, `impl`=67, `deinit`=68, `self`=69,
  `mut`=70, `inout`=71, `consuming`=72. (Verified: no corpus file uses any of these as an
  identifier; comment mentions like "self-hosting" are stripped by `skipTrivia` before `kw`.)
- `lexOp()`: `@`(ASCII 64)→73; `[`(91)→74; `]`(93)→75; change the `?`(63) case to emit 76 on
  `.`, 77 on `:`, else 45; change the `!`(33) case to emit 36 on `=`, **78 on `!`**, else 44.
- `lex()`: add a `'`(39) branch (parallel to the `"` branch) that reads a char literal →
  kind 9 with `intToStr(code)` as text (Slice 2). Change the `"` branch to detect an
  unescaped `$` and emit kind 15 (raw body) when present, else kind 4 (Slice 14).

### 3.2 Lookahead helpers (add once, near `pk`/`ptext`)

kparse has no lookahead today; ≥6 full-grammar rules need 1-token peek. Add (bounds-safe →
kind 0 / text "" past end):

```kite
fun kindAt(p: P, n: Int): Int {
  val i = p.pos + n
  if (i < listLen(p.toks)) { val t: Tok = listGet(p.toks, i) ; return t.kind }
  return 0
}
fun pk1(p: P): Int { return kindAt(p, 1) }
fun textAt(p: P, n: Int): String {
  val i = p.pos + n
  if (i < listLen(p.toks)) { val t: Tok = listGet(p.toks, i) ; return t.text }
  return ""
}
```

### 3.3 AST-node ↔ printer-label catalog (verified reference)

"ind" = the node's own level; "+1/+2/+3" = child levels; 2-space unit.

**Expressions** (`pe`, printer.ml 32–121):

| AST (ast.ml) | first line @ind | children |
|---|---|---|
| `IntLit` | `int <text>` | — (source text passthrough) |
| `FloatLit` | `float <%g>` | — (**%g**, not raw — see Slice 2) |
| `StringLit` | `string "<%S>"` | — (see Slice 14 / §8 on `%S`) |
| `CharLit` | `char <decimal>` | — |
| `BoolLit` | `bool true`/`bool false` | — |
| `NullLit` | `null` | — |
| `This` | `this` | — (also from `self`) |
| `Ident` | `ident <s>` | — |
| `Unary` | `unary neg -` / `unary not !` | e @+1 |
| `Binary` | `binary <op>` | l @+1, r @+1 |
| `Elvis` | `elvis ?:` | a @+1, b @+1 |
| `NotNull` | `not-null !!` | e @+1 |
| `Field` | `field .<n>` | e @+1 |
| `SafeField` | `safe-field ?.<n>` | e @+1 |
| `Static` | `static ::<n>` | e @+1 |
| `Call` | `call` | f @+1; if args≠[]: `args`@+1, then each arg (named: `<n> =`@+2, val@+3; positional: val@+2) |
| `Index` | `index` | e @+1, i @+1 |
| `TypeApp` | `type-app ::<<tys>>` (`, `-joined) | e @+1 |
| `ListLit` | `list` | each e @+1 |
| `MapLit` | `map` | per entry: `entry`@+1, k@+2, v@+2 |
| `Lambda` | `lambda (<params>)` (`, `-joined; `name` or `name: T`) | body @+1 |
| `If` | `if` | c@+1, `then`@+1 t@+2, opt `else`@+1 e@+2 |
| `When` | `when` | see below |
| `Block` | `block` | each stmt@+1; opt `result`@+1 res@+2 |
| `Interp` | `interp` | per part: `lit "<%S>"`@+1, or `expr`@+1 e@+2 |
| `EReturn` | `return` | opt e@+1 |
| `EBreak`/`EContinue` | `break`/`continue` | — |

**When** (87–105): `when`@ind. If subject: `subject <b><c>`@+1 where `<b>` = `val <n> = ` or
empty, `<c>` = `consuming ` or empty (**always empty**; both empty ⇒ `subject ` with trailing
space), then subj-expr@+2. Per arm: `LhsElse`→`else`@+1; `LhsCond`→`cond`@+1 e@+2;
`LhsPatterns`→`patterns`@+1 then each pattern@+2. Then opt `guard`@+1 g@+2. Then `->`@+1,
body@+2.

**Statements** (`ps`, 122–137): `SLet`→`val|var <name>[ : <ty>]`@ind, init@+1;
`SExpr`→`expr-stmt`, e@+1; `SAssign`→`assign =`, l@+1 r@+1; `SReturn`→`return` [e@+1];
`SWhile`→`while`, c@+1 b@+1; `SFor`→`for <v> in`, iter@+1 body@+1; `SBreak`/`SContinue`.

**Patterns** (`pp`, 138–162): `PWild`→`_`; `PBind`→`bind <s>`; `PLitInt`→`int <d>`;
`PLitFloat`→`float <%g>`; `PLitString`→`string "<%S>"`; `PLitChar`→`char <d>`;
`PLitBool`→`bool <b>`; `PLitNull`→`null`; `PPath`→`variant <::path>`;
`PCtor`→`ctor <::path>` then (positional: each pat@+1) or (record: per field
`field <n> (pun)` or `field <n> =` then pat@+2; then `..`@+1 **iff** rest, **always last**);
`PIs`→`[!]is <ty>`; `PIn`→`[!]in` then e@+1.

**Declarations** (top level, `pd` 217–263; each followed by a blank line):

| AST | head @0 | body |
|---|---|---|
| `Import` | `import <::path>` | — |
| `FunDecl` (`pfun`) | annos@0; `fun <name><gen>(<recv?><params>)[ : ret]<where>` | body-expr@+1, or `(signature)`@+1 when `fn_body=None` |
| `StructDecl`/`ClassDecl` (`ptd`) | annos@0; `struct`/`class` `<name><gen><where>` | each field@1 `[pub ]val|var <n> : <ty>`; opt `deinit`@1 body@2; each method via `pfun`@1 |
| `EnumDecl` | annos@0; `enum <name><gen>` | per variant@1: `Name`, `Name(t1, t2)`, or `Name(val f1 : T1, val f2 : T2)` (named uses field format) |
| `TraitDecl` | annos@0; `trait <name><gen>[ : supers]<where>` | `type <n>[ : bounds]`@1 each; methods `pfun`@1 |
| `ImplDecl` | annos@0; `impl<gen> <Trait<args>> for <ty><where>` **or** `impl<gen> <ty><where>` | `type <n> = <ty>`@1 each; methods `pfun`@1 |

`panno`: no args → `@<name>`@ind; with args → `@<name>(...)`@ind then each arg-expr@+1.
Generics inline: `<T: A + B, U = D>` (empty ⇒ ""). Where inline: ` where T: A + B, U: C`.
Param: `<name>: [inout |consuming ]<Type>`. Receiver: `self`/`mut self`/`consuming self`,
followed by `, ` iff normal params exist. Field: `[pub ]val|var <name> : <Type>`.

---

## 4. ORDERED IMPLEMENTATION BACKLOG

14 sequential, independently diff-testable slices, ordered by dependency then risk
(low-risk first). Expression sugar precedes declarations so that method/annotation-arg bodies
may use any expression; interpolation is last (hardest). Each slice is "done" when its own
probe diffs clean **and** the full `stage1/*.kite` corpus still diffs clean (§5).

> **Slice 0 (prerequisite, no output change):** add the lookahead helpers (§3.2). Ship with
> Slice 1. Each slice below adds only the *specific* lexer tokens it needs; the full token
> table (§3.1) is the reference.

---

### SLICE 1 — Function types in `parseTy`  *(LOW risk; foundational)*

**Constructs:** `() -> Int`, `(Int, String) -> Bool`, `(Int) -> (Bool) -> Int` (greedy,
right-assoc return), `(Int) -> Int?` (trailing `?` binds the return).
**Tokens:** none new (`(` `)` `,` `->` `?` all lex).
**AST:** none (type stays a `String`).
**Printer:** flattened into the decl head via the existing type-string mechanism; format
`(a, b) -> r` (args `, `-joined). Verified in §7.1.
**Gap:** `parseTy` unconditionally reads `ptext(p)` as a path segment, so a leading `(`
mis-parses.

**Draft — replace `parseTy` (kparse.kite 201–214):**
```kite
fun parseTyBase(p: P): String {
  if (pk(p) == 20) {                                // '(' -> function type (A, B) -> R
    eat(p)
    var inner = ""
    if (pk(p) != 21) {
      inner = parseTy(p)
      while (pk(p) == 24) { eat(p) ; inner = concat(inner, concat(", ", parseTy(p))) }
    }
    eat(p)                                          // ')'
    eat(p)                                          // '->'
    return concat("(", concat(inner, concat(") -> ", parseTy(p))))
  }
  var s = ptext(p) ; eat(p)                         // path Seg(::Seg)*
  while (pk(p) == 26) { eat(p) ; s = concat(s, concat("::", ptext(p))) ; eat(p) }
  if (pk(p) == 37) {                                // '<' generic args
    eat(p)
    var inner = parseTy(p)
    while (pk(p) == 24) { eat(p) ; inner = concat(inner, concat(", ", parseTy(p))) }
    eat(p)                                          // '>'
    s = concat(s, concat("<", concat(inner, ">")))
  }
  return s
}
fun parseTy(p: P): String {
  var s = parseTyBase(p)
  while (pk(p) == 45) { eat(p) ; s = concat(s, "?") }   // nullable postfix loop
  return s
}
```
**Probes:** `probe_types.kite` — the four function-type forms above, plus paths
(`a::B::C`, `kite::collections::Map<K, V>?`, `List<Int?>`) and nullable-of-generic.

---

### SLICE 2 — Char literals + float `%g`  *(LOW-MED; shared printer change)*

**Constructs:** `'A'` (and escapes `'\n' '\t' '\r' '\\' '\'' '\0'`); correct float printing
`1.0`→`float 1`, `3.0`→`float 3`, `0.5`→`float 0.5`, `100.0`→`float 100`.
**Tokens:** CHAR = 9 (lexer branch; text = `intToStr(code)`).
**AST:** add `EChar(String)` to `enum Expr`. (Pattern nodes `PCharP`/`PFloatP` land in Slice 7.)
**Printer:** `EChar(t) -> line(ind, concat("char ", t))`; change
`EFloat(t) -> line(ind, concat("float ", fmtFloat(t)))`.
**Gap:** kparse has no `'…'` lexing (`'A'` mis-lexes to `ident A`); floats print raw
(`float 1.0`) instead of `%g`.
**Regression note:** the corpus contains no char/float literals (lex/tokenize/toklist verified
clean today), so the `%g` change and char token cannot regress it; the probe covers them.

**Draft — lexer char branch (in `lex`, before the `lexOp` fallthrough):**
```kite
if (c == 39) {                                      // '  char literal
  adv(lx)                                           // opening '
  var code = 0
  if (cur(lx) == 92) {                              // backslash escape
    adv(lx)
    val e = cur(lx) ; adv(lx)
    if (e == 110) { code = 10 }                     // \n
    else { if (e == 116) { code = 9 }               // \t
    else { if (e == 114) { code = 13 }              // \r
    else { if (e == 92) { code = 92 }               // \\
    else { if (e == 39) { code = 39 }               // \'
    else { code = 0 } } } } }                       // \0
  } else { code = cur(lx) ; adv(lx) }
  adv(lx)                                           // closing '
  push2(toks, 9, intToStr(code))
}
```
Wire this into `lex`'s dispatch as a peer of the `"`(34) case. **Primary:** add
`if (k == 9) { val t = ptext(p) ; eat(p) ; return EChar(t) }` to `parsePrimary`.

**Draft — `%g` float formatter (add near `pad`):**
```kite
fun fmtFloat(raw: String): String {         // "1.0"->"1", "0.5"->"0.5", "100.0"->"100"
  var dot = 0 - 1
  var i = 0
  while (i < strLen(raw)) { if (charAt(raw, i) == 46) { dot = i } ; i = i + 1 }
  if (dot < 0) { return raw }
  var endp = strLen(raw)
  while (endp > dot + 1 && charAt(raw, endp - 1) == 48) { endp = endp - 1 }   // strip trailing 0
  if (endp == dot + 1) { endp = dot }                                          // strip lone '.'
  return substr(raw, 0, endp)
}
```
(Matches `%g` for the well-formed `d+.d+` floats the lexer produces; see §8 for the
scientific-notation / >6-sig-fig edge case, flagged as a risk.)

**Probes:** `probe_lit.kite` — `'A'`, `'0'`, `'\n'`; floats `1.0 3.0 0.5 10.25 100.0`;
strings `"\t"`, `"a\"b"`.

---

### SLICE 3 — Elvis + postfix cluster (`?.`, `!!`, index, turbofish)  *(LOW-MED; expr core)*

**Constructs:** `a ?: b` (lowest precedence, left-assoc, below `||`); `e?.name`; `e!!`;
`e[i]` (chained `a[i][j]`); turbofish `e::<T, …>`.
**Tokens:** `?.`=76, `?:`=77, `!!`=78, `[`=74, `]`=75.
**AST:** add to `enum Expr`: `ESafeField(Expr, String)`, `ENotNull(Expr)`,
`EElvis(Expr, Expr)`, `EIndex(Expr, Expr)`, `ETypeApp(Expr, String)` (args pre-rendered).
**Printer:** `safe-field ?.<n>` / `not-null !!` / `elvis ?:` (a,b) / `index` (e,i) /
`type-app ::<<tys>>` (child = callee). Precedence/associativity verified in §7.4: `!!` binds
looser than the `?.` chain (`obj?.a?.b!!` = `NotNull(SafeField(SafeField(obj,a),b))`); elvis is
left-assoc and below `||` (`a || b ?: c` = `Elvis(Or(a,b), c)`).

**Draft — elvis level (rename current `parseExpr`→`parseOr`; new `parseExpr`):**
```kite
fun parseOr(p: P): Expr {
  var e = parseAnd(p)
  while (pk(p) == 42) { eat(p) ; e = EBin("||", e, parseAnd(p)) }
  return e
}
fun parseExpr(p: P): Expr {
  var e = parseOr(p)
  while (pk(p) == 77) { eat(p) ; e = EElvis(e, parseOr(p)) }   // ?:  lowest, left-assoc
  return e
}
```
**Draft — postfix (replace `parsePostfix`; add `parseTypeArgs`/`parseColonColon`):**
```kite
fun parseTypeArgs(p: P): String {                   // sees '<'
  eat(p)
  var s = parseTy(p)
  while (pk(p) == 24) { eat(p) ; s = concat(s, concat(", ", parseTy(p))) }
  eat(p)                                            // '>'
  return s
}
fun parseColonColon(p: P, e: Expr): Expr {
  eat(p)                                            // '::'
  if (pk(p) == 37) { return ETypeApp(e, parseTypeArgs(p)) }   // '<' turbofish
  val nm = ptext(p) ; eat(p)
  return EStatic(e, nm)
}
fun parsePostfix(p: P): Expr {
  var e = parsePrimary(p)
  var go = 1
  while (go == 1) {
    val k = pk(p)
    if (k == 27) { eat(p) ; val nm = ptext(p) ; eat(p) ; e = EField(e, nm) }         // .name
    else { if (k == 76) { eat(p) ; val nm = ptext(p) ; eat(p) ; e = ESafeField(e, nm) } // ?.name
    else { if (k == 26) { e = parseColonColon(p, e) }                                // :: / ::<>
    else { if (k == 78) { eat(p) ; e = ENotNull(e) }                                 // !!
    else { if (k == 20) { eat(p) ; e = ECall(e, parseArgs(p)) }                      // ( args )
    else { if (k == 74) { eat(p) ; val ix = parseExpr(p) ; eat(p) ; e = EIndex(e, ix) } // [ i ]
    else { go = 0 } } } } } }
  }
  return e
}
```
(The trailing-lambda `{`(22) branch is added to this loop in Slice 6.)
**Printer additions:** `ESafeField(x,nm)->lineThen1(ind, concat("safe-field ?.",nm), x)`;
`ENotNull(x)->lineThen1(ind,"not-null !!",x)`; `EIndex(a,i)->printBin2(ind,"index",a,i)`;
`ETypeApp(x,ta)->lineThen1(ind, concat("type-app ::<", concat(ta,">")), x)`;
`EElvis(a,b)->printBin2(ind,"elvis ?:",a,b)`.
**Probes:** `probe_null.kite` — `obj?.a?.b!!`, `a ?: b ?: c`, `a || b ?: c`, `a?.b ?: c`;
`probe_post.kite` — `f::<Int>()`, `collect::<List<Int>, String>(xs)`, `a[i][j]`,
`m::<K, V>()[k]`.

---

### SLICE 4 — List & map literals  *(LOW-MED; expr)*

**Constructs:** `[]`, `[1,2,3]`, `[[1],[2]]`, `["k": v, "j": w]`, `[1: 2]` (arbitrary
key/value exprs), trailing commas.
**Tokens:** `[`/`]` (from Slice 3).
**AST:** `EList(List)` (List<Expr>), `EMap(List)` (List<MapEnt>); `struct MapEnt(val k: Expr, val v: Expr)`.
**Printer:** `list` then each elem@+1; `map` then per entry `entry`@+1, k@+2, v@+2. Empty list
= a lone `list` line. Verified §7.4.
**Disambiguation (matches parser.ml 222–257):** after `[`, empty ⇒ list; else parse first
expr; if next is `:` ⇒ map (`k: v` pairs), else list.

**Draft — add to `parsePrimary` (the `[`=74 case):**
```kite
if (k == 74) {                                      // '[' list or map
  eat(p)
  if (pk(p) == 75) { eat(p) ; return EList(listNew()) }         // empty list
  val first = parseExpr(p)
  if (pk(p) == 25) {                                            // ':' => map
    eat(p)
    val ents = listNew()
    listPush(ents, MapEnt(first, parseExpr(p)))
    while (pk(p) == 24) {
      eat(p)
      if (pk(p) != 75) { val kk = parseExpr(p) ; eat(p) ; listPush(ents, MapEnt(kk, parseExpr(p))) }
    }
    eat(p)                                                       // ']'
    return EMap(ents)
  }
  val elems = listNew()                                          // list
  listPush(elems, first)
  while (pk(p) == 24) { eat(p) ; if (pk(p) != 75) { listPush(elems, parseExpr(p)) } }
  eat(p)                                                         // ']'
  return EList(elems)
}
```
**Printer:** `printList`/`printMap` per the table above.
**Probes:** `probe_coll.kite` — `[]`, `[1,2,3]`, `[[1],[2]]`, `["k": v, "j": w]`, `xs[0]`, `m["k"]`.

---

### SLICE 5 — Named call arguments  *(MED; touches every call)*

**Constructs:** `f(x = 1, y)`, `Point(x = 0, y = 1)`, mixed named + positional (+ trailing
lambda later).
**AST:** `struct Arg(val name: String, val expr: Expr)` (name "" ⇒ positional). **`ECall`'s
second field becomes `List<Arg>`** (was List<Expr>).
**Printer:** under `args`, positional ⇒ value@+2; named ⇒ `<name> =`@+2 then value@+3.
Verified §7 (probe c).
**Gap/risk:** the corpus has many calls, all positional — they must print **identically**.
`parseArgs` and `printCall` change together.

**Draft — replace `parseArgs`; add `parseArg`; replace `printCall`:**
```kite
fun parseArg(p: P): Arg {
  if (pk(p) == 1 && pk1(p) == 43) {                 // IDENT '=' => named
    val nm = ptext(p) ; eat(p) ; eat(p)
    return Arg(nm, parseExpr(p))
  }
  return Arg("", parseExpr(p))
}
fun parseArgs(p: P): List {
  val args = listNew()
  if (pk(p) != 21) {
    var more = 1
    while (more == 1) { listPush(args, parseArg(p)) ; if (pk(p) == 24) { eat(p) } else { more = 0 } }
  }
  eat(p)                                            // ')'
  return args
}
fun printCall(ind: Int, f: Expr, args: List): Int {
  line(ind, "call")
  printExpr(ind + 1, f)
  if (listLen(args) > 0) {
    line(ind + 1, "args")
    var i = 0
    while (i < listLen(args)) {
      val a: Arg = listGet(args, i)
      if (strEq(a.name, "")) { printExpr(ind + 2, a.expr) }
      else { line(ind + 2, concat(a.name, " =")) ; printExpr(ind + 3, a.expr) }
      i = i + 1
    }
  }
  return 0
}
```
**Probes:** `probe_namedargs.kite` — `f(x = 1, y)`, `Point(x = 0, y = 1)`, `f(a, b = 1, c = 2)`.

---

### SLICE 6 — Lambdas + trailing-lambda calls  *(MED-HIGH; `{` ambiguity)*

**Constructs:** primary `{ x -> body }`, `{ x: Int, y: Foo -> body }`, `{ -> 0 }` (empty
params). **Edge (verified):** `{ it }` as a *primary* is a **block**, not a lambda. Trailing
lambda: `xs.map { it * 2 }`, `f(x) { it }` (implicit `it` ⇒ empty params, allowed **only**
here), typed multi-param `fold(0) { acc: Int, x: Int -> acc + x }`.
**AST:** `ELambda(String, Expr)` (params pre-rendered `, `-joined); `struct LamHead(val ok: Int, val params: String)`.
**Printer:** `lambda (<params>)` then body@+1. Trailing lambda arrives as `Arg("", lambda)` and
prints as a normal positional arg. Verified §7 (probes a, b).
**Depends on:** Slice 5 (ECall carries Arg).

**Draft — split `parseBlock`; add `tryLambdaParams`, `parseTrailingLam`, `trailingLambda`:**
```kite
fun parseBlock(p: P): Expr { eat(p) ; return parseBlockBody(p) }   // eats '{'
fun parseBlockBody(p: P): Expr {                                   // '{' already consumed
  val stmts = listNew()
  var res = ENoRes
  var go = 1
  while (go == 1) {
    val k = pk(p)
    if (k == 23 || k == 0) { go = 0 }
    else {
      if (isStmtStart(k)) { listPush(stmts, parseStmt(p)) }
      else {
        val e = parseExpr(p)
        if (pk(p) == 43) { eat(p) ; listPush(stmts, SAssign(e, parseExpr(p))) }
        else { if (pk(p) == 23) { res = e } else { listPush(stmts, SExprS(e)) } }
      }
    }
  }
  eat(p)                                            // '}'
  return EBlock(stmts, res)
}
fun tryLambdaParams(p: P): LamHead {                // '{' already consumed
  val saved = p.pos
  if (pk(p) == 60) { eat(p) ; return LamHead(1, "") }           // bare '->'
  if (pk(p) != 1) { return LamHead(0, "") }
  var s = ""
  var ok = 1
  var more = 1
  while (more == 1) {
    if (pk(p) != 1) { ok = 0 ; more = 0 }
    else {
      var one = ptext(p) ; eat(p)
      if (pk(p) == 25) { eat(p) ; one = concat(one, concat(": ", parseTy(p))) }
      if (strEq(s, "")) { s = one } else { s = concat(s, concat(", ", one)) }
      if (pk(p) == 24) { eat(p) } else { more = 0 }
    }
  }
  if (ok == 1 && pk(p) == 60) { eat(p) ; return LamHead(1, s) }
  p.pos = saved
  return LamHead(0, "")
}
```
**Primary `{`** (replace `if (k == 22) { return parseBlock(p) }`):
```kite
if (k == 22) {
  eat(p)
  val lh = tryLambdaParams(p)
  if (lh.ok == 1) { return ELambda(lh.params, parseBlockBody(p)) }
  return parseBlockBody(p)                          // plain block (incl. `{ it }`)
}
```
**Trailing lambda** — add to `parsePostfix`'s loop: `else { if (k == 22) { e = trailingLambda(p, e) }`
```kite
fun parseTrailingLam(p: P): Expr {                  // sees '{'
  eat(p)
  val lh = tryLambdaParams(p)
  var params = ""
  if (lh.ok == 1) { params = lh.params }
  return ELambda(params, parseBlockBody(p))         // implicit-it => params ""
}
fun trailingLambda(p: P, e: Expr): Expr {
  val larg = Arg("", parseTrailingLam(p))
  return when (e) {
    ECall(f, args) -> callAppend(f, args, larg)
    else -> callNew(e, larg)
  }
}
fun callAppend(f: Expr, args: List, larg: Arg): Expr { listPush(args, larg) ; return ECall(f, args) }
fun callNew(e: Expr, larg: Arg): Expr { val a = listNew() ; listPush(a, larg) ; return ECall(e, a) }
```
**Printer:** `ELambda(params, body) -> printLambda(ind, params, body)` →
`line(ind, concat("lambda (", concat(params, ")"))) ; printExpr(ind+1, body)`.
**Probes:** `probe_lambda.kite` — `{ x -> x + 1 }`, `{ x: Int, y: Foo -> x }`, `{ -> 0 }`,
`{ it }` (block edge), `xs.map { it * 2 }`, `f(x) { it }`, `fold(0) { acc: Int, x: Int -> acc + x }`.

---

### SLICE 7 — Record / char / float / negative patterns  *(MED; patterns)*

**Constructs:** char pattern `'c'`; float pattern `3.5`, negative float `-2.5`; record ctor
patterns — pun `Config(host, port, ..)`, rename `Point(x = 0, y = 0)`, rest-only `Foo(..)`,
rest-not-last `Baz(.., y = 2)`, nested `Node(left = Leaf(v), ..)`.
**Tokens:** CHAR=9 (from Slice 2).
**AST:** extend `enum Pat` with `PCharP(String)`, `PFloatP(String)`,
`PRecord(String, List, Int)` (path, List<RFld>, hasRest); add
`struct RFld(val name: String, val hasPat: Int, val pat: Pat)` (hasPat 0 = pun),
`struct RawArg(val tag: Int, val name: String, val pat: Pat)` (tag 0 pos / 1 named / 2 rest).
**Printer:** `char <d>`, `float <%g>`; record shares the `ctor <path>` header; per field
`field <n> =` + pat@+2 or `field <n> (pun)`@+1; then `..`@+1 **iff** hasRest — **always last,
regardless of source position** (verified §7.2).
**Key rule (parser.ml 370–405):** classify each arg entry; the whole list is a **record**
iff any entry is `..` or `name =`, else **positional**. In record mode a bare lowercase name
becomes a **pun** field; a bare name with no rest/named present stays a positional bind
(`Point(a, b)` = positional; `Config(host, port, ..)` = puns). A non-bind positional entry in
a record list is a parse error in the oracle (`a record pattern field must be a bare name`).

**Draft — helpers + rewritten `parsePattern` + `parseCtorPat` (replaces `parseCtorArgs`):**
```kite
fun isLower(s: String): Bool {
  if (strLen(s) == 0) { return false }
  val c = charAt(s, 0) ; return c >= 97 && c <= 122
}
fun bindName(pat: Pat): String { return when (pat) { PBind(s) -> s ; else -> "" } }

fun parsePattern(p: P): Pat {
  val k = pk(p)
  if (k == 2) { val t = ptext(p) ; eat(p) ; return PInt(t) }                 // INT
  if (k == 3) { val t = ptext(p) ; eat(p) ; return PFloatP(fmtFloat(t)) }    // FLOAT
  if (k == 31) {                                                             // -INT / -FLOAT
    eat(p)
    val nk = pk(p) ; val t = ptext(p) ; eat(p)
    if (nk == 3) { return PFloatP(concat("-", fmtFloat(t))) }
    return PInt(concat("-", t))
  }
  if (k == 4) { val t = ptext(p) ; eat(p) ; return PStr(t) }                 // STRING
  if (k == 9) { val t = ptext(p) ; eat(p) ; return PCharP(t) }               // CHAR
  if (k == 5) { eat(p) ; return PBoolP("true") }
  if (k == 6) { eat(p) ; return PBoolP("false") }
  if (k == 7) { eat(p) ; return PNullP }
  if (k == 59) { eat(p) ; return PIsP(parseTy(p), 0) }                       // is T
  if (k == 53) { eat(p) ; return PInP(parseExpr(p), 0) }                     // in e
  if (k == 44) { eat(p)                                                      // !is / !in
    if (pk(p) == 59) { eat(p) ; return PIsP(parseTy(p), 1) }
    eat(p) ; return PInP(parseExpr(p), 1) }
  val name = ptext(p) ; eat(p)
  if (strEq(name, "_")) { return PWild }
  if (isUpper(name)) {
    var path = name
    while (pk(p) == 26) { eat(p) ; path = concat(path, concat("::", ptext(p))) ; eat(p) }
    if (pk(p) == 20) { return parseCtorPat(p, path) }
    return PPath(path)
  }
  return PBind(name)
}
fun parseRawArg(p: P): RawArg {
  if (pk(p) == 28) { eat(p) ; return RawArg(2, "", PWild) }                  // '..'
  if (pk(p) == 1) {
    if (isLower(ptext(p)) && pk1(p) == 43) {                                // ident '=' rename
      val nm = ptext(p) ; eat(p) ; eat(p) ; return RawArg(1, nm, parsePattern(p))
    }
  }
  return RawArg(0, "", parsePattern(p))
}
fun parseCtorPat(p: P, path: String): Pat {
  eat(p)                                            // '('
  val raws = listNew()
  if (pk(p) != 21) {
    var more = 1
    while (more == 1) { listPush(raws, parseRawArg(p)) ; if (pk(p) == 24) { eat(p) } else { more = 0 } }
  }
  eat(p)                                            // ')'
  var hasRest = 0
  var hasNamed = 0
  var i = 0
  while (i < listLen(raws)) { val r: RawArg = listGet(raws, i)
    if (r.tag == 2) { hasRest = 1 } ; if (r.tag == 1) { hasNamed = 1 } ; i = i + 1 }
  if (hasRest == 0 && hasNamed == 0) {                                       // positional
    val pats = listNew()
    var j = 0
    while (j < listLen(raws)) { val r: RawArg = listGet(raws, j) ; listPush(pats, r.pat) ; j = j + 1 }
    return PCtor(path, pats)
  }
  val flds = listNew()                                                       // record
  var m = 0
  while (m < listLen(raws)) { val r: RawArg = listGet(raws, m)
    if (r.tag == 1) { listPush(flds, RFld(r.name, 1, r.pat)) }
    else { if (r.tag == 0) { listPush(flds, RFld(bindName(r.pat), 0, PWild)) } }
    m = m + 1 }
  return PRecord(path, flds, hasRest)
}
```
**Printer additions:** `PFloatP(t)->line(ind, concat("float ", t))`,
`PCharP(t)->line(ind, concat("char ", t))`, `PRecord(pth,flds,hasRest)->printRecord(...)`:
```kite
fun printRecord(ind: Int, pth: String, flds: List, hasRest: Int): Int {
  line(ind, concat("ctor ", pth))
  var i = 0
  while (i < listLen(flds)) { val f: RFld = listGet(flds, i)
    if (f.hasPat == 1) { line(ind + 1, concat("field ", concat(f.name, " ="))) ; printPat(ind + 2, f.pat) }
    else { line(ind + 1, concat("field ", concat(f.name, " (pun)"))) }
    i = i + 1 }
  if (hasRest == 1) { line(ind + 1, "..") }
  return 0
}
```
`parseWhen`/`printWhen` are **unchanged** — they already route pattern arms through
`parsePattern`/`printPat`, so this slice completes `when` end-to-end. (`when`'s three subject
forms are already byte-correct today.)
**Probes:** `probe_patterns.kite` — the literal set (`-1 'c' 3.5 -2.5 "a" null n _`); positional
`Point(a, b)` vs pun `Config(host, port, ..)`; rename / rest-only / rest-not-last / nested;
paths + or-list + `is`/`!in` + guard.

---

### SLICE 8 — Shared decl infra: generics, where, bounds, annotations  *(MED)*

**Constructs:** `<T: A + B, U = D>`, ` where T: A + B, U: C`, `@name` / `@name(args)`. Wire
generics+where into the **existing** `fun`/`struct`/`enum` heads; wire annotations into the
`main()` dispatch.
**Tokens:** `where`=64, `@`=73.
**AST:** `struct Anno(val name: String, val args: List)` (args: List<Expr>). Add fields to
existing decl structs (see Slices 9–13). Generics/where are plain `String` fragments.
**Printer:** generics/where flatten inline into heads (empty ⇒ ""); annotations print at the
decl's indent above the head (`@name` or `@name(...)` then arg-exprs@+1). Verified §7.6.
**Boundary resolution:** the declarations agent and the types agent both drafted these; the
canonical version uses the types agent's shared `parseBoundList` (reused by generics, where,
and trait supers). Both drafts produce identical strings. **`parseEnum` must NOT call
`parseWhere`** (the oracle rejects `enum E where …`).

**Draft:**
```kite
fun parseBoundList(p: P): String {                  // bound (+ bound)*  -> "A + B"
  var s = parseTy(p)
  while (pk(p) == 30) { eat(p) ; s = concat(s, concat(" + ", parseTy(p))) }   // 30 = '+'
  return s
}
fun parseGenerics(p: P): String {                   // "" if no '<', else "<...>"
  if (pk(p) != 37) { return "" }
  eat(p)
  var s = "<"
  var first = 1
  var more = 1
  while (more == 1) {
    var one = ptext(p) ; eat(p)
    if (pk(p) == 25) { eat(p) ; one = concat(one, concat(": ", parseBoundList(p))) }   // : bounds
    if (pk(p) == 43) { eat(p) ; one = concat(one, concat(" = ", parseTy(p))) }         // = default
    if (first == 1) { s = concat(s, one) ; first = 0 } else { s = concat(s, concat(", ", one)) }
    if (pk(p) == 24) { eat(p) } else { more = 0 }
  }
  eat(p)                                            // '>'
  return concat(s, ">")
}
fun parseWhere(p: P): String {                      // "" if no 'where', else " where ..."
  if (pk(p) != 64) { return "" }
  eat(p)
  var s = " where "
  var first = 1
  var more = 1
  while (more == 1) {
    var one = parseTy(p)
    eat(p)                                          // ':'
    one = concat(one, concat(": ", parseBoundList(p)))
    if (first == 1) { s = concat(s, one) ; first = 0 } else { s = concat(s, concat(", ", one)) }
    if (pk(p) == 24) { eat(p) } else { more = 0 }
  }
  return s
}
fun parseAnnos(p: P): List {                        // ('@' ident ['(' expr,* ')'])* -> List<Anno>
  val annos = listNew()
  while (pk(p) == 73) {
    eat(p)
    val nm = ptext(p) ; eat(p)
    val args = listNew()
    if (pk(p) == 20) { eat(p)
      if (pk(p) != 21) { var more = 1
        while (more == 1) { listPush(args, parseExpr(p)) ; if (pk(p) == 24) { eat(p) } else { more = 0 } } }
      eat(p) }                                      // ')'
    listPush(annos, Anno(nm, args))
  }
  return annos
}
fun printAnnos(ind: Int, annos: List): Int {
  var i = 0
  while (i < listLen(annos)) {
    val a: Anno = listGet(annos, i)
    if (listLen(a.args) == 0) { line(ind, concat("@", a.name)) }
    else { line(ind, concat("@", concat(a.name, "(...)")))
      var j = 0
      while (j < listLen(a.args)) { val e: Expr = listGet(a.args, j) ; printExpr(ind + 1, e) ; j = j + 1 } }
    i = i + 1
  }
  return 0
}
```
Wiring into the existing `fun`/`struct`/`enum` in this slice: give `Func`/`SDecl`/`EDecl` a
`gen`/`whr`/`annos` field, populate via `parseGenerics`/`parseWhere` after the name (fun:
where after ret; struct: where after fields; **enum: generics only**), and prepend
`printAnnos` in each print head. `main()` parses `parseAnnos(p)` before dispatch (Slice 13's
`main` rewrite folds this in). Since all three helpers return "" / empty on absence, annotation-
and generic-free decls print identically → no corpus regression.
**Probes:** `probe_generics.kite` — `fun f<T>(x: T): T = x`, `fun h<T: Show + Eq, U = Int>(x: T): U = 0`,
`struct Box<T>(val value: T)`, `struct Wrap<T>(val v: T) where T: Show + Eq`, `enum Opt<T> { None; Some(T) }`;
`probe_anno.kite` — `@inline fun`, `@derive(Eq, Ord) struct`, `@repr(transparent) enum`, stacked annos.

---

### SLICE 9 — `fun` full form: receivers, param modes, generics both positions, signature body  *(MED)*

**Constructs:** free-fn `fun <T> name(...)` **and** method `fun name<T>(...)`; receivers
`self` / `mut self` / `consuming self`; param modes `inout` / `consuming`; signature-only body
(no `=`/`{`) → prints `(signature)`; `self` as a bare expression → prints `this`.
**Tokens:** `self`=69, `mut`=70, `inout`=71, `consuming`=72 (all from §3.1).
**AST:** replace `struct Func` with
`struct Func(val annos: List, val name: String, val gen: String, val recv: String, val params: List, val ret: String, val whr: String, val body: Expr)` — `body == ENoRes` means signature-only.
Keep `struct Param(val name, val ty)` and **bake the mode prefix into `ty`** (the printer emits
exactly `name: <prefix><ty>`), and represent the receiver as a plain string.
**Printer:** header `fun <name><gen>(<recv-glue><params>)[ : ret]<where>`; body@+1 or
`(signature)`@+1. Receiver glue = `recv` then `, ` iff normal params exist. Verified §7.5.

**Draft (replaces `parseFunc`/`printFunc`):**
```kite
fun parseParam(p: P): Param {
  val nm = ptext(p) ; eat(p)
  eat(p)                                            // ':'
  var pre = ""
  if (pk(p) == 71) { eat(p) ; pre = "inout " }
  else { if (pk(p) == 72) { eat(p) ; pre = "consuming " } }
  return Param(nm, concat(pre, parseTy(p)))
}
fun parseRecv(p: P): String {
  val k = pk(p)
  if (k == 69) { eat(p) ; return "self" }
  if (k == 70 && pk1(p) == 69) { eat(p) ; eat(p) ; return "mut self" }
  if (k == 72 && pk1(p) == 69) { eat(p) ; eat(p) ; return "consuming self" }
  return ""
}
fun parseFunc(p: P, annos: List): Func {
  eat(p)                                            // 'fun'
  var gen = parseGenerics(p)                        // free-fn: fun <T> name
  val name = ptext(p) ; eat(p)
  if (strEq(gen, "")) { gen = parseGenerics(p) }    // method: fun name<T>
  eat(p)                                            // '('
  val recv = parseRecv(p)
  val params = listNew()
  var need = 0
  if (strEq(recv, "")) { if (pk(p) != 21) { need = 1 } }
  else { if (pk(p) == 24) { eat(p) ; need = 1 } }
  if (need == 1) { var more = 1
    while (more == 1) { listPush(params, parseParam(p)) ; if (pk(p) == 24) { eat(p) } else { more = 0 } } }
  eat(p)                                            // ')'
  var ret = ""
  if (pk(p) == 25) { eat(p) ; ret = parseTy(p) }
  val whr = parseWhere(p)                           // where AFTER ret
  var body = ENoRes
  if (pk(p) == 43) { eat(p) ; body = parseExpr(p) }
  else { if (pk(p) == 22) { body = parseBlock(p) } }   // else signature-only
  return Func(annos, name, gen, recv, params, ret, whr, body)
}
fun funcHead(fd: Func): String {
  var recvp = ""
  if (strEq(fd.recv, "") == false) {
    if (listLen(fd.params) == 0) { recvp = fd.recv } else { recvp = concat(fd.recv, ", ") }
  }
  var head = concat("fun ", concat(fd.name, concat(fd.gen,
             concat("(", concat(recvp, concat(paramStr(fd.params), ")"))))))
  if (strEq(fd.ret, "") == false) { head = concat(head, concat(" : ", fd.ret)) }
  return concat(head, fd.whr)
}
fun printFuncAt(ind: Int, fd: Func): Int {          // members use ind 1; NO trailing blank line
  printAnnos(ind, fd.annos)
  line(ind, funcHead(fd))
  if (isNoRes(fd.body)) { line(ind + 1, "(signature)") } else { printExpr(ind + 1, fd.body) }
  return 0
}
fun printFunc(fd: Func): Int { printFuncAt(0, fd) ; println("") ; return 0 }
```
Add `self` primary: `if (k == 69) { eat(p) ; return EThis }` (prints `this`, verified).
`paramStr` is reused unchanged (baked-in prefix yields `b: inout Foo` for free).
**Probes:** `probe_fun.kite` — `fun add(a: Int, b: Int): Int = a + b`; both generic positions
round-trip to `fun name<...>`; `fun consume(consuming self): Int = 0`;
`fun mix(a: Int, b: inout Foo, c: consuming Bar): Bool = true`; `fun swap(a: inout Int, b: inout Int) { }`.
(Signature-only is exercised via the trait probe in Slice 12.)

---

### SLICE 10 — `struct` / `class` brace bodies  *(MED-HIGH)*

**Constructs:** `class` keyword; primary-ctor fields (already work); `where`; annotations;
brace body containing `deinit { … }` and methods (`fun` with any receiver/mode). Order:
fields → deinit → methods.
**Tokens:** `class`=65, `deinit`=68.
**AST:** replace `struct SDecl` with
`struct TDecl(val annos: List, val kind: Int, val name: String, val gen: String, val fields: List, val whr: String, val deinit: Expr, val methods: List)` — kind 0 struct / 1 class; `deinit == ENoRes` ⇒ none.
**Printer:** `struct|class <name><gen><where>`; fields@1; `deinit`@1 + body@2 iff present;
methods via `printFuncAt(1, …)`. Verified §7.5.
**Grammar boundary (verified):** a type body accepts **only** `deinit` and `fun` — a standalone
property in the body is a parse error; do not implement it. Depends on Slices 8, 9.

**Draft (replaces `parseStruct`/`printSDecl`, serves both `struct` and `class`):**
```kite
fun fldStr(f: Fld): String {                        // "pub val x : Int" (space-padded colon)
  val pubs = if (f.isPub == 1) { "pub " } else { "" }
  val kw = if (f.isVar == 1) { "var" } else { "val" }
  return concat(pubs, concat(kw, concat(" ", concat(f.name, concat(" : ", f.ty)))))
}
fun parseTypeDecl(p: P, annos: List, kind: Int): TDecl {
  eat(p)                                            // 'struct' | 'class'
  val name = ptext(p) ; eat(p)
  val gen = parseGenerics(p)
  val fields = listNew()
  if (pk(p) == 20) { eat(p)
    if (pk(p) != 21) { var more = 1
      while (more == 1) {
        var isPub = 0
        if (pk(p) == 56) { isPub = 1 ; eat(p) }
        val isVar = if (pk(p) == 12) { 1 } else { 0 }
        eat(p)                                      // val / var
        val fn = ptext(p) ; eat(p)
        eat(p)                                      // ':'
        listPush(fields, Fld(isPub, isVar, fn, parseTy(p)))
        if (pk(p) == 24) { eat(p) } else { more = 0 }
      } }
    eat(p) }                                        // ')'
  val whr = parseWhere(p)
  var deinit = ENoRes
  val methods = listNew()
  if (pk(p) == 22) { eat(p)
    while (pk(p) != 23 && pk(p) != 0) {
      val manns = parseAnnos(p)
      if (pk(p) == 68) { eat(p) ; deinit = parseBlock(p) }      // deinit { ... }
      else { listPush(methods, parseFunc(p, manns)) }
    }
    eat(p) }                                        // '}'
  return TDecl(annos, kind, name, gen, fields, whr, deinit, methods)
}
fun printTDecl(td: TDecl): Int {
  printAnnos(0, td.annos)
  val kw = if (td.kind == 1) { "class " } else { "struct " }
  line(0, concat(kw, concat(td.name, concat(td.gen, td.whr))))
  var i = 0
  while (i < listLen(td.fields)) { val f: Fld = listGet(td.fields, i) ; line(1, fldStr(f)) ; i = i + 1 }
  if (isNoRes(td.deinit) == false) { line(1, "deinit") ; printExpr(2, td.deinit) }
  var j = 0
  while (j < listLen(td.methods)) { val m: Func = listGet(td.methods, j) ; printFuncAt(1, m) ; j = j + 1 }
  println("")
  return 0
}
```
**Probes:** `probe_class.kite` — the `struct Point(pub val x, pub var y) { fun norm/shift/consume }`
and `class Node(val v, var next) { deinit { println(v) } fun get }` cases; `struct Empty()`;
`struct Wrap<T: Show>(val t: T) where T: Clone`; `@derive(Eq, Ord) struct Buf { @inline fun len ; deinit }`.

---

### SLICE 11 — `enum` named payloads  *(MED)*

**Constructs:** named-field variant payloads `Named(w: Int, h: Int)` (in addition to none /
positional, which already work). Generics + annotations come from Slice 8.
**AST:** replace `struct Variant` with
`struct Variant(val name: String, val payKind: Int, val tys: List, val flds: List)` — payKind
0 none / 1 positional (tys: List<String>) / 2 named (flds: List<Fld>).
**Printer:** named payload prints via the field format: `Name(val w : Int, val h : Int)`
(reuses `fldStr` with `false false`). Verified §7 (probe_repr / declarations §3 oracle).
**Disambiguation (parser.ml 730):** named iff first entry is `IDENT` followed by `:`
(kind 25). Enum named fields carry no `pub`/`val`/`var`.

**Draft (replaces `parseEnum`/`printEDecl` variant handling):**
```kite
fun parseVariant(p: P): Variant {
  val vn = ptext(p) ; eat(p)
  if (pk(p) != 20) { return Variant(vn, 0, listNew(), listNew()) }
  eat(p)                                            // '('
  if (pk(p) == 21) { eat(p) ; return Variant(vn, 0, listNew(), listNew()) }   // '()'
  val named = if (pk(p) == 1 && pk1(p) == 25) { 1 } else { 0 }               // IDENT ':' ?
  if (named == 1) {
    val flds = listNew()
    var more = 1
    while (more == 1) {
      val fn = ptext(p) ; eat(p)
      eat(p)                                        // ':'
      listPush(flds, Fld(0, 0, fn, parseTy(p)))
      if (pk(p) == 24) { eat(p) } else { more = 0 }
    }
    eat(p)                                          // ')'
    return Variant(vn, 2, listNew(), flds)
  }
  val tys = listNew()
  var more2 = 1
  while (more2 == 1) { listPush(tys, parseTy(p)) ; if (pk(p) == 24) { eat(p) } else { more2 = 0 } }
  eat(p)                                            // ')'
  return Variant(vn, 1, tys, listNew())
}
fun variantStr(v: Variant): String {
  if (v.payKind == 0) { return v.name }
  if (v.payKind == 1) { return concat(v.name, concat("(", concat(tyList(v.tys), ")"))) }
  return concat(v.name, concat("(", concat(fldList(v.flds), ")")))
}
fun fldList(flds: List): String {                   // "val w : Int, val h : Int"
  var s = ""
  var i = 0
  while (i < listLen(flds)) { val f: Fld = listGet(flds, i)
    if (i == 0) { s = fldStr(f) } else { s = concat(s, concat(", ", fldStr(f))) } ; i = i + 1 }
  return s
}
```
`parseEnum` gains `parseGenerics` after the name (no where), stores `gen`/`annos`; `printEDecl`
prepends `printAnnos` and prints `enum <name><gen>`.
**Probes:** `probe_enum.kite` — `enum Shape { Circle(Float); Rect(Float, Float); Named(w: Int, h: Int) }`;
`enum Opt<T> { None; Some(T) }`; `enum Res<T, E> { Ok(value: T); Err(E) }`; `@repr(transparent) enum Color { Red; Green; Blue }`.

---

### SLICE 12 — `trait`  *(MED-HIGH)*

**Constructs:** `trait Name<gen>[ : super + super][ where …] { … }`; members = associated
types `type Item [: bounds]` and methods (signature-only or default body).
**Tokens:** `trait`=66. `type` stays IDENT (matched by text).
**AST:** `struct Assoc(val name: String, val text: String)` (trait: text ""|" : bounds");
`struct TraitDecl(val annos, val name, val gen, val supers, val whr, val assoc, val methods)`.
**Printer:** `trait <name><gen>[ : supers]<where>` (supers use ` : ` space-before-colon, via
`parseBoundList`); assoc `type <n>[ : bounds]`@1; methods `printFuncAt(1, …)` (sig →
`(signature)`, default → body). Verified §7.5. Depends on Slices 8, 9.

**Draft:**
```kite
fun parseTrait(p: P, annos: List): TraitDecl {
  eat(p)                                            // 'trait'
  val name = ptext(p) ; eat(p)
  val gen = parseGenerics(p)
  var supers = ""
  if (pk(p) == 25) { eat(p) ; supers = concat(" : ", parseBoundList(p)) }    // ' : ' supers
  val whr = parseWhere(p)
  eat(p)                                            // '{'
  val assoc = listNew()
  val methods = listNew()
  while (pk(p) != 23 && pk(p) != 0) {
    val manns = parseAnnos(p)
    if (pk(p) == 1 && strEq(ptext(p), "type")) {    // associated type
      eat(p)
      val an = ptext(p) ; eat(p)
      var text = ""
      if (pk(p) == 25) { eat(p) ; text = concat(" : ", parseBoundList(p)) }
      listPush(assoc, Assoc(an, text))
    } else { listPush(methods, parseFunc(p, manns)) }
  }
  eat(p)                                            // '}'
  return TraitDecl(annos, name, gen, supers, whr, assoc, methods)
}
fun printAssoc(assoc: List): Int {                  // shared with impl (impl text = " = Ty")
  var i = 0
  while (i < listLen(assoc)) { val a: Assoc = listGet(assoc, i)
    line(1, concat("type ", concat(a.name, a.text))) ; i = i + 1 }
  return 0
}
fun printTrait(tr: TraitDecl): Int {
  printAnnos(0, tr.annos)
  line(0, concat("trait ", concat(tr.name, concat(tr.gen, concat(tr.supers, tr.whr)))))
  printAssoc(tr.assoc)
  var j = 0
  while (j < listLen(tr.methods)) { val m: Func = listGet(tr.methods, j) ; printFuncAt(1, m) ; j = j + 1 }
  println("")
  return 0
}
```
**Probes:** `probe_trait.kite` — `trait Show { fun show(self): String }` (sig-only);
`trait Ord<T>: Eq + PartialOrd where T: Clone { type Item: Show ; type Raw ; fun cmp(self, other: T): Int ; fun max(self, other: T): T = self }`;
`@sealed trait Iterator<T> { type Item ; @inline fun next(mut self): Item }`.

---

### SLICE 13 — `impl` + `main` dispatch rewrite  *(MED-HIGH)*

**Constructs:** `impl<gen> Type [where …] { … }` (inherent) and
`impl<gen> Trait<args> for Type [where …] { … }`; members = associated-type bindings
`type Name = Ty` and methods.
**Tokens:** `impl`=67 (reuses `for`=52).
**AST:** `struct ImplDecl(val annos, val gen, val trait, val forTy, val whr, val assoc, val methods)`
— `trait == ""` ⇒ inherent. Reuses `Assoc` (text `" = Ty"`) and `printAssoc`.
**Printer:** trait impl `impl<gen> <Trait<args>> for <Type><where>`; inherent
`impl<gen> <Type><where>`; assoc `type <n> = <ty>`@1; methods `printFuncAt(1, …)`. `parseTy`
already returns the fully-formatted trait/type head including `<args>`. Verified §7.5.

**Draft:**
```kite
fun parseImpl(p: P, annos: List): ImplDecl {
  eat(p)                                            // 'impl'
  val gen = parseGenerics(p)
  val first = parseTy(p)
  var trait = ""
  var forTy = first
  if (pk(p) == 52) { eat(p) ; trait = first ; forTy = parseTy(p) }   // 'for'
  val whr = parseWhere(p)
  eat(p)                                            // '{'
  val assoc = listNew()
  val methods = listNew()
  while (pk(p) != 23 && pk(p) != 0) {
    val manns = parseAnnos(p)
    if (pk(p) == 1 && strEq(ptext(p), "type")) {    // associated-type binding
      eat(p)
      val an = ptext(p) ; eat(p)
      eat(p)                                        // '='
      listPush(assoc, Assoc(an, concat(" = ", parseTy(p))))
    } else { listPush(methods, parseFunc(p, manns)) }
  }
  eat(p)                                            // '}'
  return ImplDecl(annos, gen, trait, forTy, whr, assoc, methods)
}
fun implHead(im: ImplDecl): String {
  if (strEq(im.trait, "")) {
    return concat("impl", concat(im.gen, concat(" ", concat(im.forTy, im.whr))))
  }
  return concat("impl", concat(im.gen, concat(" ",
         concat(im.trait, concat(" for ", concat(im.forTy, im.whr))))))
}
fun printImpl(im: ImplDecl): Int {
  printAnnos(0, im.annos)
  line(0, implHead(im))
  printAssoc(im.assoc)
  var j = 0
  while (j < listLen(im.methods)) { val m: Func = listGet(im.methods, j) ; printFuncAt(1, m) ; j = j + 1 }
  println("")
  return 0
}
```
**`main()` rewrite (folds in leading-annotation parse + all new keywords):**
```kite
fun main(): Int {
  val src = readFile("/tmp/kparse_input.kite")
  val p = P(lex(src), 0)
  var count = 0
  var go = 1
  while (go == 1) {
    if (pk(p) == 0) { go = 0 }
    else {
      val annos = parseAnnos(p)
      val k = pk(p)
      if (k == 10) { printFunc(parseFunc(p, annos)) ; count = count + 1 }              // fun
      else { if (k == 54) { printTDecl(parseTypeDecl(p, annos, 0)) ; count = count + 1 }   // struct
      else { if (k == 65) { printTDecl(parseTypeDecl(p, annos, 1)) ; count = count + 1 }   // class
      else { if (k == 55) { printEDecl(parseEnum(p, annos)) ; count = count + 1 }          // enum
      else { if (k == 66) { printTrait(parseTrait(p, annos)) ; count = count + 1 }         // trait
      else { if (k == 67) { printImpl(parseImpl(p, annos)) ; count = count + 1 }           // impl
      else { if (k == 58) { line(0, concat("import ", parseImport(p))) ; println("") ; count = count + 1 }
      else { go = 0 } } } } } } }
    }
  }
  return count
}
```
**Probes:** `probe_impl.kite` — `impl Show for Point { fun show(self): String = "p" }`;
`impl<T> Container<T> for Box<T> where T: Clone { type Item = T ; fun get(self): T = self.v }`;
`impl Point { fun origin(): Point = Point(0, 0) }`;
`@derive(Eq) impl<T> Iterator<T> for Range<T> where T: Step { type Item = T ; @inline fun next(mut self): T = self.lo }`.

---

### SLICE 14 — String interpolation  *(HIGH; do last)*

**Constructs:** `"a $x b"`, `"sum ${a + b}!"`, `"n=${xs[i]}"`; a plain `"..."` (no `$`) stays a
`StringLit`.
**Boundary resolution (interpolation appears in BOTH expr-sugar §10 and architecture §risks):**
kparse's `Tok` is flat and cannot carry nested token lists, so use **parser-side splitting
(expr-sugar Option A)**: the lexer tags an interpolated string as **kind 15**, keeping the
**raw body** (including `$` / `${…}`) in `text`; a parser-side splitter walks the body,
emitting `ILit` chunks and, per `$ident` / `${expr}` code chunk, `IExpr(parseInterpSub(chunk))`
where `parseInterpSub` re-lexes+parses the chunk with a fresh `P`. This keeps `Tok` flat and
mirrors `parse_interp_sub` (parser.ml 269).
**AST:** `EInterp(List)` (List<IPart>); `enum IPart { ILit(String); IExpr(Expr) }`.
**Printer:** `interp`; per part `lit "<%S>"`@+1 or `expr`@+1 e@+2. Verified §7.3.
**Lexer:** in the `"` branch, scan the body; if an **unescaped** `$` is present, emit kind 15
with the raw body; else kind 4 (STRING) as today.

**Draft — expression pieces (the byte-splitter is the interp lexer's companion):**
```kite
fun parseInterpSub(src: String): Expr {             // re-lex+parse one embedded code chunk
  val sp = P(lex(src), 0)
  return parseExpr(sp)
}
// primary branch (option A): interpParts(p) splits the raw kind-15 body into List<IPart>,
// calling parseInterpSub on each $ident / ${...} chunk.
if (k == 15) { val parts = interpParts(p) ; eat(p) ; return EInterp(parts) }

fun printInterp(ind: Int, parts: List): Int {
  line(ind, "interp")
  var i = 0
  while (i < listLen(parts)) {
    val pt: IPart = listGet(parts, i)
    when (pt) {
      ILit(s)  -> line(ind + 1, concat("lit \"", concat(escStr(s), "\"")))
      IExpr(e) -> printInterpExpr(ind, e)
      else -> 0
    }
    i = i + 1
  }
  return 0
}
fun printInterpExpr(ind: Int, e: Expr): Int { line(ind + 1, "expr") ; printExpr(ind + 2, e) ; return 0 }
```
**`%S` caveat:** printer.ml emits `lit`/`string` text with OCaml `%S` escaping. kparse's raw
pass-through **coincides** with `%S` for the corpus and standard escapes (`\t \n \"` verified),
but diverges for literally-typed control chars / lone backslashes. Implement a shared
`escStr`/string-quoting helper (used by `EStr`, `PStr`, and interp `lit`) if a probe surfaces a
divergence; otherwise raw pass-through is acceptable (see §8). Splitting the raw body must also
respect `\$` (an escaped `$` is a literal, not an interpolation) and `\\`.
**Probes:** `probe_interp.kite` — `"hello $x world"`, `"sum ${a + b}!"`, `"plain"` (stays
`string`), `"n=${xs[i]}"`, `"$x$y"`, `"pre ${f(1)} post"`.

---

## 5. TEST HARNESS

**Mechanics (verified live):** the oracle prints the reference AST to **stdout**. `main.exe run
stage1/kparse.kite` recompiles `kparse.kite` to a native `stage1/kparse.out` and runs it; the
Kite parser reads the **hardcoded path `/tmp/kparse_input.kite`** and prints to stdout,
appending one trailer line `kparse.out -> exit code <N>` that must be stripped. Build the
oracle once and call the binary directly (avoids dune's lock + rebuild).

```bash
export PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH"
cd /Users/john/AndroidStudioProjects/Language
dune build                                       # once
EXE=/Users/john/AndroidStudioProjects/Language/_build/default/bin/main.exe
```

**Single-probe diff:**
```bash
PROBE=/tmp/probe_x.kite
"$EXE" parse "$PROBE" > /tmp/ref.txt 2>/tmp/ref.err               # ORACLE (reference)
cp "$PROBE" /tmp/kparse_input.kite
"$EXE" run stage1/kparse.kite 2>/dev/null \
  | sed '/kparse\.out -> exit code/d'  > /tmp/got.txt             # KITE parser (got)
diff -u /tmp/ref.txt /tmp/got.txt && echo "OK: $PROBE"
```
(If the oracle *rejects* a probe, `/tmp/ref.err` holds the `parse error` — that marks a
grammar boundary from §1.4; record it, do not treat it as a parser bug.)

**Regression driver (corpus + probes) — the acceptance gate for every slice:**
```bash
run1() { "$EXE" parse "$1" >/tmp/ref.txt 2>/dev/null
         cp "$1" /tmp/kparse_input.kite
         "$EXE" run stage1/kparse.kite 2>/dev/null | sed '/kparse\.out -> exit code/d' >/tmp/got.txt
         if diff -q /tmp/ref.txt /tmp/got.txt >/dev/null; then echo "PASS $1"
         else echo "FAIL $1"; diff -u /tmp/ref.txt /tmp/got.txt | head -40; fi; }
for f in stage1/*.kite /tmp/probe_*.kite; do run1 "$f"; done
```
A slice is **done** when its probe diffs clean **and** every `stage1/*.kite` still PASSES.
Verified today: `stage1/lex.kite`, `stage1/tokenize.kite`, `stage1/toklist.kite` PASS with the
current `kparse.kite`. **Important:** exclude `stage1/kparse.kite` itself from the corpus run
only if it uses full-language surface it does not yet self-parse; today it is plain-subset, so
it should round-trip once each slice lands (a good self-parse smoke test).

**Probe-file plan (one construct group each, minimal + edge-heavy; run each through the oracle
alone first to freeze its reference):**

| Probe file | Slice | Covers |
|---|---|---|
| `probe_types.kite` | 1 | function types, paths, generic args, nullable |
| `probe_lit.kite` | 2 | char (+escapes), float `%g`, string escapes |
| `probe_null.kite` / `probe_post.kite` | 3 | `?.` `?:` `!!`; index chain, turbofish |
| `probe_coll.kite` | 4 | list `[]`/`[…]`, map, nested, index |
| `probe_namedargs.kite` | 5 | named + positional args |
| `probe_lambda.kite` | 6 | lambdas, `{it}` block-edge, trailing lambda |
| `probe_patterns.kite` | 7 | record/char/float/negative patterns, `..`-last |
| `probe_generics.kite` / `probe_anno.kite` | 8 | decl generics/where; annotations |
| `probe_fun.kite` | 9 | receivers, param modes, generics both positions |
| `probe_class.kite` | 10 | struct/class body, deinit, methods |
| `probe_enum.kite` | 11 | none/positional/named payloads, generics |
| `probe_trait.kite` | 12 | supers, where, assoc, sig-only + default |
| `probe_impl.kite` | 13 | trait impl, inherent, assoc bindings |
| `probe_interp.kite` | 14 | interpolation, plain-string edge |

---

## 6. RISKS / OPEN QUESTIONS

1. **Token-number reconciliation (RESOLVED here).** The area analyses used mutually
   conflicting kind numbers. §3.1 is the single source of truth; implement against it, not the
   per-area numbers. Biggest shifts vs the source drafts: INTERP `9`→`15` (CHAR takes `9`);
   `[`/`]`/`?.`/`?:`/`!!` → `74/75/76/77/78`; `@` → `73` (not `65`; `65` is `class`).

2. **`%g` float edge cases.** `fmtFloat` (Slice 2) reproduces `%g` for the well-formed
   `d+.d+` decimals the lexer produces (verified `1.0→1`, `100.0→100`, `0.5→0.5`,
   `10.25→10.25`). It will **diverge** from OCaml `%g` for magnitudes that `%g` renders in
   scientific notation (e.g. `1000000.0 → 1e+06`) or with >6 significant figures
   (`1.2345678 → 1.23457`). No such literal is known in the corpus; add a targeted probe if one
   appears. Open question: does any intended full-language corpus file contain such floats?

3. **`%S` string/`lit` escaping.** kparse stores raw string bytes and prints them verbatim;
   the oracle decodes escapes then re-encodes via `%S`. These **coincide** for the corpus and
   for `\t \n \" \\` (verified), so no dedicated slice is required. They diverge for literally-
   typed control characters and unusual escapes. If a probe surfaces this, add a shared
   `escStr` helper (used by `EStr`, `PStr`, and interp `lit`) implementing `%S` semantics
   (`"`→`\"`, `\`→`\\`, `\n`→`\n`, `\t`→`\t`, `\r`→`\r`, other `<0x20`→`\NNN` decimal). Interp
   `lit` chunks share this helper.

4. **`{` ambiguity (block vs lambda vs trailing lambda).** `tryLambdaParams` backtracks via
   `p.pos` save/restore. Risk: because kparse has no NEWLINE, **any** primary immediately
   followed by `{` becomes a trailing-lambda call (matching the oracle's ATI-mitigated
   grammar). The corpus has no trailing lambdas, so this cannot regress it, but re-run the
   **full** corpus after Slice 6 to confirm no block is mis-joined. The `{ it }`-is-a-block
   edge (primary position) vs `f { it }`-is-a-lambda (trailing position) is intrinsic — keep
   the two code paths distinct.

5. **Named-args regression surface.** Slice 5 changes `ECall`'s arg element type (Expr→Arg)
   and rewrites `printCall`; every positional call in the corpus must print identically. This
   is the highest-regression-risk expression slice — gate it hard on the corpus.

6. **Interpolation byte-splitter (Slice 14).** The one genuinely new lexer/parser interaction.
   The `interpParts` splitter must honor `\$` (escaped `$` = literal) and `\\`, match `$ident`
   vs `${ balanced-braces }`, and re-lex each code chunk. This is the highest-risk slice; keep
   it last and probe it in isolation before integrating.

7. **Statement/arm termination without ATI (structural strategy).** kparse separates
   statements and `when` arms purely from structural tokens (no NEWLINE). This already works
   for the whole subset; the full grammar keeps the same strategy. The theoretical hazard is a
   full-language construct where the oracle's ATI keeps two things separate that kparse's
   brace-structural approach mis-joins — none is known, but the full-corpus gate after each
   slice is the guard.

8. **`self` keyword-ization.** Adding `self`=69 removes `self` from the identifier space.
   Verified no corpus file uses `self` (or the other new keywords) as an identifier (comment
   mentions of "self-hosting" are stripped before `kw`). Confirm again if new corpus files are
   added.

9. **Non-goals must stay rejected (§1.4).** Do not add code paths for `as`, `=>`, `@file:`,
   named annotation args, import grouping/glob/rename, type-grouping parens, `enum` `where`, or
   top-level `val`/`var`. Byte-matching the oracle means producing the same *rejections* — but
   note kparse never raises; it silently mis-consumes. Where the oracle rejects, kparse's job
   is only to not appear in the diff corpus (such inputs are excluded), so no explicit error
   path is needed.
