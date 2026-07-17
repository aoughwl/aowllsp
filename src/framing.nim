## framing.nim — LSP base-protocol transport: Content-Length framed messages
## over stdin/stdout.

import std/syncio

proc parseIntSafe(s: string): int =
  var v = 0
  var any = false
  for i in 0 ..< s.len:
    let c = s[i]
    if c >= '0' and c <= '9':
      v = v * 10 + (ord(c) - ord('0')); any = true
  if any: v else: -1

proc hasPrefixCI(s, pre: string): bool =
  if s.len < pre.len: return false
  for i in 0 ..< pre.len:
    var a = s[i]
    var b = pre[i]
    if a >= 'A' and a <= 'Z': a = chr(ord(a) + 32)
    if b >= 'A' and b <= 'Z': b = chr(ord(b) + 32)
    if a != b: return false
  return true

proc readMessage*(body: var string): bool =
  ## Read one framed message. Returns false at EOF. `body` is the JSON payload.
  var contentLength = -1
  var line = ""
  while true:
    var ok = false
    try:
      ok = readLine(stdin, line)
    except:
      return false
    if not ok: return false
    if line.len > 0 and line[line.len - 1] == '\r':
      line = substr(line, 0, line.len - 2)
    if line.len == 0: break              # blank line terminates headers
    if hasPrefixCI(line, "content-length:"):
      contentLength = parseIntSafe(substr(line, 15, line.len - 1))
  if contentLength <= 0:
    body = ""
    return true
  body = ""
  var remaining = contentLength
  var buf = default(array[4096, char])
  while remaining > 0:
    var want = remaining
    if want > 4096: want = 4096
    var r = 0
    try:
      r = readBuffer(stdin, addr buf[0], want)
    except:
      break
    if r <= 0: break
    for i in 0 ..< r: body.add buf[i]
    remaining = remaining - r
  return true

proc writeMessage*(payload: string) =
  ## Frame and write a JSON payload to stdout, then flush.
  try:
    write stdout, "Content-Length: " & $payload.len & "\r\n\r\n"
    write stdout, payload
    flushFile(stdout)
  except:
    discard
