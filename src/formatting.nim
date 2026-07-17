## formatting.nim — textDocument/formatting, delegated to the aowlfmt binary.
##
## aowllsp does not format text itself; it pipes the live buffer through
## `aowlfmt --stdin` (the verified layout formatter) and returns a single
## whole-document TextEdit. aowlfmt only ever emits layout-preserving output —
## if it can't prove a reformat is safe it returns the text unchanged — so this
## edit can never corrupt the document.

import std/[strutils, syncio]
import protocol, state
import aowlkit/json as ajson
import aowlkit/subprocess

proc lineCount(text: string): int =
  ## Number of lines, so we can build a range that covers the whole document.
  result = 1
  for i in 0 ..< text.len:
    if text[i] == '\n': inc result

proc formattingEdits*(cfg: Config; bufferText: string): string =
  ## Returns a JSON TextEdit[] (as a string) that replaces the whole document
  ## with aowlfmt's output, or `[]` when the formatter is unavailable, errored,
  ## or produced no change.
  if cfg.aowlfmtExe.len == 0 or bufferText.len == 0: return "[]"
  let cap = runWithInput(cfg.aowlfmtExe, @["--stdin"], bufferText, "")
  if not cap.ok: return "[]"
  let formatted = cap.output
  if formatted == bufferText: return "[]"   # already formatted -> no edit
  # Whole-document replace: from (0,0) to (lineCount, 0) covers everything even
  # when the last line has no trailing newline.
  let endLine = lineCount(bufferText)
  let rng = mkRange(0, 0, endLine, 0)
  result = "[{\"range\":" & rangeJson(rng) & ",\"newText\":" &
    ajson.jStr(formatted) & "}]"
