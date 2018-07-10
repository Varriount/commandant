import posix, strformat, typetraits





proc duplicate*(fromHandle, toHandle: FileHandle) =
  if dup2(fromHandle, toHandle) < 0:
    raise newException(
      ValueError,
      fmt"Unable to duplicate file handle {fromHandle}."
    )


proc duplicate*(fromHandle: FileHandle): FileHandle =
  result = dup(fromHandle)
  if result < 0:
    raise newException(
      ValueError,
      fmt"Unable to duplicate file handle {fromHandle}."
    )


proc duplicateMany*[T](handles: T): T =
  var openCount = 0

  try:
    for fromHandle, toHandle in fields(handles, result):
      toHandle = duplicate(fromHandle)
      inc openCount
  except:
    for handle in fields(handles):
      if openCount <= 0:
        break
      discard close(handle)
      dec openCount


proc duplicateMany*[T](fromHandles, toHandles: T) =
  let savedHandles = duplicateMany(toHandles)
  var openedFiles = 0

  defer:
    for handle in fields(savedHandles):
      discard close(handle)

  try:
    for fromHandle, toHandle in fields(fromHandles, toHandles):
      duplicate(fromHandle, toHandle)
      inc openedFiles
  except:
    # If this fails, the program should probably just crash.
    # Something has gone seriously wrong if the standard streams can't
    # be duplicated to.
    for toHandle, savedHandle in fields(toHandles, savedHandles):
      if openedFiles <= 0:
        break
      duplicate(savedHandle, toHandle)
      dec openedFiles
