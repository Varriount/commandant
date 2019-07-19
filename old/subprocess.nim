import osproc, posix, strformat, sequtils, typetraits

type Pipes* = object
  data: array[0..1, cint]

proc initPipes*(): Pipes
  pipe(result.data)

proc outPipe*(p: Pipe):
  result = p.data[0]

proc inPipe*(p: Pipe):
  result = p.data[1]


proc duplicate(fromHandle, toHandle: FileHandle) =
  if dup2(fromHandle, toHandle) < 0:
    raise newException(
      ValueError,
      fmt"Unable to duplicate file handle {fromHandle}."
    )


proc duplicate(fromHandle: FileHandle): FileHandle =
  result = dup(fromHandle)
  if result < 0:
    raise newException(
      ValueError,
      fmt"Unable to duplicate file handle {fromHandle}."
    )


proc duplicateMany[T](handles: T): T =
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


proc duplicateMany[T](fromHandles, toHandles: T) =
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



# ## Public Interface ## #
type CommandFiles* = tuple[
  outputFd : FileHandle,
  errputFd : FileHandle,
  inputFd  : FileHandle
]


proc initCommandFiles*(cmdFiles: var CommandFiles) =
  var openedFiles = duplicateMany((
    getFileHandle(stdout),
    getFileHandle(stderr),
    getFileHandle(stdin),
  ))
  cmdFiles.outputFd = openedFiles[0]
  cmdFiles.errputFd = openedFiles[1]
  cmdFiles.inputFd  = openedFiles[2]


proc initCommandFiles*(): CommandFiles =
  initCommandFiles(result)


proc closeCommandFiles*(cmdFiles: CommandFiles) =
  discard close(cmdFiles.outputFd)
  discard close(cmdFiles.errputFd)
  discard close(cmdFiles.inputFd)


template genCommandFilesAccessor(accessor, member) =

  proc `accessor =`*(cmdFiles: var CommandFiles, file: File) =
    var result = getFileHandle(file)
    if   result == getFileHandle(stdout): result = cmdFiles.outputFd
    elif result == getFileHandle(stderr): result = cmdFiles.errputFd
    elif result == getFileHandle(stdin):  result = cmdFiles.inputFd
    duplicate(result, cmdFiles.member)

  proc accessor*(cmdFiles: CommandFiles): FileHandle =
    result = cmdFiles.member


genCommandFilesAccessor(output, outputFd)
genCommandFilesAccessor(errput, errputFd)
genCommandFilesAccessor(input, inputFd)


template set*(cmdFiles: CommandFiles) =
  duplicateMany(
    cmdFiles,
    (
      getFileHandle(stdout),
      getFileHandle(stderr),
      getFileHandle(stdin),
    )
  )


proc callExecutable*(
    executable   : string,
    arguments    : seq[string],
    cmdFiles     : CommandFiles): Process =

  # Save standard output streams
  var oldCmdFiles: CommandFiles
  initCommandFiles(oldCmdFiles)
  defer:
    closeCommandFiles(oldCmdFiles)

  # Set the standard streams
  defer:
    set(oldCmdFiles)
  set(cmdFiles)

  # Start the process using parent streams, which have
  # just been redirected
  result = startProcess(
    command = executable,
    args    = arguments,
    options = {poParentStreams}
  )

  # Wait for the process to exit, discarding the return code.
  discard waitForExit(result)