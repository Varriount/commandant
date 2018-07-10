import osproc, posix, strformat, sequtils, fileutils


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