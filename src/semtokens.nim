## semtokens.nim — LSP semanticTokens/full via the `aowllens` CLI.
##
## `aowllens decls <file.s.nif>` prints a JSON array of declaration records
## `{"sym","name","kind","file","line","col"}` read off a sem'd NIF artifact
## (line 1-based, col 0-based, `kind` is the NIF tag). We keep the decls whose
## `file` basename matches the requested file and that carry line info, turn
## each into ONE semantic token at its declaration site, then emit the LSP
## delta-encoded flat int array `{"data":[...]}`.
##
## LIMITATION: this highlights DECLARATION sites only (where each symbol is
## introduced), not every use/reference of the symbol. That is a fine first
## version — a full implementation would also token-ize use sites.

import std/[syncio, strutils, json]
import state, driver
import aowlkit/subprocess

# --- LSP semantic-token legend (advertised by the server) ------------------

const semTokenTypes* = ["namespace", "type", "function", "variable",
                        "parameter", "property", "enum", "enumMember", "keyword"]

# --- small helpers (nimony has no join, stricter than Nim 2) ---------------

proc baseName(p: string): string =
  var i = p.len - 1
  while i >= 0 and p[i] != '/': dec i
  if i < 0: p else: substr(p, i + 1, p.len - 1)

proc among(s: string; xs: openArray[string]): bool =
  for x in xs:
    if s == x: return true
  false

# --- NIF tag -> index into semTokenTypes -----------------------------------

proc kindToTokenType(kind: string): int =
  ## Map a NIF declaration tag to a semantic token type index.
  if among(kind, ["proc", "func", "method", "converter", "macro",
                  "template", "iterator"]):
    2                                     # function
  elif among(kind, ["type", "object"]):
    1                                     # type
  elif kind == "enum":
    6                                     # enum
  elif among(kind, ["let", "const", "var", "gvar", "glet", "cursor"]):
    3                                     # variable
  elif kind == "param":
    4                                     # parameter
  elif kind == "fld":
    5                                     # property
  else:
    3                                     # variable

# --- one artifact's decls -> flat records -----------------------------------

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

# --- semanticTokens/full ----------------------------------------------------

type Tok = tuple[line, col, length, typ: int]

proc lessTok(a, b: Tok): bool =
  ## Order by (line, startChar) ascending.
  if a.line != b.line: return a.line < b.line
  a.col < b.col

proc semanticTokensFull*(cfg: Config; file: string): string =
  ## Returns a JSON object (string): {"data":[<int>,...]} — LSP's delta-encoded
  ## semantic tokens for the DECLARATION sites in `file`. Empty {"data":[]} if
  ## no artifact / no decls.
  let snif = mainArtifact(cfg, file, ".s.nif")
  let recs = runDecls(cfg, snif)
  let want = baseName(file)

  # collect one token per matching declaration
  var toks: seq[Tok] = @[]
  for i in 0 ..< recs.len:
    let r = recs[i]
    if not r.sawLine: continue
    if r.name.len == 0: continue
    if baseName(r.file) != want: continue
    let l = if r.line > 0: r.line - 1 else: 0
    toks.add (line: l, col: r.col, length: r.name.len,
              typ: kindToTokenType(r.kind))

  # insertion sort by (line, col); copy via temp — nimony rejects a[i]=a[j]
  for i in 1 ..< toks.len:
    let key = toks[i]
    var j = i - 1
    while j >= 0 and lessTok(key, toks[j]):
      let mv = toks[j]
      toks[j + 1] = mv
      dec j
    toks[j + 1] = key

  # delta-encode: [deltaLine, deltaStartChar, length, tokenType, 0]
  var s = "{\"data\":["
  var prevLine = 0
  var prevChar = 0
  for i in 0 ..< toks.len:
    let t = toks[i]
    let dLine = t.line - prevLine
    let dChar = if dLine == 0: t.col - prevChar else: t.col
    if i > 0: s.add ","
    s.add $dLine; s.add ","
    s.add $dChar; s.add ","
    s.add $t.length; s.add ","
    s.add $t.typ; s.add ","
    s.add "0"
    prevLine = t.line
    prevChar = t.col
  s.add "]}"
  result = s
