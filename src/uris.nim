## uris.nim — file:// URI <-> filesystem path, with minimal percent-coding.

proc hexVal(c: char): int =
  if c >= '0' and c <= '9': ord(c) - ord('0')
  elif c >= 'a' and c <= 'f': ord(c) - ord('a') + 10
  elif c >= 'A' and c <= 'F': ord(c) - ord('A') + 10
  else: -1

proc percentDecode(s: string): string =
  result = ""
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len:
      let h = hexVal(s[i+1])
      let l = hexVal(s[i+2])
      if h >= 0 and l >= 0:
        result.add chr(h * 16 + l)
        i += 3
        continue
    result.add s[i]
    inc i

proc uriToPath*(uri: string): string =
  ## `file:///home/x%20y.nim` -> `/home/x y.nim`. Non-file URIs pass through.
  var s = uri
  if s.len >= 7 and substr(s, 0, 6) == "file://":
    s = substr(s, 7, s.len - 1)
    # a leading host is empty for local files: file:///path -> /path
  result = percentDecode(s)

proc percentEncodePath(s: string): string =
  ## Encode a path for a file URI: keep '/', unreserved chars; percent-encode
  ## the rest (spaces etc.).
  const hexd = "0123456789ABCDEF"
  result = ""
  for i in 0 ..< s.len:
    let c = s[i]
    if (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
       (c >= '0' and c <= '9') or c == '/' or c == '-' or c == '_' or
       c == '.' or c == '~':
      result.add c
    else:
      result.add '%'
      result.add hexd[(ord(c) shr 4) and 0xF]
      result.add hexd[ord(c) and 0xF]

proc pathToUri*(path: string): string =
  ## `/home/x y.nim` -> `file:///home/x%20y.nim`.
  var p = path
  if p.len == 0 or p[0] != '/':
    p = "/" & p
  result = "file://" & percentEncodePath(p)
