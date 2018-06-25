import tables, regex, osproc, os, strformat, sequtils
import lexer, parser, treeutils

const varRegex = toPattern(r"\$\(([^ \\t]+)\)")


type
  VariableFrame* = Table[string, seq[AstNode]]
  CommandantVm* = ref object
    variables*: VariableFrame
    lastExitCode*: string


proc newCommandantVm*(): CommandantVm =
  new(result)
  result.variables = initTable[string, seq[AstNode]]()



# iterator processWord(vm: CommandantVm, node: AstNode): AstNode =
#   template getVar(token): seq[AstNode] =
#     let key = token.data[1..high(token.data)]
#     vm.variables[key]

#   let token = node.term
#   case token.kind
#   of wordToken:
#     var match: RegexMatch
#     if match(token.data, varRegex, match):
#       for s in group(match, 0):
#         yield makeNode(termNode, Token(kind, data, position))

#   of strToken:
#     var buffer = ""
#     for match in findAll(data, varRegex):


# ## Execution Procedures ## #
proc execCommandNode(vm: CommandantVm, node: AstNode)
proc execSeperatorNode(vm: CommandantVm, node: AstNode)
proc execNode*(vm: CommandantVm, node: AstNode)


proc execCommandNode(vm: CommandantVm, node: AstNode) =
  echo "In execCommandNode:"
  echo nodeRepr(node, 1)
  
  # Sanity check
  assert(len(node.children) >= 2)
  assert(node.kind == commandNode)

  # Build command string
  let commandParts = toSeq(node.termsData)

  # Resolve executable location
  var
    executable = commandParts[0]
    arguments = commandParts[1..^1]

  if existsFile(executable):
    discard
  elif existsDir(executable):
    echo fmt"'{executable}' is a directory."
    vm.lastExitCode = "1"
    return
  # elif isBuiltin(executable):
  #   discard
  else:
    let resolved = findExe(executable)
    if resolved == "":
      echo fmt"Cannot find command/executable '{executable}'."
      vm.lastExitCode = "1"
      return
    else:
      executable = resolved

  # Start subprocess
  echo fmt"Executing '{executable}' with {arguments}"
  let subprocess = startProcess(
    command = executable,
    args = arguments,
    options = {poStdErrToStdOut, poParentStreams}
  )

  vm.lastExitCode = $waitForExit(subprocess)


proc execSeperatorNode(vm: CommandantVm, node: AstNode) =
  echo "In execSeperatorNode:"
  echo nodeRepr(node, 1)
  
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
