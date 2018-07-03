import tables, regex, osproc, os, strformat, sequtils, streams, posix
import lexer, parser, treeutils


# Low-level Constants/Procedures
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


# Constants
const varRegex = toPattern(r"\$\(([^ \\t]+)\)")


type
  VariableFrame* = Table[string, seq[AstNode]]
  CommandantVm* = ref object
    variables*: VariableFrame
    lastExitCode*: string


proc newCommandantVm*(): CommandantVm =
  new(result)
  result.variables = initTable[string, seq[AstNode]]()


# ## File Redirection Procedures ## #
type CommandFiles* = object
  output*, errput*, input*: File


proc filteredClose(file: File) =
  let core = (
    file == stdin or
    file == stdout or
    file == stderr
  )
  if not core:
    close(file)


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


# ## Execution Procedures ## #
proc execCommandNode(vm: CommandantVm, node: AstNode)
proc execSeperatorNode(vm: CommandantVm, node: AstNode)
proc execNode*(vm: CommandantVm, node: AstNode)


proc tryCallBuiltin(
    vm        : CommandantVm,
    executable: string,
    arguments : seq[string],
    cmdFiles   : CommandFiles): bool =
  result = false


proc tryCallExecutable(
    vm           : CommandantVm,
    unresolvedExe: string,
    arguments    : seq[string],
    cmdFiles     : CommandFiles): bool =
  # Resolve the executable location
  let resolvedExe = findExe(unresolvedExe)
  if resolvedExe == "":
    return false

  # Start the subprocess
  echo fmt"Starting process {unresolvedExe} with paramters {arguments}"

  # Save cmdFiles
  let
    savedStdout = dup_fd(STDOUT_FILENO)
    savedStderr = dup_fd(STDERR_FILENO)
    savedStdin = dup_fd(STDIN_FILENO)

  # Restore cmdFiles at the end of the function
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

  let subprocess = startProcess(
    command = resolvedExe,
    args    = arguments,
    options = {poParentStreams}
  )

  vm.lastExitCode = $waitForExit(subprocess)
  result = true


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


proc execCommandNode(vm: CommandantVm, node: AstNode) =
  # echo "In execCommandNode:"
  # echo nodeRepr(node, 1)
  
  # Sanity check
  assert len(node.children) >= 2
  assert node.kind == commandNode

  # Handle command redirection
  let stdFiles = getCommandFiles(node.children[0])
  defer:
    filteredClose(stdFiles.output)
    filteredClose(stdFiles.errput)
    filteredClose(stdFiles.input)

  # Build command string
  let
    commandParts = toSeq(termsData(node))
    executable   = commandParts[0]
    arguments    = commandParts[1..^1]

  # Call builtin or command
  let validCommand = (
    tryCallBuiltin(vm, executable, arguments, stdFiles) or
    tryCallExecutable(vm, executable, arguments, stdFiles) 
  )

  # Handle invalid command
  if not validCommand:
    vm.lastExitCode = "1"
    handleInvalidCommand(vm, executable, arguments, stdFiles)


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
