# Kite Language — VS Code extension

Syntax highlighting, bracket/comment handling, and snippets for the Kite
programming language (`.kite`).

Kite is a Kotlin-flavored, ARC / no-GC systems language. The grammar here tracks
the bootstrap lexer in `lib/lexer.ml` and `lib/token.ml`.

## What it highlights

- **Keywords** — `fun val var struct class enum trait impl type import deinit`,
  control flow `if else when while for return break continue where`, and the
  word operators `is in as`.
- **Modifiers** — `pub mut consuming inout`.
- **Constants & self** — `true false null`, `this self`, and the `Self` type.
- **Types** — capitalized identifiers (`Vec2`, `Ordering::Greater`, `Self`),
  including enum variants.
- **Functions** — definition names after `fun` (including generic
  `fun <T: Ord> maxOf(...)`) and call sites.
- **Annotations** — `@derive(Eq, Ord, ...)`.
- **Numbers** — integers and floats (`1..5` stays a range, not a float).
- **Strings** — double-quoted with escapes, triple-quoted raw strings, and
  char literals, all with `$name` / `${ expr }` interpolation highlighted
  (the embedded expression is re-highlighted as Kite code).
- **Comments** — `//` line comments and **nested** `/* /* ... */ */` block
  comments.
- **Operators** — `-> => ?. ?: !! :: .. == != <= >= && ||` and friends.

## Install (local)

No build step — this is a declarative (grammar + config) extension.

**Option A — symlink into your extensions folder:**

```sh
ln -s "$(pwd)/editors/vscode-kite" ~/.vscode/extensions/kite-language-0.1.0
```

(For VS Code Insiders use `~/.vscode-insiders/extensions/`.)
Then reload VS Code (`Cmd/Ctrl+Shift+P` → *Developer: Reload Window*).

**Option B — package a `.vsix`:**

```sh
npm install -g @vscode/vsce
cd editors/vscode-kite
vsce package
code --install-extension kite-language-0.1.0.vsix
```

## Verify

Open any file under `examples/` or `stage1/`.
To inspect the scope under the cursor (useful when tuning colors or a theme),
run *Developer: Inspect Editor Tokens and Scopes* from the command palette.

## Notes / limitations

- Highlighting is lexical (TextMate), so it is heuristic: any capitalized
  identifier is colored as a type, and any lowercase identifier immediately
  before `(` as a function call. This matches Kite convention but is not a
  parser.
- `type` is a contextual (soft) keyword — it is a plain identifier in the
  lexer, highlighted here for readability of `trait` associated types.
