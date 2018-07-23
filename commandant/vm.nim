import tables, osproc, os, strformat, sequtils, streams, posix
import strutils

import lexer, parser, subprocess, treeutils, options


type
  VariableMap* = Table[string, seq[string]]
  FunctionMap* = Table[string, seq[AstNode]]

  VmInputProc* = proc (
    vm: CommandantVm,
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
      astBlock*   : seq[AstNode]
      execIndex*  : int

  CommandantVm* = ref object
    parser    : Parser
    inputProc : VmInputProc
    callStack : seq[StackFrame]
    depth     : int


# ## Basic VM Procedures ## #
proc execNode*(vm: CommandantVm, node: AstNode)
proc execLine*(vm: CommandantVm, node: AstNode)
proc `lastExitCode=`*(vm: CommandantVm, value: string) {.inline.}
proc `lastExitCode`*(vm: CommandantVm): string {.inline.}


proc newCommandantVm*(inputProc: VmInputProc): CommandantVm =
  new(result)
  result.parser    = newParser()
  result.inputProc = inputProc
  result.callStack = @[StackFrame(
    isRoot    : true,
    isFinished: false,
    variables : initTable[string, seq[string]](),
    functions : initTable[string, seq[AstNode]]()
  )]

  result.lastExitCode = "0"


proc nextCommand(vm: CommandantVm): Option[AstNode] =
  var line = ""

  while line == "":
    let inputOpen = vm.inputProc(vm, line)
    if not inputOpen:
      return none(AstNode)

    line = strip(line)

  result = some(parse(vm.parser, line))


proc runFrame(vm: CommandantVm, frame: StackFrame) =
  if frame.isRoot:
    let wrappedNode = nextCommand(vm)
    if isNone(wrappedNode):
      frame.isFinished = true
    else:
      execLine(vm, get(wrappedNode))
  else:
    execLine(vm, frame.astBlock[frame.execIndex])
    inc frame.execIndex


proc finished(frame: StackFrame): bool =
  case frame.isRoot
  of true:
    return frame.isFinished
  of false:
    return frame.execIndex >= len(frame.astBlock)


proc run*(vm: var CommandantVm) =
  while true:
    let frame = vm.callStack[^1]
    runFrame(vm, frame)

    if frame.finished:
      setLen(vm.callStack, high(vm.callStack))
    if len(vm.callStack) == 0:
      quit()


# ## Variable Procedures ## #
proc findFuncFrame(vm: CommandantVm, name: string): Option[StackFrame] =
  for index in countDown(high(vm.callStack), 0):
    let frame = vm.callStack[index]
    if name in frame.functions:
      result = some(frame)
      break


proc setFunc(vm: CommandantVm, name: string, values: seq[AstNode]) =
  let frame = vm.callStack[^1]
  frame.functions[name] = values


proc getFunc(vm: CommandantVm, name: string): Option[seq[AstNode]] =
  let frame = findFuncFrame(vm, name)
  if isSome(frame):
    result = some(get(frame).functions[name])


proc setVar(vm: CommandantVm, name: string, values: seq[string]) =
  let frame = vm.callStack[0]
  frame.variables[name] = values


proc setLocalVar(vm: CommandantVm, name: string, values: seq[string]) =
  let frame = vm.callStack[^1]
  frame.variables[name] = values


proc findVarFrame(vm: CommandantVm, name: string): Option[StackFrame] =
  for index in countDown(high(vm.callStack), 0):
    let frame = vm.callStack[index]
    if name in frame.variables:
      result = some(frame)
      break


proc getVar(vm: CommandantVm, name: string): Option[seq[string]] =
  let frame = findVarFrame(vm, name)
  if isSome(frame):
    result = some(get(frame).variables[name])


proc delVar(vm: CommandantVm, name: string) =
  let frame = findVarFrame(vm, name)
  if isSome(frame):
    del(get(frame).variables, name)


proc hasVar(vm: CommandantVm, name: string): bool =
  let frame = findVarFrame(vm, name)
  if isSome(frame):
    result = true


# Builtin Variable Setters/Getters
proc `lastExitCode=`*(vm: CommandantVm, value: string) {.inline.} =
  setVar(vm, "lastExitCode", @[value])

proc `lastExitCode`*(vm: CommandantVm): string {.inline.} =
  result = get(getVar(vm, "lastExitCode"))[0]


# ## Execution Procedures ## #
proc tryCallCommand(
    vm        : CommandantVm,
    executable: string,
    arguments : seq[string],
    cmdFiles  : CommandFiles
)
proc tryCallCommand(
    vm        : CommandantVm,
    arguments : seq[string],
    cmdFiles  : CommandFiles
)

# Include the modules containing code for executing builtins
include builtins

# ### Command Execution ### #
proc tryCallFunction(
    vm        : CommandantVm,
    executable: string,
    arguments : seq[string],
    cmdFiles   : CommandFiles): bool =

  # Find the frame where the function is defined.
  var localFrame = vm.callStack[^1]
  var rootFrame = vm.callStack[0]

  var sourceFrame: StackFrame
  for frame in [localFrame, rootFrame]:
    if executable in frame.functions:
      sourceFrame = frame
      result = true

  if not result:
    return result

  # Retrieve the function AST, create a new stack frame, then execute.
  var functionFrame = StackFrame(
    isRoot   : false,
    execIndex: 0,
    astBlock : sourceFrame.functions[executable],
    variables: initTable[string, seq[string]](),
    functions: initTable[string, seq[AstNode]]()
  )

  add(vm.callStack, functionFrame)


proc tryCallStatement(
    vm        : CommandantVm,
    executable: string,
    arguments : seq[string],
    commands  : seq[AstNode],
    cmdFiles  : CommandFiles): bool =
  let statement = getStatement(executable)
  result = isSome(statement)

  if result:
    discard get(statement)(
      vm         = vm, 
      executable = executable, 
      arguments  = arguments, 
      commands   = commands,
      cmdFiles   = cmdFiles,
    )


proc tryCallBuiltin(
    vm        : CommandantVm,
    executable: string,
    arguments : seq[string],
    cmdFiles   : CommandFiles): bool =
  let builtin = getBuiltin(executable)
  result = isSome(builtin)

  if result:
    vm.lastExitCode = $get(builtin)(
      vm         = vm, 
      executable = executable, 
      arguments  = arguments, 
      cmdFiles   = cmdFiles,
    )


proc tryCallExecutable(
    vm        : CommandantVm,
    executable: string,
    arguments : seq[string],
    cmdFiles  : CommandFiles): bool =
  let resolvedExe = findExe(executable)
  if resolvedExe == "":
    return false

  result = true
  let process = callExecutable(
    executable = resolvedExe,
    arguments  = arguments,
    cmdFiles   = cmdFiles
  )


proc handleInvalidCommand(
    vm        : CommandantVm,
    executable: string,
    arguments : seq[string],
    files   : CommandFiles) =
  vm.lastExitCode = "1"

  if existsDir(executable):
      echo fmt"'{executable}' is a directory."
  else:
    echo fmt"Cannot find command/executable '{executable}'."


proc tryCallCommand(
    vm        : CommandantVm,
    executable: string,
    arguments : seq[string],
    cmdFiles   : CommandFiles) =

  let validCommand = (
    tryCallBuiltin(vm, executable, arguments, cmdFiles) or
    tryCallFunction(vm, executable, arguments, cmdFiles) or
    tryCallExecutable(vm, executable, arguments, cmdFiles) 
  )

  # Handle invalid command
  if not validCommand:
    vm.lastExitCode = "1"
    handleInvalidCommand(vm, executable, arguments, cmdFiles)


proc tryCallCommand(
    vm        : CommandantVm,
    arguments : seq[string],
    cmdFiles  : CommandFiles) =
  tryCallCommand(vm, arguments[0], arguments[1..^1], cmdFiles)


proc openFileToken(fileToken: Token, mode: FileMode): File =
  case fileToken.kind
  of strToken:
    result = open(fileToken.data, mode)
  of wordToken:
    var sourceHandle, destHandle: FileHandle
    case fileToken.data:
    of "stdout":
      result = stdout
    of "stderr":
      result = stderr
    of "stdin":
      result = stdin
    else:
      result = open(fileToken.data, mode)
  else:
    raise newException(ValueError, "openFile: Invalid file token.")


proc getCommandFiles*(node: AstNode): CommandFiles =
  assert node.kind == outputNode
  initCommandFiles(result)

  for child in node.children:
    let
      operatorKind = child.children[0].term.kind
      fileToken = child.children[1].term

    template setCmdFile(member, mode) =
      discard close(result.member)
      result.member = openFileToken(fileToken, mode)

    case operatorKind
    of stdoutToken   : setCmdFile(output, fmWrite)
    of stdoutAppToken: setCmdFile(output, fmAppend)
    of stderrToken   : setCmdFile(errput, fmWrite)
    of stderrAppToken: setCmdFile(errput, fmAppend)
    of stdinToken    : setCmdFile(input,  fmRead)
    else:
      raise newException(ValueError, "Unexpected output token.")


# ## AST Preprocessing ## #
proc isEndCommand(commandAst: AstNode): bool =
  result = (
    commandAst.kind == commandNode and
    len(commandAst.children) == 2  and
    commandAst.children[1].term.data == "end"
  )


proc isStatement(commandAst: AstNode): bool =
  result = (
    commandAst.kind == commandNode and
    isSome(getStatement(commandAst.children[1].term.data))
  )


proc tryProcessingStatement(vm: CommandantVm, node: AstNode): Option[AstNode] =
  if not isStatement(node):
    return

  var commands = @[node]
  while true:
    let commandAstOpt = vm.nextCommand()
    if isNone(commandAstOpt):
      echo "Invalid statement: EOF reached."
      return

    let commandAst = commandAstOpt.get()
    if isEndCommand(commandAst):
      break
    
    let subStatement = tryProcessingStatement(vm, commandAst)
    if isSome(subStatement):
      commands.add(get(subStatement))
    else:
      commands.add(commandAst)

  result = some(makeNode(statementNode, commands))


# ## Node Execution ## #
proc execCommandNode(vm: CommandantVm, node: AstNode) =
  # Sanity check
  assert len(node.children) >= 2
  assert node.kind == commandNode

  # Handle command redirection
  let cmdFiles = getCommandFiles(node.children[0])
  defer:
    closeCommandFiles(cmdFiles)

  # Build command string
  let
    commandParts = toSeq(termsData(node))
    executable   = commandParts[0]
    arguments    = commandParts[1..^1]

  # Call builtin or command
  tryCallCommand(vm, executable, arguments, cmdFiles)


proc execStatement(vm: CommandantVm, node: AstNode) =
  # Sanity check
  assert len(node.children) >= 2
  assert node.kind == statementNode

  let
    statement = node.children[0]
    commands  = node.children[1..^1]

  # Handle command redirection
  let cmdFiles = getCommandFiles(statement.children[0])
  defer:
    closeCommandFiles(cmdFiles)

  # Build command string
  let
    commandParts = toSeq(termsData(statement))
    executable   = commandParts[0]
    arguments    = commandParts[1..^1]

  # Call builtin or command
  discard tryCallStatement(vm, executable, arguments, commands, cmdFiles)


proc execSeperatorNode(vm: CommandantVm, node: AstNode) =
  # echo "In execSeperatorNode:"
  # echo nodeRepr(node, 1)
  
  execNode(vm, node.children[1])

  let seperatorKind = node.children[0].term.kind
  case seperatorKind
  of andSepToken:
    if vm.lastExitCode == "0":
      execNode(vm, node.children[2])
  of orSepToken:
    if vm.lastExitCode != "0":
      execNode(vm, node.children[2])
  of semiSepToken:
    execNode(vm, node.children[2])
  else:
    raise newException(ValueError, "Unexpected node")


# ## Root Execution ## #
proc execNode*(vm: CommandantVm, node: AstNode) =
  case node.kind
  of commandNode:
    execCommandNode(vm, node)
  of seperatorNode:
    execSeperatorNode(vm, node)
  of expressionNode:
    for child in node.children:
      execNode(vm, node)
  else:
    raise newException(ValueError, "Invalid node to execute.")


proc execLine*(vm: CommandantVm, node: AstNode) =
  case node.kind
  of commandNode:
    let statementOpt = tryProcessingStatement(vm, node)
    if isSome(statementOpt):
      execStatement(vm, get(statementOpt))
    else:
      execCommandNode(vm, node)
  of statementNode:
    execStatement(vm, node)
  of seperatorNode:
    execSeperatorNode(vm, node)
  of expressionNode:
    for child in node.children:
      execNode(vm, node)
  else:
    raise newException(ValueError, "Invalid node to execute.")
