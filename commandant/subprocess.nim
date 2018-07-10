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
    raise newException(ValueError, fmt"Unable to duplicate file handle {oldHandle}.")


proc dup_fd(oldHandle: FileHandle): FileHandle =
  result = dup(oldHandle)
  if result < 0:
    raise newException(ValueError, fmt"Unable to duplicate file handle {oldHandle}.")


# ## Public Interface ## #
type CommandFiles* = object
  outputFd* : FileHandle
  errputFd* : FileHandle
  inputFd*  : FileHandle


proc initCommandFiles*(cmdFiles: var CommandFiles) =
    cmdFiles.outputFd = dup_fd(c_fileno(stdout))
    cmdFiles.errputFd = dup_fd(c_fileno(stderr))
    cmdFiles.inputFd  = dup_fd(c_fileno(stdin))
    echo "Init: ", repr(cmdFiles)


proc closeCommandFiles*(cmdFiles: CommandFiles) =
  echo "Close: ", repr(cmdFiles)
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

proc callExecutable*(
    executable   : string,
    arguments    : seq[string],
    cmdFiles     : CommandFiles): Process =
  
  echo "Output: ", cmdFiles.output
  echo "Errput: ", cmdFiles.errput
  echo "Input: ", cmdFiles.input

  # Save standard output streams
  let
    savedStdout = dup_fd(c_fileno(stdout))
    savedStderr = dup_fd(c_fileno(stderr))
    savedStdin = dup_fd(c_fileno(stdin))

  # Restore cmdFiles at the end of the function
  # This code block is actually run when the function ends
  # (whether normally, or through an exception)
  defer:
    dup_fd(savedStdout, c_fileno(stdout));
    dup_fd(savedStderr, c_fileno(stderr));
    dup_fd(savedStdin, c_fileno(stdin));
    discard close(savedStdout)
    discard close(savedStderr)
    discard close(savedStdin)

  # Set the cmdFiles
  dup_fd(cmdFiles.output, c_fileno(stdout));
  dup_fd(cmdFiles.errput, c_fileno(stderr));
  dup_fd(cmdFiles.input, c_fileno(stdin));

  # Start the process using parent streams, which have
  # just been redirected
  result = startProcess(
    command = executable,
    args    = arguments,
    options = {poParentStreams}
  )

  # Wait for the process to exit, discarding the return code.
  discard waitForExit(result)