import osproc, posix, strformat


# ## Low-level Constants/Procedures ## #
when defined(windows):
  proc c_fileno(f: FileHandle): cint {.
      importc: "_fileno", header: "<stdio.h>".}
else:
  proc c_fileno(f: File): cint {.
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
  output*, errput*, input*: File


proc filteredClose*(file: File) =
  let isCoreFile = (
    file == stdin or
    file == stdout or
    file == stderr
  )
  if not isCoreFile:
    close(file)


proc close*(files: CommandFiles) =
  filteredClose(files.output)
  filteredClose(files.errput)
  filteredClose(files.input)


proc callExecutable*(
    executable   : string,
    arguments    : seq[string],
    cmdFiles     : CommandFiles): Process =

  # Save standard output streams
  let
    savedStdout = dup_fd(STDOUT_FILENO)
    savedStderr = dup_fd(STDERR_FILENO)
    savedStdin = dup_fd(STDIN_FILENO)

  # Restore cmdFiles at the end of the function
  # This code block is actually run when the function ends
  # (whether normally, or through an exception)
  defer:
    dup_fd(savedStdout, STDOUT_FILENO);
    dup_fd(savedStderr, STDERR_FILENO);
    dup_fd(savedStdin, STDIN_FILENO);
    discard close(savedStdout)
    discard close(savedStderr)
    discard close(savedStdin)

  # Set the cmdFiles
  dup_fd(c_fileno(cmdFiles.output), STDOUT_FILENO)
  dup_fd(c_fileno(cmdFiles.errput), STDERR_FILENO)
  dup_fd(c_fileno(cmdFiles.input), STDIN_FILENO)

  # Start the process using parent streams, which have
  # just been redirected
  result = startProcess(
    command = executable,
    args    = arguments,
    options = {poParentStreams}
  )

  # Wait for the process to exit, discarding the return code.
  discard waitForExit(result)