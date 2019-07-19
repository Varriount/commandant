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


# ## Basic VM Procedures ## #
proc execNode*(vm: VM, node: Node, pipes: CommandPipes): Pid
proc execSeperator(vm: VM, node: Node, pipes: CommandPipes): Pid
proc execCommand(vm: VM, node: Node, pipes: CommandPipes): Pid
proc `lastExitCode=`*(vm: VM, value: string) {.inline.}
proc `lastExitCode`*(vm: VM): string {.inline.}
proc waitOnPID(vm: VM, pid: PID)


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

      var pid = execNode(vm, get(wrappedNode), pipes)
      vm.waitOnPID(pid)
  else:
    var pid = execNode(vm, frame.astBlock[frame.execIndex], initStandardPipes())
    vm.waitOnPID(pid)
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


proc waitOnPID(vm: VM, pid: PID) =
  var
    status     = cint(0)
    waitResult = waitpid(pid, status, 0)

  if pid == -1:
    raiseOSError(osLastError())
  elif WIFEXITED(status):
    vm.lastExitCode = $WEXITSTATUS(status)


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
proc resolveVariableSub(vm: VM, node: Node, pipes: CommandPipes, result: var string)


proc execNode(vm: VM, node: Node, pipes: CommandPipes): Pid = 
  case node.kind
  of NKCommand:
    result = execCommand(vm, node, pipes)
  of NKSeperator:
    result = execSeperator(vm, node, pipes)
  else:
    raise newException(Exception, fmt"Bad node: {node.kind}")

proc execSeperator(vm: VM, node: Node, pipes: CommandPipes): Pid =
  case node.token.data
  of "&&":
    result = execNode(vm, node.children[0], pipes)
    vm.waitOnPID(result)
    if vm.lastExitCode == "0":
      result = execNode(vm, node.children[1], pipes)

  of "||":
    result = execNode(vm, node.children[0], pipes)
    vm.waitOnPID(result)
    if vm.lastExitCode != "0":
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
    
    discard execNode(vm, node.children[0], leftpipes)
    discard execNode(vm, node.children[1], rightpipes)
  else:
    raise newException(Exception, "Bad seperator")


proc execCommand(vm: VM, node: Node, pipes: CommandPipes): Pid =
  var arguments: seq[string]

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
      resolveVariableSub(vm, child, pipes, arguments[^1])
    else:
      raise newException(Exception, fmt"Bad node: {child.kind}")

  echo repr(arguments)
  result = spawnProcess(arguments, pipes)


proc modRedirect(vm: VM, node: Node) =
  discard


proc resolveString(vm: VM, node: Node, pipes: CommandPipes, result: var string) =
  for child in node.children:
    case child.kind
    of NKStringData:
      add(result, child.token.data)
    of NKVariableSub:
      resolveVariableSub(vm, child, pipes, result)
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
  var pid = execCommand(vm, node.children[0], subPipes)
  closeEnd(subPipes.output.writeEnd)

  # Read the output
  var buffer: array[128, char]

  while true:
    let readCount = read(
      connectingPipe.readEnd, # File descriptor
      addr buffer[0],         # Buffer address
      128                     # Buffer length
    )

    if readCount == 0:
      break
    elif readCount == -1:
      raiseOSError(osLastError())

    for i in 0..(readCount - 1):
      result.add(buffer[i])
  
  vm.waitOnPID(pid)


proc resolveVariableSub(vm: VM, node: Node, pipes: CommandPipes, result: var string) =
  let
    variableWord = node.children[0].token.data
    variableOpt  = getVar(vm, variableWord)

  if not isNone(variableOpt):
    let variable = variableOpt.get()

    for element in variable:
      result.add(element)
      result.add(' ')

    result.setLen(high(result))


