import tables, regex, osproc, os, strformat, sequtils, streams, posix
import strutils
import lexer, parser, subprocess, treeutils, strutils, options


# Constants
const varRegex = toPattern(r"\$\(([^ \\t]+)\)")


type
  VariableMap* = Table[string, seq[string]]
  FunctionMap* = Table[string, seq[AstNode]]

  VmInputProc* = proc (
    vm: CommandantVm,
    output: var string
  ): bool {.closure.}

  StackFrame = ref object
    parent*     : StackFrame
    execIndex*  : int
    astBlock*   : seq[AstNode]
    variables*  : VariableMap
    functions*  : FunctionMap

  CommandantVm* = ref object
    parser*    : Parser
    inputProc* : VmInputProc
    callStack  : seq[StackFrame]


# ## Basic VM Procedures ## #
proc execNode*(vm: CommandantVm, node: AstNode)


proc newCommandantVm*(inputProc: VmInputProc): CommandantVm =
  new(result)
  result.parser = newParser()
  result.inputProc = inputProc
  result.callStack = @[StackFrame(
    parent     : nil,
    execIndex  : 0,
    astBlock   : nil,
    variables  : initTable[string, seq[string]](),
    functions  : initTable[string, seq[AstNode]]()
  )]

  result.callStack[0].variables["lastExitCode"] = @["0"]


proc `lastExitCode=`*(vm: CommandantVm, value: string) {.inline.} =
  vm.callStack[0].variables["lastExitCode"] = @[value]

proc `lastExitCode`*(vm: CommandantVm): string {.inline.} =
  result = vm.callStack[0].variables["lastExitCode"][0]


proc nextCommand(vm: CommandantVm): Option[AstNode] =
  var frame = vm.callStack[^1]

  if len(vm.callStack) == 1:
    var line = ""

    while line == "":
      let inputOpen = vm.inputProc(vm, line)
      if not inputOpen:
        return none(AstNode)
      line = strip(line)

    result = some(parse(vm.parser, line))
  else:
    result = some(frame.astBlock[frame.execIndex])
    inc frame.execIndex


proc run*(vm: var CommandantVm) =
  while true:
    let commandAst = nextCommand(vm)
    # echo nodeRepr(commandAst.get())
    if isSome(commandAst):
      execNode(vm, get(commandAst))
    else:
      break


# Frame Procedures
proc execute(vm: CommandantVm, frame: StackFrame) = 
  while frame.execIndex < len(frame.astBlock):
    echo frame.execIndex
    execNode(vm, frame.astBlock[frame.execIndex])
    inc frame.execIndex


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


# ## Execution Procedures ## #
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
    parent   : sourceFrame,
    execIndex: 0,
    astBlock : sourceFrame.functions[executable],
    variables: initTable[string, seq[string]](),
    functions: initTable[string, seq[AstNode]]()
  )

  add(vm.callStack, functionFrame)
  execute(vm, functionFrame)
  setLen(vm.callStack, high(vm.callStack))


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
    cmdFiles   : CommandFiles): bool =
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


proc execCommandNode(vm: CommandantVm, node: AstNode) =
  # echo "In execCommandNode:"
  # echo nodeRepr(node, 1)
  
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
  let validCommand = (
    tryCallBuiltin(vm, executable, arguments, cmdFiles) or
    tryCallFunction(vm, executable, arguments, cmdFiles) or
    tryCallExecutable(vm, executable, arguments, cmdFiles) 
  )

  # Handle invalid command
  if not validCommand:
    vm.lastExitCode = "1"
    handleInvalidCommand(vm, executable, arguments, cmdFiles)


# ## Seperator Execution ## #
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
  # echo "In execNode:"
  # echo nodeRepr(node, 1)

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
