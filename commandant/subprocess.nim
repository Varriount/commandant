import os, posix, strformat
import utils


var environ {.importc.}: cstringArray


type
  PipeEnd* = distinct FileHandle

  Pipe* = object
    readEnd*  : PipeEnd
    writeEnd* : PipeEnd

  CommandPipes* = object
    input*  : Pipe
    output* : Pipe
    errput* : Pipe


# ## Pipe End Procedures ## #
const InvalidPipeEnd = PipeEnd(-1)

proc `==`(x: PipeEnd, y: PipeEnd): bool {.borrow.}
proc dup(pipeEnd: PipeEnd): PipeEnd {.borrow.}
proc `$`(pipeEnd: PipeEnd): string {.borrow.}
proc read(a1: PipeEnd; a2: pointer; a3: int): int {.borrow.}


iterator read*(pipeEnd: PipeEnd): char =
  const BufferLength = 128
  var buffer: array[BufferLength, char]

  while true:
    let readCount = read(
      FileHandle(pipeEnd),  # File descriptor
      addr buffer[0],       # Buffer address
      BufferLength          # Buffer length
    )

    if readCount == 0:
      break
    elif readCount == -1:
      raiseOSError(osLastError())

    for i in 0..(readCount - 1):
      yield buffer[i]


proc write*(pipeEnd: PipeEnd, buffer: openarray[char]) =
  if len(buffer) > 0:
    discard write(FileHandle(pipeEnd), unsafeAddr buffer[0], len(buffer))


proc write*(pipeEnd: PipeEnd, c: char) =
  discard write(FileHandle(pipeEnd), unsafeAddr c, 1)


proc close*(pipeEnd: var PipeEnd) =
  if pipeEnd == InvalidPipeEnd:
    return
  chk close(FileHandle(pipeEnd))
  pipeEnd = InvalidPipeEnd


# ## Pipe Procedures ## #
proc initPipe*(): Pipe =
  var res: array[2, cint]
  chk pipe(res)
  result.readEnd  = cast[PipeEnd](res[0])
  result.writeEnd = cast[PipeEnd](res[1])


proc duplicate*(pipe: Pipe): Pipe =
  result.readEnd = InvalidPipeEnd
  if pipe.readEnd != InvalidPipeEnd:
    result.readEnd = dup(pipe.readEnd)
  
  result.writeEnd = InvalidPipeEnd
  if pipe.writeEnd != InvalidPipeEnd:
    result.writeEnd = dup(pipe.writeEnd)


proc close*(pipe: var Pipe) =
  close(pipe.readEnd)
  close(pipe.writeEnd)


# ## CommandPipes Procedures
proc initStandardPipes*(): CommandPipes =
  result.input.writeEnd  = InvalidPipeEnd
  result.input.readEnd   = PipeEnd(dup(getFileHandle(stdin)))
  
  result.output.readEnd  = InvalidPipeEnd
  result.output.writeEnd = PipeEnd(dup(getFileHandle(stdout)))
  
  result.errput.readEnd  = InvalidPipeEnd
  result.errput.writeEnd = PipeEnd(dup(getFileHandle(stderr)))


proc duplicate*(pipes: CommandPipes): CommandPipes =
  result.input  = duplicate(pipes.input)
  result.output = duplicate(pipes.output)
  result.errput = duplicate(pipes.errput)


proc close*(p: var CommandPipes) =
  close(p.input)
  close(p.output)
  close(p.errput)


# ## Posix Wrappers ## #
# Signal Mask
proc initEmptySignalMask(): SigSet =
  chk sig_empty_set(result)

proc addSignal(mask: var SigSet, signal: cint) =
  chk sig_add_set(mask, signal)


# File Actions
type FileActions = TPosixSpawnFileActions

proc initFileActions(): FileActions =
  chk posix_spawn_file_actions_init(result)

proc destroyFileActions(actions: var FileActions) =
  chk posix_spawn_file_actions_destroy(actions)

proc addClose(actions: var FileActions, pipeEnd: PipeEnd) =
  if pipeEnd != InvalidPipeEnd:
    chk posix_spawn_file_actions_add_close(actions, FileHandle(pipeEnd))

proc addDuplicate(actions: var FileActions, srcEnd: PipeEnd, dstEnd: PipeEnd) =
  chk posix_spawn_file_actions_adddup2(
    actions,            # Actions
    FileHandle(srcEnd), # End to duplicate from
    FileHandle(dstEnd)  # End to duplicate into
  )


# Spawn Attributes
type SpawnAttributes = TPosixSpawnAttr
proc initSpawnAttributes(): SpawnAttributes =
  chk posix_spawnattr_init(result)

proc destroySpawnAttributes(attributes: var SpawnAttributes) =
  chk posix_spawnattr_destroy(attributes)

proc setSignalMask(attributes: var SpawnAttributes, mask: var SigSet) =
  chk posix_spawnattr_set_sigmask(attributes, mask)

proc setProcessGroup(attributes: var SpawnAttributes, group: int32) =
  chk posix_spawnattr_set_pgroup(attributes, group)

proc setFlags(attributes: var SpawnAttributes, flags: cint) =
  chk posix_spawn_attr_set_flags(attributes, flags)


# ## Process Spawning Procedures ## #
proc spawnProcess*(commandLine: openarray[string], pipes: CommandPipes): Pid =
  # Initialize file actions and spawn attributes
  var spawnAttributes = initSpawnAttributes()
  defer: destroySpawnAttributes(spawnAttributes)

  var fileActions = initFileActions()
  defer: destroyFileActions(fileActions)

  # Set the subprocess signal mask
  var mask = initEmptySignalMask()
  addSignal(mask, SIGCHLD)
  setSignalMask(spawnAttributes, mask)

  # Set the subprocess process group
  setProcessGroup(spawnAttributes, 0)

  # Set the subprocess file actions
  # Note - this assumes that all file descriptors are unique!
  addClose(fileActions, pipes.input.writeEnd)
  addClose(fileActions, pipes.output.readEnd)
  addClose(fileActions, pipes.errput.readEnd)

  addDuplicate(fileActions, pipes.input.readEnd, PipeEnd(0))
  addDuplicate(fileActions, pipes.output.writeEnd, PipeEnd(1))
  addDuplicate(fileActions, pipes.errput.writeEnd, PipeEnd(2))

  addClose(fileActions, pipes.input.readEnd)
  addClose(fileActions, pipes.output.writeEnd)
  if pipes.errput.writeEnd != pipes.output.writeEnd:
    addClose(fileActions, pipes.errput.writeEnd)

  # Set process flags
  var spawnFlags = (
    POSIX_SPAWN_USEVFORK   or
    POSIX_SPAWN_SETSIGMASK or
    POSIX_SPAWN_SETPGROUP
  )
  setFlags(spawnAttributes, spawnFlags)

  # Allocate command and arguments
  var
    command   = cstring(commandLine[0])
    arguments = allocCStringArray(commandLine)

  defer: deallocCStringArray(arguments)

  # Spawn the process
  # echo fmt"Spawning {command}"
  let res = posixSpawnP(
    result,           # PID
    command,          # Command
    fileActions,      # File actions
    spawnAttributes,  # Spawn attributes
    arguments,        # Command arguments
    environ           # Environment variables
  )
  if res != 0'i32:
    raiseOSError(OSErrorCode(res))
