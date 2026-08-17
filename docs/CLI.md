# kitec — the Kite compiler CLI

`kitec` compiles a Kite source file to a **signed native arm64 Mach-O binary**.

## Usage

```
kitec [options] <input.kite>
```

| option | meaning |
|---|---|
| `-o <file>`     | output path (default: the input with `.kite` stripped, e.g. `foo.kite` → `foo`) |
| `check`         | type-check only; print diagnostics, write no binary |
| `--no-check`    | skip the type-check pass and compile anyway |
| `--emit-funcs`  | print the lowered function/struct counts |
| `-O0` / `-O1`   | disable / enable the peephole optimizer (default `-O1`) |
| `--version`     | print the compiler version |
| `-h`, `--help`  | show help |

The output also accepts a second positional argument: `kitec in.kite out` is the same as
`kitec in.kite -o out`. `kitec` does **not** set the executable bit — `chmod +x` the result yourself.

## Examples

```sh
kitec hello.kite              # writes ./hello
chmod +x hello && ./hello

kitec src/app.kite -o build/app     # explicit output
kitec check src/app.kite            # CI-style: no binary, non-zero exit on errors
kitec app.kite --no-check           # compile without the type-check pass
kitec app.kite -O0                  # skip the peephole optimizer
```

On success `kitec` exits `0` (add `--emit-funcs` to see `wrote <path>`). A type error prints
`error: …` then `N error(s); no binary written`, writes no binary, and exits with the error count.

## Implementation note

Kite `main` is `fun main(argc: Int, argv: Int): Int`. macOS hands `_main` the argument count in `x0`
and `argv` (a `char**`) in `x1` — the first two argument registers — so `main` receives them directly;
`__argv(argv, i)` reads `argv[i]` as a `String`. Programs that take no arguments may still declare the
zero-parameter `fun main(): Int`.
