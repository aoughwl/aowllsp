## typehier.nim — LSP type hierarchy, mirroring callhier but over inheritance
## edges instead of call edges.
##
##   * prepareTypeHierarchy — resolve the type under the cursor to a
##     TypeHierarchyItem, stashing its declaration position in `data`.
##   * supertypes — the type's direct parent (`object of Parent`).
##   * subtypes — every type that inherits from it.
##
## Both directions read the inheritance table from `aowllens types <snif>`
## (records {type,name,parent,parentName,line,col}). Degrades to an empty list
## when that command is unavailable, so it's never wrong, only sometimes empty.

import std/[strutils, json]
import protocol, state, uris, driver, idetools, symbols
import aowlkit/json as ajson
import aowlkit/subprocess

proc baseSym(sym: string): string =
  var i = 0
  while i < sym.len and sym[i] != '.': inc i
  substr(sym, 0, i - 1)

proc itemJson(name: string; uri: string; rng: Range;
              dataUri: string; dataLine, dataCol: int): string =
  ## A TypeHierarchyItem (kind 5 = Class) carrying the def position in `data`.
  let r = rangeJson(rng)
  result = "{\"name\":" & ajson.jStr(name) & ",\"kind\":5" &
    ",\"uri\":" & ajson.jStr(uri) & ",\"range\":" & r & ",\"selectionRange\":" & r &
    ",\"data\":{\"uri\":" & ajson.jStr(dataUri) & ",\"line\":" & $dataLine &
    ",\"character\":" & $dataCol & "}}"

type TypeRec = object
  typ: string       ## full type sym
  name: string      ## base name
  parent: string    ## full parent sym ("" = root)
  parentName: string
  line: int         ## 1-based
  col: int          ## 0-based

proc allTypes(cfg: Config; snif: string): seq[TypeRec] =
  ## Every object-type / parent edge in the artifact via `aowllens types`.
  result = @[]
  if cfg.aowllensExe.len == 0 or snif.len == 0: return
  let cap = runCaptured(cfg.aowllensExe, @["types", snif], "", false)
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
    var rec = TypeRec(typ: "", name: "", parent: "", parentName: "",
                      line: 0, col: 0)
    for k, v in pairs(el):
      case k
      of "type": rec.typ = v.getStr
      of "name": rec.name = v.getStr
      of "parent": rec.parent = v.getStr
      of "parentName": rec.parentName = v.getStr
      of "line": rec.line = int(v.getInt)
      of "col": rec.col = int(v.getInt)
      else: discard
    if rec.name.len > 0: result.add rec

proc symAtLine(decls: seq[SymPos]; line: int): string =
  for i in 0 ..< decls.len:
    if decls[i].line == line: return decls[i].name
  return ""

# --- prepare ----------------------------------------------------------------

proc prepareTypeHierarchy*(cfg: Config; file: string; p: Position;
                           bufferText: string): string =
  let locs = definition(cfg, file, p, bufferText)
  if locs.len == 0: return "null"
  let dfile = uriToPath(locs[0].uri)
  let dline = locs[0].rng.start.line
  let dcol = locs[0].rng.start.character
  let decls = fileDecls(cfg, dfile)
  var name = ""
  var kind = ""
  for i in 0 ..< decls.len:
    if decls[i].line == dline:
      name = decls[i].name; kind = decls[i].kind; break
  if name.len == 0 or kind != "type": return "null"
  let rng = mkRange(dline, dcol, dline, dcol + name.len)
  result = "[" & itemJson(name, locs[0].uri, rng, locs[0].uri, dline, dcol) & "]"

# --- supertypes (the parent chain, one level) -------------------------------

proc supertypesJson*(cfg: Config; uri: string; line, ch: int): string =
  let file = uriToPath(uri)
  let snif = mainArtifact(cfg, file, ".s.nif")
  let decls = fileDecls(cfg, file)
  let self = symAtLine(decls, line)
  if self.len == 0: return "[]"
  let recs = allTypes(cfg, snif)
  var parents: seq[string] = @[]
  for i in 0 ..< recs.len:
    if recs[i].name != self: continue
    let pn = if recs[i].parentName.len > 0: recs[i].parentName
             else: baseSym(recs[i].parent)
    if pn.len == 0: continue
    var already = false
    for q in parents:
      if q == pn: already = true; break
    if already: continue
    parents.add pn
  result = "["
  var first = true
  for i in 0 ..< parents.len:
    let pn = parents[i]
    # resolve the parent's decl position if it lives in this file
    var dl = 0
    var dc = 0
    var found = false
    for j in 0 ..< decls.len:
      if decls[j].name == pn and decls[j].kind == "type":
        dl = decls[j].line; dc = decls[j].col; found = true; break
    if not first: result.add ","
    first = false
    let rng = mkRange(dl, dc, dl, dc + pn.len)
    result.add itemJson(pn, uri, rng, uri, dl, dc)
  result.add "]"

# --- subtypes (everyone who inherits from this) -----------------------------

proc subtypesJson*(cfg: Config; uri: string; line, ch: int): string =
  let file = uriToPath(uri)
  let snif = mainArtifact(cfg, file, ".s.nif")
  let decls = fileDecls(cfg, file)
  let self = symAtLine(decls, line)
  if self.len == 0: return "[]"
  let recs = allTypes(cfg, snif)
  result = "["
  var first = true
  for i in 0 ..< recs.len:
    let pn = if recs[i].parentName.len > 0: recs[i].parentName
             else: baseSym(recs[i].parent)
    if pn != self: continue
    let cl = if recs[i].line > 0: recs[i].line - 1 else: 0
    if not first: result.add ","
    first = false
    let rng = mkRange(cl, recs[i].col, cl, recs[i].col + recs[i].name.len)
    result.add itemJson(recs[i].name, uri, rng, uri, cl, recs[i].col)
  result.add "]"
