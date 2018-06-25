import tables, regex, osproc, os, strformat
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
proc execNode*(vm: CommandantVm, node: AstNode)


proc extractCommand(node: AstNode): seq[string] =
  result = @[]
  for child in node.children[1..^1]:
    result.add(child.term.data)


proc execCommandNode(vm: CommandantVm, node: AstNode) =
  echo "In execCommandNode:"
  echo nodeRepr(node, 1)
  
  if len(node.children) < 2:
    raise newException(ValueError, "Invalid command node.")

  let commandParts = extractCommand(node)


  let
    args = commandParts[1..^1]
    executable = 
      if existsFile(commandParts[0]) or existsDir(commandParts[0]):
        commandParts[0]
      else:
        findExe(commandParts[0])

  echo fmt"Executing '{executable}' with {args}"

  let subprocess = startProcess(
    command = executable,
    args = args,
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
