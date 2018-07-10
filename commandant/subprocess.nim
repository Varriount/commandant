import osproc, posix, strformat


# ## Low-level Constants/Procedures ## #
when defined(windows):
  proc c_fileno*(f: FileHandle): cint {.
      importc: "_fileno", header: "<stdio.h>".}
else:
  proc c_fileno*(f: File): cint {.
      importc: "fileno", header: "<fcntl.h>".}


proc dup_fd(oldHandle, newHandle: FileHandle) =
  if dup2(oldHandle, newHandle) < 0:
    raise newException(
      ValueError,
      fmt"Unable to duplicate file handle {oldHandle}."
    )


proc dup_fd(oldHandle: FileHandle): FileHandle =
  result = dup(oldHandle)
  if result < 0:
    raise newException(
      ValueError,
      fmt"Unable to duplicate file handle {oldHandle}."
    )


# ## Public Interface ## #
type CommandFiles* = object
  outputFd* : FileHandle
  errputFd* : FileHandle
  inputFd*  : FileHandle


proc initCommandFiles*(cmdFiles: var CommandFiles) =
    cmdFiles.outputFd = dup_fd(c_fileno(stdout))
    cmdFiles.errputFd = dup_fd(c_fileno(stderr))
    cmdFiles.inputFd  = dup_fd(c_fileno(stdin))


proc closeCommandFiles*(cmdFiles: CommandFiles) =
  discard close(cmdFiles.outputFd)
  discard close(cmdFiles.errputFd)
  discard close(cmdFiles.inputFd)


template genCommandFilesAccessor(accessor, member) =

  proc `accessor =`*(cmdFiles: var CommandFiles, file: File) =
    var result = c_fileno(file)
    if   result == c_fileno(stdout): result = cmdFiles.outputFd
    elif result == c_fileno(stderr): result = cmdFiles.errputFd
    elif result == c_fileno(stdin):  result = cmdFiles.inputFd
    dup_fd(result, cmdFiles.member)

  proc accessor*(cmdFiles: CommandFiles): FileHandle =
    result = cmdFiles.member


genCommandFilesAccessor(output, outputFd)
genCommandFilesAccessor(errput, errputFd)
genCommandFilesAccessor(input, inputFd)


proc set*(cmdFiles: CommandFiles) =
  dup_fd(cmdFiles.output, c_fileno(stdout));
  dup_fd(cmdFiles.errput, c_fileno(stderr));
  dup_fd(cmdFiles.input, c_fileno(stdin));


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