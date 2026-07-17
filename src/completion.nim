## completion.nim — LSP textDocument/completion.
##
## Gathers candidate symbols from the `aowllens` NIF-artifact reader (the same
## seam navigation uses) and filters them by the identifier prefix under the
## cursor. Candidates come from three places, unioned + deduped by name:
##   1. `aowllens decls <snif>` on THIS file's main artifact — its own decls.
##   2. `aowllens index <snif>` on the same artifact — the module's exports.
##   3. `aowllens decls` on EVERY `*.s.nif` under `<projectRoot>/nimcache/lsp/`
##      — so symbols from imported modules are offered too.
##
## LIMITATIONS (honest scope):
##   * No scope-awareness — every module-level symbol in the warm cache is a
##     candidate regardless of whether it is actually visible at the cursor.
##   * `.`-member access is treated exactly like plain prefix completion: we do
##     NOT resolve the receiver's type and offer only its fields/methods; the
##     prefix after the dot just filters the same global candidate pool.
##   * Filtering is a case-sensitive prefix match on the demangled name.

import std/[strutils, os, dirs, paths, tables, sets, json]
import state, driver
import aowlkit/json
import aowlkit/subprocess

# ── LSP CompletionItemKind mapping ──────────────────────────────────────────

proc among(s: string; xs: openArray[string]): bool =
  for i in 0 ..< xs.len:
    if xs[i] == s: return true
  return false

proc kindToLsp(kind: string): int =
  ## NIF decl tag → LSP CompletionItemKind int.
  if among(kind, ["proc", "func", "method", "converter", "iterator",
                  "template", "macro"]):
    3            # Function
  elif among(kind, ["type", "object"]):
    7            # Class
  elif kind == "enum":
    13           # Enum
  elif among(kind, ["let", "glet", "const"]):
    21           # Constant
  elif among(kind, ["var", "gvar"]):
    6            # Variable
  else:
    1            # Text

# ── prefix extraction ───────────────────────────────────────────────────────

proc isIdentChar(c: char): bool =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
  (c >= '0' and c <= '9') or c == '_'

proc reversed(s: string): string =
  result = ""
  var i = s.len - 1
  while i >= 0:
    result.add s[i]
    dec i

proc prefixAt(bufferText: string; line, col: int): string =
  ## The identifier characters immediately to the left of (line, col).
  var lines = split(bufferText, '\n')
  if line < 0 or line >= lines.len: return ""
  let ln = lines[line]
  var c = col
  if c > ln.len: c = ln.len
  if c < 0: c = 0
  var acc = ""
  var i = c - 1
  while i >= 0 and isIdentChar(ln[i]):
    acc.add ln[i]
    dec i
  result = reversed(acc)

# ── candidate collection ────────────────────────────────────────────────────

proc addCand(name, kind, sym: string; prefix: string;
             seen: var HashSet[string]; names: var seq[string];
             kindOf: var Table[string, int]; detailOf: var Table[string, string]) =
  if name.len == 0: return
  # Skip compiler-internal locals that are never useful completions.
  if among(kind, ["result", "param"]): return
  if prefix.len > 0 and not startsWith(name, prefix): return
  if seen.containsOrIncl(name): return
  names.add name
  kindOf[name] = kindToLsp(kind)
  detailOf[name] = if kind.len > 0: kind else: sym

proc collectDecls(cfg: Config; snif, prefix: string;
                  seen: var HashSet[string]; names: var seq[string];
                  kindOf: var Table[string, int];
                  detailOf: var Table[string, string]) =
  ## `aowllens decls <snif>` → a JSON array of {sym,name,kind,file,line,col}.
  if cfg.aowllensExe.len == 0 or snif.len == 0: return
  let cap = runCaptured(cfg.aowllensExe, @["decls", snif], "", true)
  if not cap.ok: return
  var tree = default(JsonTree)
  try:
    tree = parseJson(cap.output)
  except:
    return
  var arr = tree.root
  if kind(arr) != JArray: return
  for el in items(arr):
    if kind(el) != JObject: continue
    var name = ""
    var kd = ""
    var sym = ""
    for k, v in pairs(el):
      case k
      of "name": name = getStr(v)
      of "kind": kd = getStr(v)
      of "sym": sym = getStr(v)
      else: discard
    addCand(name, kd, sym, prefix, seen, names, kindOf, detailOf)

proc collectExports(cfg: Config; snif, prefix: string;
                    seen: var HashSet[string]; names: var seq[string];
                    kindOf: var Table[string, int];
                    detailOf: var Table[string, string]) =
  ## `aowllens index <snif>` → an OBJECT with an "exports" array of {sym,name,kind}.
  if cfg.aowllensExe.len == 0 or snif.len == 0: return
  let cap = runCaptured(cfg.aowllensExe, @["index", snif], "", true)
  if not cap.ok: return
  var tree = default(JsonTree)
  try:
    tree = parseJson(cap.output)
  except:
    return
  var obj = tree.root
  if kind(obj) != JObject: return
  for k, v in pairs(obj):
    if k != "exports": continue
    if kind(v) != JArray: continue
    for el in items(v):
      if kind(el) != JObject: continue
      var name = ""
      var kd = ""
      var sym = ""
      for k2, v2 in pairs(el):
        case k2
        of "name": name = getStr(v2)
        of "kind": kd = getStr(v2)
        of "sym": sym = getStr(v2)
        else: discard
      addCand(name, kd, sym, prefix, seen, names, kindOf, detailOf)

proc lspSnifs(cfg: Config): seq[string] =
  ## Every `*.s.nif` under `<projectRoot>/nimcache/lsp/` (one dir per module).
  result = @[]
  let root = if cfg.projectRoot.len > 0: cfg.projectRoot else: "."
  let base = root & "/nimcache/lsp"
  if not dirExists(base): return
  try:
    for kind, p in walkDir(path(base)):
      let ps = $p
      if kind == pcFile:
        if endsWith(ps, ".s.nif") and not endsWith(ps, ".s.idx.nif"):
          result.add ps
      elif kind == pcDir:
        try:
          for k2, f in walkDir(path(ps)):
            if k2 == pcFile:
              let fs = $f
              if endsWith(fs, ".s.nif") and not endsWith(fs, ".s.idx.nif"):
                result.add fs
        except:
          discard
  except:
    discard

# ── sort (selection, ascending, case-sensitive) ─────────────────────────────

proc sortNames(names: var seq[string]) =
  for a in 0 ..< names.len:
    var best = a
    for b in a + 1 ..< names.len:
      if names[b] < names[best]: best = b
    if best != a:
      let tmp = names[a]
      names[a] = names[best]
      names[best] = tmp

# ── public entry ────────────────────────────────────────────────────────────

proc completions*(cfg: Config; file: string; line, col: int;
                  bufferText: string): string =
  ## Returns `{"isIncomplete":false,"items":[ CompletionItem... ]}` as a string.
  ## line/col are 0-based (LSP). See module doc for scope limitations.
  const cap = 200
  let prefix = prefixAt(bufferText, line, col)

  var seen = initHashSet[string]()
  var names: seq[string] = @[]
  var kindOf = initTable[string, int]()
  var detailOf = initTable[string, string]()

  # 1+2: this file's own decls and exports.
  let mine = mainArtifact(cfg, file, ".s.nif")
  collectDecls(cfg, mine, prefix, seen, names, kindOf, detailOf)
  collectExports(cfg, mine, prefix, seen, names, kindOf, detailOf)

  # 3: decls from every module in the warm LSP cache (imported symbols).
  let snifs = lspSnifs(cfg)
  for i in 0 ..< snifs.len:
    if names.len >= cap and prefix.len == 0: break
    collectDecls(cfg, snifs[i], prefix, seen, names, kindOf, detailOf)

  sortNames(names)
  if names.len > cap:
    names.setLen(cap)

  var items = ""
  for i in 0 ..< names.len:
    let nm = names[i]
    let ki = getOrDefault(kindOf, nm, 1)
    let dt = getOrDefault(detailOf, nm, "")
    if items.len > 0: items.add ","
    items.add "{\"label\":" & jStr(nm) &
              ",\"kind\":" & $ki &
              ",\"detail\":" & jStr(dt) & "}"
  result = "{\"isIncomplete\":false,\"items\":[" & items & "]}"
