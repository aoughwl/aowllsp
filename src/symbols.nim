## symbols.nim — LSP documentSymbol / workspaceSymbol via the `aowllens` CLI.
##
## `aowllens decls <file.s.nif>` prints a JSON array of declaration records
## `{"sym","name","kind","file","line","col"}` read off a sem'd NIF artifact
## (line 1-based, col 0-based). We shell out through aowlkit, parse the JSON
## with nimony's lazy-cursor std/json (scalars extracted DURING iteration only),
## and hand-build the LSP JSON reply.

import std/[syncio, strutils, json, os, dirs, paths]
import state, protocol, driver, uris
import aowlkit/json as ajson
import aowlkit/subprocess

# --- small helpers (nimony has no join, stricter than Nim 2) ---------------

proc baseName(p: string): string =
  var i = p.len - 1
  while i >= 0 and p[i] != '/': dec i
  if i < 0: p else: substr(p, i + 1, p.len - 1)

proc among(s: string; xs: openArray[string]): bool =
  for x in xs:
    if s == x: return true
  false

proc lowerAscii(s: string): string =
  result = ""
  for i in 0 ..< s.len:
    let c = s[i]
    if c >= 'A' and c <= 'Z': result.add chr(ord(c) + 32)
    else: result.add c

proc containsSub(hay, needle: string): bool =
  ## Case-sensitive substring test (callers lower-case first for ci matching).
  if needle.len == 0: return true
  if needle.len > hay.len: return false
  var i = 0
  while i + needle.len <= hay.len:
    var j = 0
    while j < needle.len and hay[i + j] == needle[j]: inc j
    if j == needle.len: return true
    inc i
  false

# --- NIF tag -> LSP SymbolKind ---------------------------------------------

proc kindToLsp(kind: string): int =
  ## LSP SymbolKind: Class=5, Constant=14, Variable=13, Function=12, ...
  if among(kind, ["proc", "func", "method", "converter", "macro",
                  "template", "iterator"]):
    12                                    # Function
  elif kind == "type":
    5                                     # Class
  elif among(kind, ["let", "const", "glet"]):
    14                                    # Constant
  elif among(kind, ["var", "gvar"]):
    13                                    # Variable
  else:
    13                                    # Variable (params, results, efld, ...)

# --- one artifact's decls -> a builder callback -----------------------------

type DeclRec = object
  name: string
  kind: string
  file: string
  line: int
  col: int
  sawLine: bool

proc runDecls(cfg: Config; snif: string): seq[DeclRec] =
  ## Parse `aowllens decls <snif>` into flat records. Empty on any failure.
  result = @[]
  if cfg.aowllensExe.len == 0 or snif.len == 0: return
  let cap = runCaptured(cfg.aowllensExe, @["decls", snif], "", false)
  if not cap.ok or cap.output.len == 0: return
  var tree = default(JsonTree)
  try:
    tree = parseJson(cap.output)
  except:
    return
  let arr = tree.root
  if arr.kind != JArray: return
  for el in items(arr):
    if el.kind != JObject: continue
    var rec = DeclRec(name: "", kind: "", file: "", line: 0, col: 0,
                      sawLine: false)
    for k, v in pairs(el):
      case k
      of "name": rec.name = v.getStr
      of "kind": rec.kind = v.getStr
      of "file": rec.file = v.getStr
      of "line":
        rec.line = int(v.getInt); rec.sawLine = true
      of "col": rec.col = int(v.getInt)
      else: discard
    result.add rec

proc lineRange(line, col: int): Range =
  ## aowllens: line 1-based, col 0-based -> LSP 0-based range on that name.
  let l = if line > 0: line - 1 else: 0
  mkRange(l, col, l, col)

# --- documentSymbol ---------------------------------------------------------

proc documentSymbols*(cfg: Config; file: string): string =
  ## Returns a JSON array (string) of LSP DocumentSymbol[] for `file`.
  let snif = mainArtifact(cfg, file, ".s.nif")
  let recs = runDecls(cfg, snif)
  let want = baseName(file)
  var parts: seq[string] = @[]
  for i in 0 ..< recs.len:
    let r = recs[i]
    if not r.sawLine: continue
    if r.name.len == 0: continue
    if baseName(r.file) != want: continue
    let rj = rangeJson(lineRange(r.line, r.col))
    parts.add "{\"name\":" & ajson.jStr(r.name) &
      ",\"kind\":" & $kindToLsp(r.kind) &
      ",\"range\":" & rj &
      ",\"selectionRange\":" & rj & "}"
  result = "["
  for i in 0 ..< parts.len:
    if i > 0: result.add ","
    result.add parts[i]
  result.add "]"

# --- workspaceSymbol --------------------------------------------------------

proc gatherSnifs(cfg: Config): seq[string] =
  ## Every `*.s.nif` under <projectRoot>/nimcache/lsp/*/.
  result = @[]
  let base = cfg.projectRoot & "/nimcache/lsp"
  if not dirExists(base): return
  try:
    for k, sub in walkDir(path(base)):
      if k != pcDir: continue
      let subs = $sub
      try:
        for k2, f in walkDir(path(subs)):
          if k2 != pcFile: continue
          let fs = $f
          if endsWith(fs, ".s.nif"): result.add fs
      except:
        discard
  except:
    discard

proc workspaceSymbols*(cfg: Config; query: string): string =
  ## Returns a JSON array (string) of LSP SymbolInformation[] matching `query`.
  let snifs = gatherSnifs(cfg)
  let q = lowerAscii(query)
  const cap = 500
  var parts: seq[string] = @[]
  var seenKeys: seq[string] = @[]
  for si in 0 ..< snifs.len:
    if parts.len >= cap: break
    let recs = runDecls(cfg, snifs[si])
    for i in 0 ..< recs.len:
      if parts.len >= cap: break
      let r = recs[i]
      if not r.sawLine: continue
      if r.name.len == 0 or r.file.len == 0: continue
      if not containsSub(lowerAscii(r.name), q): continue
      let key = r.name & "\x00" & r.file & "\x00" & $r.line
      if among(key, seenKeys): continue
      seenKeys.add key
      let uri = pathToUri(r.file)
      let loc = Location(uri: uri, rng: lineRange(r.line, r.col))
      parts.add "{\"name\":" & ajson.jStr(r.name) &
        ",\"kind\":" & $kindToLsp(r.kind) &
        ",\"location\":" & locationJson(loc) & "}"
  result = "["
  for i in 0 ..< parts.len:
    if i > 0: result.add ","
    result.add parts[i]
  result.add "]"
