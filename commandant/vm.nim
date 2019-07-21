{.experimental: "codeReordering".}
import tables, osproc, os, strformat, sequtils, streams, posix, strutils
import lexer, parser, subprocess, options, utils


type
  VariableMap* = Table[string, seq[string]]
  FunctionMap* = Table[string, seq[Node]]

  VmInputProc* = proc (
    vm: VM,
    output: var string
  ): bool {.closure.}
    ## Used by the VM to retrieve the next line of input.

  StackFrame = ref object
    variables*  : VariableMap
    functions*  : FunctionMap
    case isRoot: bool
    of true:
      isFinished: bool
    of false:
      astBlock*   : seq[Node]
      execIndex*  : int

  VM* = ref object
    lexer     : Lexer
    inputProc : VmInputProc
    callStack : seq[StackFrame]
    depth     : int
    signalMask: SigSet
    childBlock: int

  Job* = object
    finished: bool
    pid     : Pid
    exitCode: int


# ## Basic VM Procedures ## #
proc execNode*(vm: VM, node: Node, pipes: CommandPipes): Job
proc execSeperator(vm: VM, node: Node, pipes: CommandPipes): Job
proc execCommand(vm: VM, node: Node, pipes: CommandPipes): Job
proc `lastExitCode=`*(vm: VM, value: string) {.inline.}
proc `lastExitCode`*(vm: VM): string {.inline.}
proc wait*(vm: VM, job: var Job)


proc newVM*(inputProc: VmInputProc): VM =
  new(result)
  result.lexer    = newLexer()
  result.inputProc = inputProc
  result.callStack = @[StackFrame(
    isRoot    : true,
    isFinished: false,
    variables : initTable[string, seq[string]](),
    functions : initTable[string, seq[Node]]()
  )]

  result.lastExitCode = "0"
  discard sigEmptySet(result.signalMask);
  discard sigAddSet(result.signalMask, SIGCHLD);


proc nextCommand(vm: VM): Option[Node] =
  var line = ""

  while line == "":
    let inputOpen = vm.inputProc(vm, line)
    if not inputOpen:
      return none(Node)

    line = strip(line)

  result = some(parse(vm.lexer, line))


proc runFrame(vm: VM, frame: StackFrame) =
  if frame.isRoot:
    let wrappedNode = nextCommand(vm)
    if isNone(wrappedNode):
      frame.isFinished = true
    else:
      var pipes = initStandardPipes()
      defer: close(pipes)

      var job = execNode(vm, get(wrappedNode), pipes)
      vm.wait(job)
  else:
    var job = execNode(vm, frame.astBlock[frame.execIndex], initStandardPipes())
    vm.wait(job)
    inc frame.execIndex


proc finished(frame: StackFrame): bool =
  case frame.isRoot
  of true:
    return frame.isFinished
  of false:
    return frame.execIndex >= len(frame.astBlock)


proc run*(vm: var VM) =
  while true:
    let frame = vm.callStack[^1]
    runFrame(vm, frame)

    if frame.finished:
      setLen(vm.callStack, high(vm.callStack))
    if len(vm.callStack) == 0:
      quit()


proc blockChildSignals(vm: var VM) =
  if vm.childBlock == 0:
    discard sigprocmask(SIG_BLOCK, vm.signalMask, cast[var SigSet](nil));
  inc vm.childBlock


proc unblockChildSignals(vm: var VM) =
  dec vm.childBlock
  if vm.childBlock == 0:
    discard sigprocmask(SIG_UNBLOCK, vm.signalMask, cast[var SigSet](nil));


proc wait(vm: VM, job: var Job) =
  if job.finished:
    return
  job.finished = true

  var
    status     = cint(0)
    waitResult = waitpid(job.pid, status, 0)

  if waitResult == -1:
    raiseOSError(osLastError())
  elif WIFEXITED(status):
    job.exitCode = WEXITSTATUS(status)


# ## Variable/Function Procedures ## #
proc findFuncFrame(vm: VM, name: string): Option[StackFrame] =
  for index in countDown(high(vm.callStack), 0):
    let frame = vm.callStack[index]
    if name in frame.functions:
      result = some(frame)
      break


proc setFunc(vm: VM, name: string, values: seq[Node]) =
  let frame = vm.callStack[^1]
  frame.functions[name] = values


proc getFunc(vm: VM, name: string): Option[seq[Node]] =
  let frame = findFuncFrame(vm, name)
  if isSome(frame):
    result = some(get(frame).functions[name])


proc setVar(vm: VM, name: string, values: seq[string]) =
  let frame = vm.callStack[0]
  frame.variables[name] = values


proc setLocalVar(vm: VM, name: string, values: seq[string]) =
  let frame = vm.callStack[^1]
  frame.variables[name] = values


proc findVarFrame(vm: VM, name: string): Option[StackFrame] =
  for index in countDown(high(vm.callStack), 0):
    let frame = vm.callStack[index]
    if name in frame.variables:
      result = some(frame)
      break


proc getVar(vm: VM, name: string): Option[seq[string]] =
  let frame = findVarFrame(vm, name)
  if isSome(frame):
    result = some(get(frame).variables[name])


proc delVar(vm: VM, name: string) =
  let frame = findVarFrame(vm, name)
  if isSome(frame):
    del(get(frame).variables, name)


proc hasVar(vm: VM, name: string): bool =
  let frame = findVarFrame(vm, name)
  if isSome(frame):
    result = true


# Builtin Variable Setters/Getters
proc `lastExitCode=`*(vm: VM, value: string) {.inline.} =
  setVar(vm, "lastExitCode", @[value])

proc `lastExitCode`*(vm: VM): string {.inline.} =
  result = get(getVar(vm, "lastExitCode"))[0]


# ## AST Preprocessing ## #
proc resolveString(vm: VM, node: Node, pipes: CommandPipes, result: var string)
proc resolveCommandSub(vm: VM, node: Node, pipes: CommandPipes, result: var string)


proc execNode(vm: VM, node: Node, pipes: CommandPipes): Job = 
  case node.kind
  of NKCommand:
    result = execCommand(vm, node, pipes)
  of NKSeperator:
    result = execSeperator(vm, node, pipes)
  else:
    raise newException(Exception, fmt"Bad node: {node.kind}")


proc execSeperator(vm: VM, node: Node, pipes: CommandPipes): Job =
  case node.token.data
  of "&&":
    result = execNode(vm, node.children[0], pipes)
    vm.wait(result)
    if result.exitCode == 0:
      result = execNode(vm, node.children[1], pipes)

  of "||":
    result = execNode(vm, node.children[0], pipes)
    vm.wait(result)
    if result.exitCode != 0:
      discard execNode(vm, node.children[1], pipes)

  of ";":
    discard execNode(vm, node.children[0], pipes)
    discard execNode(vm, node.children[1], pipes)

  of "|":
    var 
      leftPipes      = duplicate(pipes)
      rightPipes     = duplicate(pipes)
      connectingPipe = initPipe()

    defer:
      close(leftPipes)
      close(rightPipes)
      close(connectingPipe)

    swap(leftPipes.output.writeEnd, connectingPipe.writeEnd)
    swap(rightPipes.input.readEnd, connectingPipe.readEnd)
    close(connectingPipe)
    
    discard execNode(vm, node.children[0], leftpipes)
    close(leftPipes)

    result = execNode(vm, node.children[1], rightpipes)
    close(rightPipes)
  else:
    raise newException(Exception, "Bad seperator")


proc execCommand(vm: VM, node: Node, pipes: CommandPipes): Job =
  var
    arguments: seq[string]
    pipes = duplicate(pipes)

  defer: close(pipes)

  var unlinked = true
  for index, child in node.children:
    if unlinked:
      arguments.add("")
    unlinked = child.unlinked

    case child.kind
    of NKWord:
      arguments[^1].add(child.token.data)

    of NKString:
      resolveString(vm, child, pipes, arguments[^1])

    of NKCommandSub:
      resolveCommandSub(vm, child, pipes, arguments[^1])

    of NKVariableSub:
      for piece in resolveVariableSub(vm, child, pipes):
        arguments.add(piece)

    of NKRedirect:
      modRedirect(vm, child, pipes)

    else:
      raise newException(Exception, fmt"Bad node: {child.kind}")

  result.pid = spawnProcess(arguments, pipes)


proc modRedirect(vm: VM, node: Node, pipes: var CommandPipes) =
  template openTarget(mode): auto =
    let
      accessMode = (
        S_IRUSR or S_IWUSR or
        S_IRGRP or S_IWGRP or
        S_IROTH or S_IWOTH
      )

      target = node.children[0].token.data
      fd = posix.open(target, mode, accessMode)

    if fd == -1:
      raise newException(
        Exception,
        fmt"Unable to redirect. OS Error: {$strerror(errno)}"
      )
    PipeEnd(fd)

  case node.token.data
  # Set input to file
  of "<":  
    let targetFd = openTarget(O_RDONLY)
    close(pipes.input.readEnd)
    pipes.input.readEnd = targetFd

  # Set output to file (write)
  of ">":  
    let targetFd = openTarget(O_WRONLY or O_CREAT)
    close(pipes.output.writeEnd)
    pipes.output.writeEnd = targetFd

  # Set output to file (append)
  of ">>": 
    let targetFd = openTarget(O_WRONLY or O_CREAT or O_APPEND)
    close(pipes.output.writeEnd)
    pipes.output.writeEnd = targetFd

  # Set errput to file (write)
  of "!>": 
    let targetFd = openTarget(O_WRONLY or O_CREAT)
    close(pipes.errput.writeEnd)
    pipes.errput.writeEnd = targetFd

  # Set errput to file (append)
  of "!>>":
    let targetFd = openTarget(O_WRONLY or O_CREAT or O_APPEND)
    close(pipes.errput.writeEnd)
    pipes.errput.writeEnd = targetFd

  # Set output and errput to file (write)
  of "&>": 
    let targetFd = openTarget(O_WRONLY or O_CREAT)
    close(pipes.output.writeEnd)
    pipes.output.writeEnd = targetFd
    close(pipes.errput.writeEnd)
    pipes.errput.writeEnd = targetFd

  # Set output and errput to file (append)
  of "&>>":
    let targetFd = openTarget(O_WRONLY or O_CREAT or O_APPEND)
    close(pipes.output.writeEnd)
    pipes.output.writeEnd = targetFd
    close(pipes.errput.writeEnd)
    pipes.errput.writeEnd = targetFd
  else:
    raise newException(Exception, "Invalid redirection operator.")


proc resolveString(vm: VM, node: Node, pipes: CommandPipes, result: var string) =
  for child in node.children:
    case child.kind
    of NKStringData:
      add(result, child.token.data)

    of NKVariableSub:
      for piece in resolveVariableSub(vm, child, pipes):
        result.add(piece)
        result.add(' ')
      setLen(result, high(result))

    of NKCommandSub:
      resolveCommandSub(vm, child, pipes, result)

    else:
      raise newException(Exception, fmt"Bad node: {child.kind}")


proc resolveCommandSub(vm: VM, node: Node, pipes: CommandPipes, result: var string) =
  # Setup the pipes
  var
    connectingPipe = initPipe()
    subPipes       = duplicate(pipes)

  defer:
    close(connectingPipe)
    close(subPipes)

  swap(subPipes.output.writeEnd, connectingPipe.writeEnd)

  # Spawn the subprocess
  var job = execCommand(vm, node.children[0], subPipes)
  close(subPipes.output.writeEnd)

  # Read the output
  read(connectingPipe.readEnd, result)

  # Strip off newlines
  var index = high(result)
  while index > 0 and result[index] in {'\c', '\l'}:
    dec index
  setLen(result, index + 1)
  
  wait(vm, job)


iterator resolveVariableSub(vm: VM, node: Node, pipes: CommandPipes): string =
  let
    variableWord = node.children[0].token.data
    variableOpt  = getVar(vm, variableWord)

  if not isNone(variableOpt):
    let variable = variableOpt.get()

    for element in variable:
      yield element
