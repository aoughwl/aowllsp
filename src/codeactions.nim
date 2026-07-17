## codeactions.nim — LSP textDocument/codeAction by delegating to `aowlsuggest`.
##
## `aowlsuggest lsp --stdin` reads a buffer on stdin and prints ONE JSON object:
##   {"uri":..,"diagnostics":[...],"codeActions":[ CodeAction... ]}
## We run it, pull the `codeActions` array value out of the output as a raw
## (balanced-bracket, string-aware) substring, then optionally drop actions whose
## first diagnostic's start line falls outside [loLine, hiLine]. Returning the
## array verbatim avoids re-serializing nested LSP CodeActions by hand.

import std/syncio
import std/strutils
import state
import aowlkit/subprocess

proc matchingBracket(s: string; openIdx: int): int =
  ## Given `s[openIdx]` is an opening bracket (`[` or `{`), return the index of
  ## its matching close, tracking `[]`/`{}` depth while skipping over JSON string
  ## literals (so brackets inside strings don't miscount). -1 if unbalanced.
  var depth = 0
  var i = openIdx
  var inStr = false
  while i < s.len:
    let c = s[i]
    if inStr:
      if c == '\\':
        inc i   # skip the escaped char
      elif c == '"':
        inStr = false
    else:
      if c == '"':
        inStr = true
      elif c == '[' or c == '{':
        inc depth
      elif c == ']' or c == '}':
        dec depth
        if depth == 0:
          return i
    inc i
  return -1

proc firstLineOf(obj: string): int =
  ## Parse the integer after the first `"line":` in `obj` (a CodeAction object).
  ## Returns -1 if not found. The first `"line":` is the first diagnostic's start
  ## line (start precedes end in the emitted JSON).
  let k = find(obj, "\"line\":")
  if k < 0: return -1
  var i = k + len("\"line\":")
  while i < obj.len and (obj[i] == ' ' or obj[i] == '\t'):
    inc i
  var num = ""
  while i < obj.len and obj[i] >= '0' and obj[i] <= '9':
    num.add obj[i]
    inc i
  if num.len == 0: return -1
  var val = 0
  try: val = parseInt(num)
  except: return -1
  return val

proc splitTopObjects(inner: string): seq[string] =
  ## Split the contents of a JSON array (`inner`, without the surrounding `[]`)
  ## into its top-level `{...}` object substrings, string-aware.
  result = @[]
  var i = 0
  while i < inner.len:
    if inner[i] == '{':
      let close = matchingBracket(inner, i)
      if close < 0: break
      result.add substr(inner, i, close)   # inclusive of both braces
      i = close + 1
    else:
      inc i

proc codeActionsFor*(cfg: Config; file, bufferText: string; loLine, hiLine: int): string =
  ## Returns a JSON array (string) of LSP CodeAction[] for the buffer, limited to
  ## diagnostics whose line (0-based) falls in [loLine, hiLine]. Empty "[]" if none.
  if cfg.aowlsuggestExe.len == 0:
    return "[]"
  let args = @["lsp", "--stdin", "--filename:" & file]
  let cap = runWithInput(cfg.aowlsuggestExe, args, bufferText, "")
  if not cap.ok:
    return "[]"
  let outp = cap.output
  let k = find(outp, "\"codeActions\":")
  if k < 0:
    return "[]"
  # find the opening '[' after the key
  var b = k + len("\"codeActions\":")
  while b < outp.len and outp[b] != '[':
    inc b
  if b >= outp.len:
    return "[]"
  let close = matchingBracket(outp, b)
  if close < 0:
    return "[]"
  let arr = substr(outp, b, close)          # "[ ... ]" inclusive
  if arr.len < 2:
    return "[]"
  # inner = contents between the outer brackets
  let inner = substr(arr, 1, arr.len - 2)
  let objs = splitTopObjects(inner)
  if objs.len == 0:
    return "[]"
  # Filter by first-diagnostic start line; keep objects whose line is unknown.
  var kept: seq[string] = @[]
  for o in objs:
    let ln = firstLineOf(o)
    if ln < 0 or (ln >= loLine and ln <= hiLine):
      kept.add o
  if kept.len == 0:
    return "[]"
  var res = "["
  var first = true
  for o in kept:
    if not first: res.add ","
    res.add o
    first = false
  res.add "]"
  return res
