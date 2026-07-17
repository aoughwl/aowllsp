## document.nim — an in-memory text document with LSP<->byte-offset mapping.
##
## LSP `character` columns are UTF-16 code units. We keep the raw UTF-8 text plus
## a cached index of line-start byte offsets and translate between the two, so a
## cursor position from the editor lands on the right byte and vice-versa.

import std/[strutils, unicode]
import protocol

type
  Document* = object
    uri*: string
    languageId*: string
    version*: int
    text*: string
    lineStarts*: seq[int]   ## byte offset of the start of each line

proc computeLineStarts(text: string): seq[int] =
  result = @[0]
  for i in 0 ..< text.len:
    if text[i] == '\n':
      result.add i + 1

proc newDocument*(uri, languageId: string; version: int; text: string): Document =
  Document(uri: uri, languageId: languageId, version: version,
           text: text, lineStarts: computeLineStarts(text))

proc setText*(d: var Document; version: int; text: string) =
  d.version = version
  d.text = text
  d.lineStarts = computeLineStarts(text)

proc utf16Units(r: Rune): int =
  if int32(r) > 0xFFFF: 2 else: 1

proc offsetAt*(d: Document; p: Position): int =
  ## Byte offset in `d.text` for an LSP position. Clamps out-of-range input.
  if d.lineStarts.len == 0: return 0
  var line = p.line
  if line < 0: line = 0
  if line > d.lineStarts.len - 1: line = d.lineStarts.len - 1
  let lineStart = d.lineStarts[line]
  let lineEnd =
    if line + 1 < d.lineStarts.len: d.lineStarts[line + 1]
    else: d.text.len
  var utf16 = 0
  var i = lineStart
  while i < lineEnd:
    if utf16 >= p.character: break
    let r = runeAt(d.text, i)
    utf16 += utf16Units(r)
    i += r.size
  result = i

proc positionAt*(d: Document; offset: int): Position =
  ## LSP position for a byte offset in `d.text`.
  var off = offset
  if off < 0: off = 0
  if off > d.text.len: off = d.text.len
  # find the line by scan (line counts are small; keeps it simple)
  var line = 0
  for k in 0 ..< d.lineStarts.len:
    if d.lineStarts[k] <= off: line = k
    else: break
  let lineStart = d.lineStarts[line]
  var utf16 = 0
  var i = lineStart
  while i < off:
    let r = runeAt(d.text, i)
    utf16 += utf16Units(r)
    i += r.size
  result = pos(line, utf16)

proc lineText*(d: Document; line: int): string =
  if line < 0 or line >= d.lineStarts.len: return ""
  let s = d.lineStarts[line]
  var e = if line + 1 < d.lineStarts.len: d.lineStarts[line + 1] else: d.text.len
  while e > s and (d.text[e-1] == '\n' or d.text[e-1] == '\r'): dec e
  result = substr(d.text, s, e - 1)

proc wordAt*(d: Document; p: Position): string =
  ## The identifier surrounding the position (Nim identifier chars).
  let off = offsetAt(d, p)
  proc isIdent(c: char): bool =
    (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
    (c >= '0' and c <= '9') or c == '_'
  var s = off
  while s > 0 and isIdent(d.text[s-1]): dec s
  var e = off
  while e < d.text.len and isIdent(d.text[e]): inc e
  result = substr(d.text, s, e - 1)
