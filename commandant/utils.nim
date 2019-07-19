import os
proc chk*(e: int|cint) =
  if e != 0'i32: raiseOSError(osLastError())