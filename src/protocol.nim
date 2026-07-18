## protocol.nim — the LSP value types we use, plus their JSON serialization.
## Positions are 0-based; `character` is a UTF-16 code-unit offset (LSP's rule),
## which `document.nim` maps to/from UTF-8 byte offsets.

import aowlkit/json

type
  Position* = object
    line*: int
    character*: int

  Range* = object
    start*: Position
    stop*: Position        ## `end` in LSP; `end` is a nimony keyword

  Location* = object
    uri*: string
    rng*: Range

  DiagnosticSeverity* = enum
    dsNone, dsError, dsWarning, dsInformation, dsHint   ## LSP: Error=1..Hint=4

  RelatedInfo* = object
    uri*: string
    rng*: Range
    message*: string

  Diagnostic* = object
    rng*: Range
    severity*: DiagnosticSeverity
    source*: string
    message*: string
    code*: string           ## LSP Diagnostic.code (the rule id); "" = omit
    codeHref*: string       ## codeDescription.href (rule docs); "" = omit
    related*: seq[RelatedInfo]

proc pos*(line, character: int): Position =
  Position(line: line, character: character)

proc mkRange*(sl, sc, el, ec: int): Range =
  Range(start: pos(sl, sc), stop: pos(el, ec))

proc posJson*(p: Position): string =
  "{\"line\":" & $p.line & ",\"character\":" & $p.character & "}"

proc rangeJson*(r: Range): string =
  "{\"start\":" & posJson(r.start) & ",\"end\":" & posJson(r.stop) & "}"

proc locationJson*(l: Location): string =
  "{\"uri\":" & jStr(l.uri) & ",\"range\":" & rangeJson(l.rng) & "}"

proc severityNum*(s: DiagnosticSeverity): int =
  case s
  of dsError: 1
  of dsWarning: 2
  of dsInformation: 3
  of dsHint: 4
  of dsNone: 3

proc diagnosticJson*(d: Diagnostic): string =
  result = "{\"range\":" & rangeJson(d.rng) &
    ",\"severity\":" & $severityNum(d.severity) &
    ",\"source\":" & jStr(d.source) &
    ",\"message\":" & jStr(d.message)
  if d.code.len > 0:
    result.add ",\"code\":" & jStr(d.code)
    if d.codeHref.len > 0:
      result.add ",\"codeDescription\":{\"href\":" & jStr(d.codeHref) & "}"
  if d.related.len > 0:
    result.add ",\"relatedInformation\":["
    for i in 0 ..< d.related.len:
      if i > 0: result.add ","
      result.add "{\"location\":{\"uri\":" & jStr(d.related[i].uri) &
        ",\"range\":" & rangeJson(d.related[i].rng) & "},\"message\":" &
        jStr(d.related[i].message) & "}"
    result.add "]"
  result.add "}"
