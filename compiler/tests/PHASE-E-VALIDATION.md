# Phase E — Kite Parser Adversarial Validation

> **STATUS: ALL 7 BUG CLASSES RESOLVED (2026-08-16).** After fixes, all 239 adversarial probes diff clean
> and the permanent suite `compiler/tests/run-parser-tests.sh` is 40/40. Fixes: parseBranch (if-expr non-brace
> branches); lexStr ${...} depth tracking (nested strings in interpolation); real %g in fmtFloat (scientific +
> 6-sig-fig rounding); escStr %S encode/decode (\$ → $, \0 → \000); $ident → EIdent (no keyword lookup); triple-
> quoted raw strings (kinds 16/17); trailing comma in call args. The findings below are the ORIGINAL report.

**Date:** 2026-08-16
**Under test:** `compiler/kparse` (built from `compiler/kparse.kite`)
**Oracle (ground truth):** `_build/default/bin/main.exe parse FILE` (OCaml parser)
**Method:** For every oracle-accepted probe `FILE.kite` (with sibling `FILE.ref` = oracle output),
`./compiler/kparse FILE | grep -v ' -> exit code ' > got.txt ; diff FILE.ref got.txt`
(kparse takes the source path from argv). Parallel-safe: the harness builds into a private `mktemp -d`
and passes each probe as an argument — no shared `/tmp` writer.

## Summary counts

| Metric | Count |
|---|---|
| Total probes tested | 239 |
| Byte-identical (CLEAN) | 225 |
| Divergent probes | 14 |
| — KNOWN_LIMITATION (K1/K2) hits | 0 |
| — REAL_BUG probe hits | 14 |
| Distinct REAL_BUG root causes | 7 |

Per-area: precedence 49/49 clean, patterns 39/40 (1 diverge), declarations 34/34 clean,
types 40/40 clean, sugar 39/40 (1 diverge), lexer-interp 24/36 (12 diverge).

**No K1 or K2 hits** — the generator agents deliberately avoided negative-literal `when`-arm
patterns and same-line trailing-lambda joins, so none of the 14 divergences are documented
known-limitations. **All 14 are REAL_BUGs.**

**VERDICT: BUGS FOUND: 7**

---

## REAL_BUGs (minimal repros, expected-vs-got)

### BUG 1 — `if`-expression with bare (non-brace) branches produces EMPTY output
Probes: `patterns/35`, `lexer-interp/34`. Root cause: `parseIf` (kparse.kite:364) unconditionally
calls `parseBlock` (kparse.kite:721) for the then/else branches, and `parseBlock` unconditionally
`eat`s a `{`. When a branch is a bare expression (`... 1 else 2`) instead of a `{ block }`, the token
stream desyncs and the whole parse silently yields nothing. `if` as a **statement** with brace bodies
works; only the **expression** form with non-brace branches breaks.

Minimal repro:
```
fun m(x: Int): Int { return if (x > 0) 1 else 2 }
```
Expected (oracle):
```
        return
          if
            binary >
              ident x
              int 0
            then
              int 1
            else
              int 2
```
Got (kparse): *(empty — no output at all)*

---

### BUG 2 — nested string literal inside `${ ... }` interpolation produces EMPTY output
Probes: `lexer-interp/12`, `lexer-interp/13`. Root cause: the string lexer (kparse.kite:133-137)
scans the outer string until the first unescaped `"`, without tracking `${...}` brace depth or the
quotes nested inside it. An inner `"` (e.g. `"inner=$y"`, `f("a{b}c")`) prematurely terminates the
outer string, desyncing the lexer and yielding no output. (The oracle's `${...}` scanner is
brace-counting and quote-blind, so it accepts these.)

Minimal repro:
```
fun m(y: Int): String { return "a${ "b$y" }c" }
```
Expected (oracle):
```
          interp
            lit "a"
            expr
              interp
                lit "b"
                expr
                  ident y
            lit "c"
```
Got (kparse): *(empty — no output at all)*

---

### BUG 3 — float printing does not implement OCaml `%g`
Probes: `lexer-interp/02`, `lexer-interp/03`. Root cause: `fmtFloat` (kparse.kite:975) only strips
trailing zeros and a lone `.`; it does not switch to exponential notation for large/small magnitudes
nor round to 6 significant figures the way OCaml's default `%g` (used by the oracle's printer) does.
Affects both `EFloat` expressions and `PFloatP` patterns.

Minimal repro:
```
fun m(): Float { return 1000000.0 }
```
Expected (oracle): `          float 1e+06`
Got (kparse):      `          float 1000000`

Other observed cases: `123456789.0` → oracle `1.23457e+08` / kparse `123456789`;
`1.2345678` → oracle `1.23457` / kparse `1.2345678`; `3.14159265` → oracle `3.14159` / kparse `3.14159265`.

---

### BUG 4 — string escape sequences not normalized to OCaml `String.escaped` form
Probes: `lexer-interp/15`, `lexer-interp/30` (`\$`), `lexer-interp/19` (`\0`). Root cause: the string
printer (kparse.kite:1000, and interp-literal chunks kparse.kite:520-521) emits the **raw source
substring** verbatim instead of decoding escapes and re-encoding via OCaml's `%S`/`String.escaped`.
Escapes whose source form already equals OCaml's escaped form round-trip fine (`\n \t \r \\ \"` — probe
18 is clean), but any escape that normalizes differently diverges:
- `\$` → oracle decodes to literal `$`; kparse keeps `\$`.
- `\0` → oracle re-encodes NUL as decimal `\000`; kparse keeps `\0`.

Minimal repro (`\$`):
```
fun m(): String { return "\$x" }
```
Expected (oracle): `          string "$x"`
Got (kparse):      `          string "\$x"`

Minimal repro (`\0`, from probe 19 `"a\0b\0c"`):
Expected (oracle): `      string "a\000b\000c"`
Got (kparse):      `      string "a\0b\0c"`

---

### BUG 5 — `$this` interpolation emits the `this` keyword instead of a plain identifier
Probe: `lexer-interp/17`. Root cause: the `$ident` path (kparse.kite:538-541) re-lexes/parses the
captured name through `parseInterpSub` → `parseExpr`, which recognizes `this` as the THIS keyword and
yields `EThis` (printed `this`). The oracle's `$name` capture bypasses keyword lookup, so `$this` is a
plain identifier.

Minimal repro:
```
fun m(): String { return "$this" }
```
Expected (oracle):
```
          interp
            expr
              ident this
```
Got (kparse):
```
          interp
            expr
              this
```

---

### BUG 6 — triple-quoted strings `""" ... """` are not supported
Probes: `lexer-interp/22`, `lexer-interp/23`, `lexer-interp/24`. Root cause: the lexer (kparse.kite:129)
treats every `"` as an ordinary single-quoted string start, so `"""hi"""` lexes as `""` (empty string) +
`"hi"` + `""`, splitting one string into three tokens and an extra statement. No triple-quote / raw-string
handling exists. The oracle supports triple-quoted raw multi-line strings.

Minimal repro:
```
fun m(): String { return """hi""" }
```
Expected (oracle): `          string "hi"`
Got (kparse):
```
          string ""
        expr-stmt
          string "hi"
        result
          string ""
```

---

### BUG 7 — trailing comma in call arguments injects a spurious empty argument
Probe: `sugar/18`. Root cause: the call-argument parser accepts a trailing `,` and then parses one more
argument, which degenerates to an empty `ident ` (`EIdent("")`). The resulting token-stream desync also
demotes the following `return 0` statement to a block **result** expression.

Minimal repro:
```
fun m(): Int { val r = f(a,) return 0 }
```
Expected (oracle):
```
      call
        ident f
        args
          ident a
    return
      int 0
```
Got (kparse):
```
      call
        ident f
        args
          ident a
          ident 
    result
      int 0
```

---

## KNOWN_LIMITATION hits

None. Zero probes exercised K1 (negative-literal `when`-arm pattern after a bare-expression body) or
K2 (trailing-lambda open-brace after a primary) — the generators intentionally kept those out of the
oracle-accepted set. K3 (extension-fn receivers) is an oracle grammar boundary and was not probed.

## Probe → bug map

| Bug | Probes |
|---|---|
| 1 if-expr bare branches | patterns/35, lexer-interp/34 |
| 2 nested string in `${}` | lexer-interp/12, lexer-interp/13 |
| 3 float `%g` | lexer-interp/02, lexer-interp/03 |
| 4 string escape normalization | lexer-interp/15, lexer-interp/19, lexer-interp/30 |
| 5 `$this` keyword vs ident | lexer-interp/17 |
| 6 triple-quoted strings | lexer-interp/22, lexer-interp/23, lexer-interp/24 |
| 7 trailing comma in call args | sugar/18 |
