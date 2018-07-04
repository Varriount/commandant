import tables, regex, osproc, os, strformat, sequtils, streams, posix
import lexer, parser, subprocess, treeutils




# Constants
const varRegex = toPattern(r"\$\(([^ \\t]+)\)")


type
  VariableFrame* = Table[string, seq[string]]
  CommandantVm* = ref object
    variables*: VariableFrame
    lastExitCode*: string


proc newCommandantVm*(): CommandantVm =
  new(result)
  result.variables = initTable[string, seq[string]]()


# ## Execution Procedures ## #
# Include the modules containing code for executing builtins
include builtins
proc execCommandNode(vm: CommandantVm, node: AstNode)
proc execSeperatorNode(vm: CommandantVm, node: AstNode)
proc execNode*(vm: CommandantVm, node: AstNode)


# ### Command Execution ### #
proc tryCallBuiltin(
    vm        : CommandantVm,
    executable: string,
    arguments : seq[string],
    cmdFiles   : CommandFiles): bool =
  let builtin = findBuiltin(executable)
  if builtin == biUnknown:
    return false

  result = true
  callBuiltin(
    vm        = vm,
    builtin   = builtin,
    arguments = arguments,
    cmdFiles  = cmdFiles,
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

  result.output = stdout
  result.errput = stderr
  result.input = stdin

  for child in node.children:
    let
      operatorKind = child.children[0].term.kind
      fileToken = child.children[1].term

    case operatorKind
    of stdoutToken:
      filteredClose(result.output)
      result.output = openFileToken(fileToken, fmWrite)

    of stdoutAppToken:
      filteredClose(result.output)
      result.output = openFileToken(fileToken, fmAppend)

    of stderrToken:
      filteredClose(result.errput)
      result.errput = openFileToken(fileToken, fmWrite)

    of stderrAppToken:
      filteredClose(result.errput)
      result.errput = openFileToken(fileToken, fmAppend)

    of stdinToken:
      filteredClose(result.input)
      result.input = openFileToken(fileToken, fmRead)
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
    close(cmdFiles)

  # Build command string
  let
    commandParts = toSeq(termsData(node))
    executable   = commandParts[0]
    arguments    = commandParts[1..^1]

  # Call builtin or command
  let validCommand = (
    tryCallBuiltin(vm, executable, arguments, cmdFiles) or
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
  echo "In execNode:"
  echo nodeRepr(node, 1)

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
