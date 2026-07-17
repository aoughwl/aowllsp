## typeinfo.nim — inlay type hints, powered by `aowllens render`.
##
## nimony's sem'd NIF artifact carries the *inferred* type of every binding, and
## `aowllens render` prints it back as source: a bare `let x = greet("bob")`
## renders as `let x: string = greet("bob")`. We diff that against the actual
## source line — when the user wrote no annotation, we surface the inferred type
## as an LSP inlay hint (`: string`) right after the name.
##
## Everything is derived from the existing render seam; no new NIF reading.

import std/[strutils, syncio, json]
import protocol, state, driver, symbols
import aowlkit/json as ajson
import aowlkit/subprocess

type RenderRec = object
  name: string
  kind: string
  render: string

proc runRender(cfg: Config; snif: string): seq[RenderRec] =
  ## Parse `aowllens render <snif>` (a `{"nodes":[...]}` object) into records.
  result = @[]
  if cfg.aowllensExe.len == 0 or snif.len == 0: return
  let cap = runCaptured(cfg.aowllensExe, @["render", snif], "", false)
  if not cap.ok or cap.output.len == 0: return
  var tree = default(JsonTree)
  try:
    tree = parseJson(cap.output)
  except:
    return
  let root = tree.root
  if root.kind != JObject: return
  for k, v in pairs(root):
    if k != "nodes": continue
    if v.kind != JArray: continue
    for el in items(v):
      if el.kind != JObject: continue
      var rec = RenderRec(name: "", kind: "", render: "")
      for kk, vv in pairs(el):
        case kk
        of "name": rec.name = vv.getStr
        of "kind": rec.kind = vv.getStr
        of "render": rec.render = vv.getStr
        else: discard
      result.add rec

proc isBinding(kind: string): bool =
  kind == "let" or kind == "var" or kind == "glet" or kind == "gvar" or
  kind == "const" or kind == "gconst"

proc firstLine(s: string): string =
  for ln in splitLines(s): return ln
  return s

proc inferredType(render, name: string): string =
  ## From `let NAME: TYPE = …` (or `var`/`const`) pull out TYPE. "" if the
  ## render has no annotation or doesn't match the shape we expect.
  let ln = firstLine(render)
  # locate `NAME:` — the name token followed immediately by a colon
  let pat = name & ":"
  let at = find(ln, pat)
  if at < 0: return ""
  var i = at + pat.len
  # skip one optional space after the colon
  while i < ln.len and ln[i] == ' ': inc i
  # read the type up to the top-level ` = ` (depth-aware over []/()/{})
  var depth = 0
  var start = i
  while i < ln.len:
    let c = ln[i]
    if c == '[' or c == '(' or c == '{': inc depth
    elif c == ']' or c == ')' or c == '}': dec depth
    elif c == '=' and depth == 0:
      break
    inc i
  var t = strip(substr(ln, start, i - 1))
  return t

proc sourceHasAnnotation(line, name: string): bool =
  ## Does the source line already annotate `name` with a `: type`? True if a
  ## top-level ':' appears between the name and the '=' (or end of line).
  let at = find(line, name)
  if at < 0: return true          # can't tell -> assume annotated (suppress hint)
  var i = at + name.len
  var depth = 0
  while i < line.len:
    let c = line[i]
    if c == '[' or c == '(' or c == '{': inc depth
    elif c == ']' or c == ')' or c == '}': dec depth
    elif depth == 0:
      if c == ':': return true
      if c == '=': return false
    inc i
  return false

proc nthLine(text: string; n: int): string =
  var cur = 0
  for ln in splitLines(text):
    if cur == n: return ln
    inc cur
  return ""

proc renderAt*(cfg: Config; file: string; line: int): string =
  ## The `aowllens render` text of the declaration on 0-based `line` of `file`,
  ## or "" if none. Used to give hover the fully-resolved signature/type instead
  ## of the raw source line (procs show their full signature; bindings show the
  ## inferred type).
  let decls = fileDecls(cfg, file)
  var name = ""
  for i in 0 ..< decls.len:
    if decls[i].line == line:
      name = decls[i].name
      break
  if name.len == 0: return ""
  let snif = mainArtifact(cfg, file, ".s.nif")
  let renders = runRender(cfg, snif)
  for j in 0 ..< renders.len:
    if renders[j].name == name:
      return renders[j].render
  return ""

proc inlayHintsJson*(cfg: Config; file, bufferText: string): string =
  ## Inlay `: type` hints for every un-annotated let/var/const in `file`.
  let snif = mainArtifact(cfg, file, ".s.nif")
  let decls = fileDecls(cfg, file)        # positions (name/line/col/kind)
  let renders = runRender(cfg, snif)       # inferred types (name/kind/render)
  let src = if bufferText.len > 0: bufferText
            else: (try: readFile(file) except: "")
  var parts: seq[string] = @[]
  for i in 0 ..< decls.len:
    let d = decls[i]
    if not isBinding(d.kind): continue
    # find the render record for this binding by name
    var rndr = ""
    for j in 0 ..< renders.len:
      if renders[j].name == d.name and isBinding(renders[j].kind):
        rndr = renders[j].render
        break
    if rndr.len == 0: continue
    let ty = inferredType(rndr, d.name)
    if ty.len == 0: continue
    let sline = nthLine(src, d.line)
    if sourceHasAnnotation(sline, d.name): continue
    # place the hint right after the variable name
    let charPos = d.col + d.name.len
    parts.add "{\"position\":{\"line\":" & $d.line & ",\"character\":" &
      $charPos & "},\"label\":" & ajson.jStr(": " & ty) &
      ",\"kind\":1,\"paddingLeft\":false,\"paddingRight\":false}"
  result = "["
  for i in 0 ..< parts.len:
    if i > 0: result.add ","
    result.add parts[i]
  result.add "]"
