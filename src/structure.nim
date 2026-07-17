## structure.nim — LSP foldingRange + selectionRange as pure text heuristics.
## No compiler artifacts required; indentation/identifier based.

import std/strutils
import protocol
import aowlkit/json

proc isBlankLine(s: string): bool =
  ## True if the line is empty or only whitespace.
  var i = 0
  while i < s.len:
    let c = s[i]
    if c != ' ' and c != '\t':
      return false
    inc i
  true

proc indentOf(s: string): int =
  ## Number of leading spaces (tabs count as one space each, for robustness).
  var n = 0
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == ' ' or c == '\t':
      inc n
    else:
      break
    inc i
  n

proc isIdentChar(c: char): bool =
  (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
    (c >= '0' and c <= '9') or c == '_'

proc foldingRanges*(bufferText: string): string =
  ## JSON array of LSP FoldingRange[]: {"startLine":L,"endLine":L2,"kind":"region"}
  ## (0-based lines). One region per indentation block.
  let lines = splitLines(bufferText)
  let n = lines.len
  # Precompute indent + blank flags.
  var indent: seq[int] = @[]
  var blank: seq[bool] = @[]
  var i = 0
  while i < n:
    blank.add isBlankLine(lines[i])
    indent.add indentOf(lines[i])
    inc i

  result = "["
  var count = 0
  var emitted = false
  i = 0
  while i < n:
    if not blank[i]:
      # Find next non-blank line j.
      var j = i + 1
      while j < n and blank[j]:
        inc j
      if j < n and indent[j] > indent[i]:
        # Region: walk forward while deeper than indent[i], tracking last
        # non-blank line that belongs to the deeper block.
        var k = j
        var lastDeep = i
        while k < n:
          if not blank[k]:
            if indent[k] > indent[i]:
              lastDeep = k
            else:
              break
          inc k
        if lastDeep > i and count < 1000:
          if emitted: result.add ","
          result.add "{\"startLine\":" & $i & ",\"endLine\":" & $lastDeep &
            ",\"kind\":\"region\"}"
          emitted = true
          inc count
    inc i
  result.add "]"

proc selectionRangeJson(r: Range; parent: Range): string =
  "{\"range\":" & rangeJson(r) & ",\"parent\":{\"range\":" & rangeJson(parent) & "}}"

proc selectionRanges*(bufferText: string; positions: seq[Position]): string =
  ## JSON array, one nested SelectionRange per input position:
  ## inner = identifier under cursor, outer = whole line.
  let lines = splitLines(bufferText)
  let n = lines.len
  result = "["
  var idx = 0
  while idx < positions.len:
    if idx > 0: result.add ","
    let p = positions[idx]
    var lineText = ""
    if p.line >= 0 and p.line < n:
      lineText = lines[p.line]
    let lineLen = lineText.len
    let lineRange = mkRange(p.line, 0, p.line, lineLen)

    # Clamp cursor into [0, lineLen].
    var cur = p.character
    if cur < 0: cur = 0
    if cur > lineLen: cur = lineLen

    # Walk left/right over identifier characters.
    var lo = cur
    while lo > 0 and lo - 1 < lineLen and isIdentChar(lineText[lo - 1]):
      dec lo
    var hi = cur
    while hi < lineLen and isIdentChar(lineText[hi]):
      inc hi

    var identRange: Range
    if hi > lo:
      identRange = mkRange(p.line, lo, p.line, hi)
    else:
      # No identifier under cursor: zero-width range at the cursor.
      identRange = mkRange(p.line, cur, p.line, cur)

    result.add selectionRangeJson(identRange, lineRange)
    inc idx
  result.add "]"
