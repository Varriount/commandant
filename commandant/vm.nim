import tables, regex, osproc, os, strformat, sequtils, streams, posix
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

  VmInputMode* = enum
    imCommand
    imFunction

  CommandantVm* = ref object
    parser*    : Parser
    inputProc* : VmInputProc
    inputMode* : VmInputMode
    variables* : VariableMap
    functions* : FunctionMap


# ## Basic VM Procedures ## #
proc execNode*(vm: CommandantVm, node: AstNode)


proc newCommandantVm*(inputProc: VmInputProc): CommandantVm =
  new(result)
  result.parser = newParser()
  result.variables = initTable[string, seq[string]]()
  result.functions = initTable[string, seq[AstNode]]()
  result.inputProc = inputProc

  result.variables["lastExitCode"] = @["0"]


proc `lastExitCode=`*(vm: CommandantVm, value: string) {.inline.} =
  vm.variables["lastExitCode"][0] = value

proc `lastExitCode`*(vm: CommandantVm): string {.inline.} =
  result = vm.variables["lastExitCode"][0]


proc nextCommand(vm: CommandantVm): Option[AstNode] =
  var
    line = ""
    inputOpen = true

  while line == "" and inputOpen:
    inputOpen = vm.inputProc(vm, line)
    line = strip(line)

  if not inputOpen:
    return none(AstNode)

  result = some(parse(vm.parser, line))


proc run*(vm: var CommandantVm) =
  while true:
    let commandAst = nextCommand(vm)
    # echo nodeRepr(commandAst.get())
    if isSome(commandAst):
      execNode(vm, get(commandAst))
    else:
      break


# ## Execution Procedures ## #
# Include the modules containing code for executing builtins
include builtins


# ### Command Execution ### #
proc tryCallFunction(
    vm        : CommandantVm,
    executable: string,
    arguments : seq[string],
    cmdFiles   : CommandFiles): bool =
  result = (executable in vm.functions)
  if not result:
    return result

  let functionAsts = vm.functions[executable]
  for node in functionAsts:
    vm.execNode(node)



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
