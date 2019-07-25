{.experimental: "codeReordering".}

import tables, osproc, os, strformat, sequtils, streams, posix, strutils, options
import ".." / [lexer, parser, subprocess, utils]


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

  Job* = object
    state   : JobState
    pid     : Pid
    exitCode: int

  JobState = enum
    jsRunning
    jsVirtual
    jsFinished


# ## Builtins ## #
include builtins
# ## Basic VM Procedures ## #
proc preprocessNode(vm: VM, node: var Node)


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


proc nextCommand(vm: VM): Option[Node] =
  var line = ""

  while line == "":
    let inputOpen = vm.inputProc(vm, line)
    if not inputOpen:
      return none(Node)

  result = some(parse(vm.lexer, line))
  if isSome(result):
    preprocessNode(vm, get(result))


proc preprocessNode(vm: VM, node: var Node) =
  if not isStatement(node):
    return

  node.children.add(Node(kind: NKBody))
  while true:
    let wrappedCommand = vm.nextCommand()

    if isNone(wrappedCommand):
      raise newException(
        Exception,
        "Invalid statement: EOF reached."
      )

    let command = get(wrappedCommand)
    if isEndCommand(command):
      break

    node.children[^1].children.add(command)

  var newNode = Node(kind: NKStatement)
  shallowCopy(newNode.token, node.token)
  shallowCopy(newNode.unlinked, node.unlinked)
  shallowCopy(newNode.children, node.children)
  shallowCopy(node, newNode)


proc runFrame(vm: VM, frame: StackFrame, pipes: CommandPipes): Job =
  # Are we in a position to read the next command?
  if frame.isRoot:
    let wrappedNode = nextCommand(vm)
    if isNone(wrappedNode):
      frame.isFinished = true
      return

    result = execNode(vm, get(wrappedNode), pipes)

  else:
    result = execNode(vm, frame.astBlock[frame.execIndex], pipes)
    inc frame.execIndex

  vm.wait(result)


proc finished(frame: StackFrame): bool =
  case frame.isRoot
  of true:
    return frame.isFinished
  of false:
    return frame.execIndex >= len(frame.astBlock)


proc run*(vm: var VM) =
  let pipes = initStandardPipes()
  while true:
    let frame = vm.callStack[0]
    discard runFrame(vm, frame, pipes)

    if frame.finished:
      quit()


proc wait(vm: VM, job: var Job) =
  case job.state
  of jsFinished:
    return
  of jsVirtual:
    job.state = jsFinished
  of jsRunning:
    job.state = jsFinished

    var
      status     = cint(0)
      waitResult = waitpid(job.pid, status, 0)

    if waitResult == -1:
      raiseOSError(osLastError())
    elif WIFEXITED(status):
      job.exitCode = WEXITSTATUS(status)

  vm.lastExitCode = $job.exitCode

proc callCommand(vm: VM, arguments: seq[string], pipes: CommandPipes): Job
proc tryCallFunction(
    vm        : VM,
    arguments : seq[string],
    pipes     : CommandPipes,
    job       : var Job): bool

proc callCommand(vm: VM, arguments: seq[string], pipes: CommandPipes): Job =
  # Is the command a function?
  # Is it a builtin?
  # It must be a native executable.
  let valid = (
    tryCallFunction(vm, arguments, pipes, result) or 
    tryCallBuiltin(vm, arguments, pipes, result)  or 
    tryCallExecutable(vm, arguments, pipes, result)
  )


proc callStatement(vm: VM, arguments: seq[string], body: seq[Node], pipes: CommandPipes): Job =
  let wrappedStatement = getStatement(arguments[0])
  if isSome(wrappedStatement):
    result.pid      = 0
    result.state    = jsVirtual
    result.exitCode = get(wrappedStatement)(vm, arguments, body, pipes)
  else:
    raise newException(
      Exception,
      fmt"Called non-existant statement {arguments[0]}"
    )


proc tryCallFunction(
    vm        : VM,
    arguments : seq[string],
    pipes     : CommandPipes,
    job       : var Job): bool =
  # Find the frame where the function is defined.
  let executable = arguments[0]
  var localFrame = vm.callStack[^1]
  var rootFrame  = vm.callStack[0]

  var sourceFrame: StackFrame
  for frame in [localFrame, rootFrame]:
    if executable in frame.functions:
      sourceFrame = frame
      result = true

  if not result:
    return result

  # Retrieve the function AST, create a new stack frame, then execute.
  let functionFrame = StackFrame(
    isRoot   : false,
    execIndex: 0,
    astBlock : sourceFrame.functions[executable],
    variables: initTable[string, seq[string]](),
    functions: initTable[string, seq[Node]]()
  )

  add(vm.callStack, functionFrame)
  while not functionFrame.finished:
    job = runFrame(vm, functionFrame, pipes)
  setLen(vm.callStack, high(vm.callStack))


proc tryCallBuiltin(
    vm        : VM,
    arguments : seq[string],
    pipes     : CommandPipes,
    job       : var Job): bool =
  let wrappedBuiltin = getBuiltin(arguments[0])
  if isSome(wrappedBuiltin):
    job.pid      = 0
    job.state    = jsVirtual
    job.exitCode = get(wrappedBuiltin)(vm, arguments, pipes)
    result = true 


proc tryCallExecutable(
    vm        : VM,
    arguments : seq[string],
    pipes     : CommandPipes,
    job       : var Job): bool =
  try:
    job.pid      = spawnProcess(arguments, pipes)
    job.state    = jsRunning
    job.exitCode = 0
  except OSError as error:
    let arglist = arguments.join(" ")
    echo fmt"shell: {arglist}: {error.msg}"
    job.state    = jsVirtual
    job.exitCode = 128


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



# ## AST Execution ## #
include  execution