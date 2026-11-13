# aowllsp

A **Language Server for aowlmony, written in aowlmony.** Its only hard runtime
dependency is the `aowlmony` binary; three optional helper CLIs
(`aowllens`, `aowlsuggest`, `aowlfmt`) switch on the richer features and are
found next to the server exe (or via `AOWLLENS` / `AOWLSUGGEST` / `AOWLFMT`).
A missing helper turns its features off silently -- it never crashes the server.

Windows is the target platform; every path inside the server is `/`-separated
with an upper-case drive letter, and `file:///c%3A/x` and `file:///C:/x` are the
same buffer.

## What works

Verified by `tests/smoke.sh` (one scripted, Content-Length framed session against
the real exe; 60 checks when all three helpers are present):

| group | methods | needs |
|-------|---------|-------|
| lifecycle | `initialize` (+ capabilities, `initializationOptions`), `initialized`, `shutdown`, `exit`, unknown requests answered `null` | -- |
| document sync | `didOpen` / `didChange` (full) / `didSave` / `didClose`, UTF-16 <-> byte columns | -- |
| diagnostics | push (`publishDiagnostics`) and pull (`textDocument/diagnostic`) from `aowlmony check` over the **live, unsaved buffer**; `Trace` lines become `relatedInformation` | aowlmony |
| navigation | `definition`, `declaration`, `typeDefinition`, `implementation`, `references`, `documentHighlight`, `hover`, `prepareRename` / `rename`, `signatureHelp` via `aowlmony check --def/--usages` | aowlmony |
| text-only | `foldingRange`, `selectionRange`, `documentLink` | -- |
| symbols and tokens | `documentSymbol`, `workspace/symbol`, `semanticTokens/full`, `completion` (plain and type-directed member completion), `codeLens` + resolve, `inlayHint`, call hierarchy, type hierarchy | aowllens |
| syntax diagnostics, code actions | recovering syntax errors over the live buffer (rule id in `code`), `quickfix`, `source.fixAll` | aowlsuggest |
| formatting | `formatting`, `rangeFormatting` | aowlfmt |

Degraded without a helper: its methods answer an empty result (`[]` / `null`).
`aowlfmt` has no aowlmony port yet, so formatting is currently off unless you
point `AOWLFMT` at one.

`initializationOptions`: `aowlmonyExe`, `aowlsuggestExe`, `aowllensExe`,
`aowlfmtExe`, `extraPaths`, `pedantic` (aowlsuggest's safe style set) and
`style` (per-category opt-in).

## Architecture -- the subprocess seam

Everything semantic goes through `src/driver.aowl`, which runs `aowlmony` and
captures its output whole (via a temp file; pipes mangle long single-line JSON).
Each open file is checked as its own main module into an isolated cache under
`<projectRoot>/.aowllsp/cache/<mangled>/`. Tracked queries (`--def` / `--usages`)
and live-buffer checks get their own sibling caches (`-nav`, `-live`,
`-livenav`): the compiler invalidates the whole sem step when the command line
changes, so mixing them in one cache makes every request cold (~5 s instead of
~0.5 s). The pool is bounded (LRU eviction on `didClose`).

That seam is deliberate: a browser build swaps `driver.run` for in-process
parser/sem calls and the modules above it do not change.

JSON: reading uses `jsonref`; writing is hand-built text (`src/util.aowl`:
`jStr`, `jBool`, `jArr`). `util.aowl` also holds the whole-output subprocess
capture and temp paths -- it replaces the retired `aowlkit` library, so there is
no dependency on it.

## Layout

| file | role |
|------|------|
| `src/aowllsp.aowl` | entry: message loop, lifecycle, dispatch |
| `src/framing.aowl` | Content-Length framed stdio transport (binary-mode stdio on Windows) |
| `src/protocol.aowl` | LSP value types + JSON serialization |
| `src/document.aowl` | text buffer + UTF-16 <-> byte mapping |
| `src/state.aowl` | config, tool discovery, open-document registry |
| `src/uris.aowl` | `file://` URI <-> path (Windows drive letters) |
| `src/util.aowl` | JSON text builders, subprocess capture, temp paths |
| `src/driver.aowl` | the `aowlmony` subprocess seam (per-module caches) |
| `src/diagnostics.aowl` | parse `aowlmony check` output |
| `src/idetools.aowl` | parse `--def` / `--usages` records |
| `src/syntaxdiag.aowl`, `src/codeactions.aowl` | `aowlsuggest` adapters |
| `src/symbols.aowl`, `src/semtokens.aowl`, `src/completion.aowl`, `src/typeinfo.aowl`, `src/callhier.aowl`, `src/typehier.aowl` | `aowllens` adapters |
| `src/formatting.aowl` | `aowlfmt` adapter |
| `src/hints.aowl`, `src/renamehl.aowl`, `src/structure.aowl` | signature help / lenses / links, rename + highlight, folding + selection |

## Build and test

```sh
bash build.sh          # -> bin/aowllsp.exe   (aowlmony only; fails loudly if no exe)
bash tests/smoke.sh    # builds the aowlmony test client and runs one scripted session
```

`build.sh` runs `aowlmony.exe c -d:release --path:<jsonref> --path:src aowllsp.aowl`
with `AOWLMONY_ROOT` set (defaults: `~/dev/toolchain/aowlmony/root`,
`~/dev/jsonref/src`; override with `AOWLMONY_ROOT` / `AOWLJSONREF`). To enable the
optional features, copy `aowllens.exe` / `aowlsuggest.exe` / `aowlfmt.exe` into
`bin/`.

Point your editor's LSP client at `bin/aowllsp.exe` for `.aowl` files.
