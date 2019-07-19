import os, osproc, posix, strformat, sequtils, typetraits
import utils


var environ {.importc.}: cstringArray


type
  Pipe* = object
    readEnd*  : FileHandle
    writeEnd* : FileHandle

  CommandPipes* = object
    input*  : Pipe
    output* : Pipe
    errput* : Pipe


# proc dup*(fh: FileHandle): FileHandle =
#   result = cast[FileHandle](dup(cast[cint](fh)))


# ## Pipe Procedures ## #
proc initPipe*(): Pipe =
  var res: array[2, cint]
  chk pipe(res)
  result.readEnd  = cast[FileHandle](res[0])
  result.writeEnd = cast[FileHandle](res[1])


proc duplicate*(pipe: Pipe): Pipe =
  result.readEnd  = -1
  if pipe.readEnd != -1:
    result.readEnd = dup(pipe.readEnd)
  
  result.writeEnd = -1
  if pipe.writeEnd != -1:
    result.writeEnd = dup(pipe.writeEnd)


proc closeEnd*(handle: var FileHandle) =
  if handle == -1:
    return
  chk close(handle)
  handle = -1


proc close*(pipe: var Pipe) =
  closeEnd(pipe.readEnd)
  closeEnd(pipe.writeEnd)


# ## CommandPipes Procedures
proc initStandardPipes*(): CommandPipes =
  result.input.writeEnd  = -1
  result.input.readEnd   = dup(getFileHandle(stdin))
  result.output.readEnd  = -1
  result.output.writeEnd = dup(getFileHandle(stdout))
  result.errput.readEnd  = -1
  result.errput.writeEnd = dup(getFileHandle(stderr))


proc duplicate*(pipes: CommandPipes): CommandPipes =
  result.input  = duplicate(pipes.input)
  result.output = duplicate(pipes.output)
  result.errput = duplicate(pipes.errput)


proc close*(p: var CommandPipes) =
  close(p.input)
  close(p.output)
  close(p.errput)


# ## Process Spawning Procedures ## #
proc spawnProcess*(commandLine: openarray[string], pipes: CommandPipes): Pid =
  var 
    spawnAttributes: TPosixSpawnAttr
    fileActions    : TPosixSpawnFileActions
  # Initialize file actions and spawn attributes
  chk posix_spawn_file_actions_init(fileActions)
  defer: discard posix_spawn_file_actions_destroy(fileActions)

  chk posix_spawnattr_init(spawnAttributes)
  defer: discard posix_spawnattr_destroy(spawnAttributes)

  # Set the subprocess signal mask
  var mask: Sigset
  chk sig_empty_set(mask)
  chk sig_add_set(mask, SIGCHLD);
  chk posix_spawnattr_set_sigmask(spawnAttributes, mask)

  # Set the subprocess process group
  chk posix_spawnattr_set_pgroup(spawnAttributes, 0'i32)

  # Set the subprocess file actions
  # Note - this assumes that all file descriptors are unique!
  if pipes.input.writeEnd != -1:
    echo "Closing FD " & $pipes.input.writeEnd
    chk posixSpawnFileActionsAddClose(fileActions, pipes.input.writeEnd)
  if pipes.output.readEnd != -1:
    echo "Closing FD " & $pipes.output.readEnd
    chk posixSpawnFileActionsAddClose(fileActions, pipes.output.readEnd)
  if pipes.errput.readEnd != -1:
    echo "Closing FD " & $pipes.errput.readEnd
    chk posixSpawnFileActionsAddClose(fileActions, pipes.errput.readEnd)

  echo "Duplicating FD " & $pipes.input.readEnd
  echo "Duplicating FD " & $pipes.output.writeEnd
  echo "Duplicating FD " & $pipes.errput.writeEnd
  chk posixSpawnFileActionsAddDup2(fileActions, pipes.input.readEnd, 0)
  chk posixSpawnFileActionsAddDup2(fileActions, pipes.output.writeEnd, 1)
  chk posixSpawnFileActionsAddDup2(fileActions, pipes.errput.writeEnd, 2)

  echo "Closing FD " & $pipes.input.readEnd
  echo "Closing FD " & $pipes.output.writeEnd
  chk posixSpawnFileActionsAddClose(fileActions, pipes.input.readEnd)
  chk posixSpawnFileActionsAddClose(fileActions, pipes.output.writeEnd)
  if pipes.errput.writeEnd != pipes.output.writeEnd:
    echo "Closing FD " & $pipes.errput.writeEnd
    chk posixSpawnFileActionsAddClose(fileActions, pipes.errput.writeEnd)

  # Set process flags
  var spawnFlags = (
    POSIX_SPAWN_USEVFORK   or
    POSIX_SPAWN_SETSIGMASK or
    POSIX_SPAWN_SETPGROUP
  )
  chk posix_spawnattr_setflags(spawnAttributes, spawnFlags)

  # Allocate command and arguments
  var
    command     = cstring(commandLine[0])
    arguments   = allocCStringArray(commandLine)

  defer: deallocCStringArray(arguments)

  # Spawn the process
  let res = posixSpawnP(
    result,
    command,
    fileActions,
    spawnAttributes,
    arguments,
    environ
  )
  if res != 0'i32:
    raiseOSError(
      osLastError(),
      "Unable to spawn subprocess. OS Error: " & $strerror(res)
    )


# proc duplicate(fromHandle, toHandle: FileHandle) =
#   if dup2(fromHandle, toHandle) < 0:
#     raise newException(
#       ValueError,
#       fmt"Unable to duplicate file handle {fromHandle}."
#     )


# proc duplicate(fromHandle: FileHandle): FileHandle =
#   result = dup(fromHandle)
#   if result < 0:
#     raise newException(
#       ValueError,
#       fmt"Unable to duplicate file handle {fromHandle}."
#     )


# proc duplicateMany[T](handles: T): T =
#   var openCount = 0

#   try:
#     for fromHandle, toHandle in fields(handles, result):
#       toHandle = duplicate(fromHandle)
#       inc openCount
#   except:
#     for handle in fields(handles):
#       if openCount <= 0:
#         break
#       discard close(handle)
#       dec openCount


# proc duplicateMany[T](fromHandles, toHandles: T) =
#   let savedHandles = duplicateMany(toHandles)
#   var openedFiles = 0

#   defer:
#     for handle in fields(savedHandles):
#       discard close(handle)

#   try:
#     for fromHandle, toHandle in fields(fromHandles, toHandles):
#       duplicate(fromHandle, toHandle)
#       inc openedFiles
#   except:
#     # If this fails, the program should probably just crash.
#     # Something has gone seriously wrong if the standard streams can't
#     # be duplicated to.
#     for toHandle, savedHandle in fields(toHandles, savedHandles):
#       if openedFiles <= 0:
#         break
#       duplicate(savedHandle, toHandle)
#       dec openedFiles



# # ## Public Interface ## #
# type CommandPipes* = tuple[
#   output : FileHandle,
#   errput : FileHandle,
#   input  : FileHandle
# ]


# proc initCommandPipes*(cmdFiles: var CommandPipes) =
#   var openedFiles = duplicateMany((
#     getFileHandle(stdout),
#     getFileHandle(stderr),
#     getFileHandle(stdin),
#   ))
#   cmdFiles.output = openedFiles[0]
#   cmdFiles.errput = openedFiles[1]
#   cmdFiles.input  = openedFiles[2]


# proc initCommandPipes*(): CommandPipes =
#   initCommandPipes(result)


# proc closeCommandPipes*(cmdFiles: CommandPipes) =
#   discard close(cmdFiles.output)
#   discard close(cmdFiles.errput)
#   discard close(cmdFiles.input)


# template genCommandPipesAccessor(accessor, member) =

#   proc `accessor =`*(cmdFiles: var CommandPipes, file: File) =
#     var result = getFileHandle(file)
#     if   result == getFileHandle(stdout): result = cmdFiles.output
#     elif result == getFileHandle(stderr): result = cmdFiles.errput
#     elif result == getFileHandle(stdin):  result = cmdFiles.input
#     duplicate(result, cmdFiles.member)

#   proc accessor*(cmdFiles: CommandPipes): FileHandle =
#     result = cmdFiles.member


# genCommandPipesAccessor(output, output)
# genCommandPipesAccessor(errput, errput)
# genCommandPipesAccessor(input, input)


# template set*(cmdFiles: CommandPipes) =
#   duplicateMany(
#     cmdFiles,
#     (
#       getFileHandle(stdout),
#       getFileHandle(stderr),
#       getFileHandle(stdin),
#     )
#   )


# proc callExecutable*(
#     executable   : string,
#     arguments    : seq[string],
#     cmdFiles     : CommandPipes): Process =

#   # Save standard output streams
#   var oldCmdFiles: CommandPipes
#   initCommandPipes(oldCmdFiles)
#   defer:
#     closeCommandPipes(oldCmdFiles)

#   # Set the standard streams
#   defer:
#     set(oldCmdFiles)
#   set(cmdFiles)

#   # Start the process using parent streams, which have
#   # just been redirected
#   result = startProcess(
#     command = executable,
#     args    = arguments,
#     options = {poParentStreams}
#   )

#   # Wait for the process to exit, discarding the return code.
#   discard waitForExit(result)