## builtins.nim - Implements shell builtins.
## 
## Note that this file is *included* in vm.nim due to
## a circular dependancy between the virtual machine type
## and the builtin routines.
## 
{.experimental: "codeReordering".}
import parseutils, sequtils, pegs, tables, strutils, strformat, os
import ".." / [parser, lexer]

import regex except Option
# ## Builtin Implementations ## #
template writeQuoted(outSym, s) =
  outSym("\"")
  outSym(s)
  outSym("\"")


template writeOut(outputString) =
  pipes.output.writeEnd.write(outputString)


template writeOutLn(outputString) =
  pipes.output.writeEnd.write(outputString)
  pipes.output.writeEnd.write("\n")


template writeErr(errorString) =
  pipes.errput.writeEnd.write(errorString)


template writeErrLn(errorString) =
  pipes.errput.writeEnd.write(errorString)
  pipes.errput.writeEnd.write("\n")


template emitError(errorString) =
  pipes.errput.writeEnd.write(errorString)
  echo "\n"
  return 1


template emitErrorIf(condition, errorString) =
  if condition:
    emitError(errorString)


template addFmt(s: var string, value: static[string]) =
  s.add(fmt(value))


template checkVarIdentifiers(vars) =
  var invalidVars: seq[string]

  # Identifier checks
  for variable in vars:
    if not validIdentifier(variable):
      invalidTargets.add(variable)

  emitErrorIf(len(invalidTargets) > 0):
    fmt("Error: " & invalidTargets & " are not valid variable indentifier(s).")


template checkExistingVars(vars) =
  var invalidVars: seq[string]

  # Identifier checks
  for variable in vars:
    if not validIdentifier(variable):
      invalidVars.add(variable)

  emitErrorIf(len(invalidVars) > 0):
    "Error: " & invalidVars.join(" ") & " are not valid variable indentifier(s)."

  # Value checks
  for variable in vars:
    if not hasVar(vm, variable):
      invalidVars.add(variable)

  emitErrorIf(len(invalidVars) > 0):
    "Error: " & invalidVars.join(" ") & " are not set variables."


template checkExpression(expressionString, valid) =
  emitErrorIf(not valid):
    fmt"Error: Expected an expression of the form " & expressionString & "."


# ### Flow-Control Commands ### #
proc execDefine(
    vm        : VM,
    arguments : seq[string],
    commands  : seq[Node],
    pipes     : CommandPipes): int =
  ## Define a function.
  ## Syntax:
  ##   0   1               2
  ##   def <function name> =
  ##      ...
  ##   end

  checkExpression(
    "def <function name> =",
    len(arguments) == 3 and
    arguments[2] == "=",
  )

  let name = arguments[1]

  emitErrorIf(not validIdentifier(name)):
    fmt("Error: \"{name}\" is not a valid identifier.")

  vm.setFunc(name, commands)


proc execIf(
    vm        : VM,
    arguments : seq[string],
    commands  : seq[Node],
    pipes     : CommandPipes): int =
  ## Run a series of commands, based on whether a single command returns
  ## success.
  ## Syntax:
  ##   0  1   2      ^3 ^2  ^1
  ##   if "(" <command> ")" then
  ##      ...
  ##   end

  checkExpression(
    "if ( <command> ) then",
    len(arguments) >= 4   and
    arguments[1] == "("   and
    arguments[^2] == ")"  and
    arguments[^1] == "then"
  )

  let conditionCommand = arguments[2..^3]
  var job = callCommand(vm, conditionCommand, pipes)

  wait(vm, job)
  if vm.lastExitCode == "0":
    for command in commands:
      job = execNode(vm, command, pipes)
      wait(vm, job)


proc execWhile(
    vm        : VM,
    arguments : seq[string],
    commands  : seq[Node],
    pipes     : CommandPipes): int =
  ## Run a series of commands, while a single command returns 0
  ## Syntax:
  ##   0     1   2      ^3 ^2  ^1
  ##   while "(" <command> ")" do
  ##      ...
  ##   end

  checkExpression(
    "while ( <command> ) do",
    len(arguments) >= 5   and
    arguments[1] == "("   and
    arguments[^2] == ")"  and
    arguments[^1] == "do"
  )

  let conditionCommand = arguments[2..^3]

  while true:
    var job = callCommand(vm, conditionCommand, pipes)
    wait(vm, job)
    if vm.lastExitCode != "0":
      break

    for command in commands:
      var job = execNode(vm, command, pipes)
      wait(vm, job)


# ### Utility Commands ### #
proc execEcho(
    vm        : VM,
    arguments : seq[string],
    pipes     : CommandPipes): int =
  ## Set a variable.
  ## Syntax:
  ##  0    1        ^1
  ##  echo <x> ... <z>

  for i in 1..high(arguments):
    writeOut(arguments[i])
    break

  for i in 2..high(arguments):
    writeOut(' ')
    writeOut(arguments[i])
  writeOut("\n")



# ### VM/Environment Variable Procedures ### #
proc execSet(
    vm        : VM,
    arguments : seq[string],
    pipes     : CommandPipes): int =
  ## Echo a variable.
  ## Syntax:
  ##   0   1   2 3        ^1
  ##   set <x> = <y> ... <z>

  checkExpression(
    "<x> = <y> [... <z>]",
    len(arguments) >= 3 and
    arguments[2] == "="
  )

  let 
    target = arguments[1]
    values = arguments[3..^1]

  emitErrorIf(not validIdentifier(target)):
    fmt("Error: \"{target}\" is not a valid identifier.")

  vm.setVar(target, values)


proc execUnset(
    vm        : VM,
    arguments : seq[string],
    pipes     : CommandPipes): int =
  ## Unset a variable.
  ## Syntax:
  ##   0     1       ^1
  ##   unset <x> ... <z>

  checkExpression(
    "<x> [<y> ... <z>]",
    len(arguments) >= 2
  )

  checkExistingVars(arguments[1..^1])

  for arg in arguments[1..^1]:
    vm.delVar(arg)


proc execExport(
    vm        : VM,
    arguments : seq[string],
    pipes     : CommandPipes): int =
  ## Export and set a variable.
  ## Syntax:
  ##   0      1   2 3       ^1
  ##   export x [ = <y> ... <z> ]

  let 
    exportMultiple = (len(arguments) > 1)
    exportAndSet = (
      len(arguments) >= 3 and
      arguments[1] == "="
    )

  checkExpression(
    "<x> [ = <y> ... <z>]",
    (exportMultiple or exportAndSet)
  )

  if exportAndSet:
    let
      target = arguments[1]
      values = arguments[3..^1]
    
    emitErrorIf(not validIdentifier(target)):
      fmt("Error: \"{target}\" is not a valid identifier.")

    vm.setVar(target, values)
    putEnv(target, join(values, " "))
  
  else: # exportMultiple
    checkExistingVars(arguments[1..^1])

    # Export
    for target in arguments[1..^1]:
      let values = vm.getVar(target).get()
      os.putEnv(target, join(values, " "))


proc execUnexport(
    vm        : VM,
    arguments : seq[string],
    pipes     : CommandPipes): int =
  ## Unexport a variable.
  ## Syntax:
  ##   0        1  ^1
  ##   unexport x [<y>...]

  discard


proc execDelete(
    vm        : VM,
    arguments : seq[string],
    pipes     : CommandPipes): int =
  ## Delete an element or subrange of elements from a variable.
  ## 
  ## If the given index or range doesn't exist, the variable will remain 
  ## unchanged. If only part of a given range exists, that part will be 
  ## removed.
  ## 
  ## Syntax:
  ##   0      1   ^2   ^1 
  ##   delete <x> from <z>
  checkExpression(
    "delete <x> from <z>",
    len(arguments) >= 4 and
    arguments[^2] == "from"
  )
  checkExistingVars(arguments[^1..^1])

  var deletionPoint = 0
  try:
    deletionPoint = parseInt(arguments[1])
  except:
    emitError("Invalid index " & arguments[1])
  
  var variable = get(vm.getVar(arguments[^1]))
  if deletionPoint >= 0 and deletionPoint <= high(arguments):
    variable.delete(deletionPoint)
    vm.setVar(arguments[^1], variable)


proc execInsert(
    vm        : VM,
    arguments : seq[string],
    pipes     : CommandPipes): int =
  ## Insert an element into a variable.
  ## Syntax:
  ##   0      1    ^5      ^4   ^3  ^2 ^1 
  ##   insert <w> [<x>...] into <y> at <z>
  # Command structure check
  checkExpression(
    "insert <w> [<x>...] into <y> at <z>",
    len(arguments) >= 6 and
    arguments[^4] == "into" and
    arguments[^2] == "at"
  )

  # Identifier checks
  checkExistingVars(arguments[^3..^3])

  # Logic
  let name = arguments[^3]
  var insertionPoint = 0
  try:
    insertionPoint = parseInt(arguments[^1])
  except:
    emitError("Invalid index " & arguments[^1])

  var variable = get(vm.getVar(name))

  insert(variable, arguments[1..^5], insertionPoint)
  vm.setVar(name, variable)


proc execAdd(
    vm        : VM,
    arguments : seq[string],
    pipes     : CommandPipes): int =
  ## Add an element to a variable.
  ## Syntax:
  ##   0   1    ^3      ^2 ^1 
  ##   add <x> [<y>...] to <z>
  # Command structure check
  checkExpression(
    "add <x> [<y>...] to <z>",
    len(arguments) >= 4 and
    arguments[^2] == "to"
  )

  # Identifier checks
  checkExistingVars(arguments[^1..^1])

  # Logic
  let name = arguments[^1]
  var variable = get(vm.getVar(name))
  
  for value in arguments[1..^3]:
    variable.add(value)

  vm.setVar(name, variable)


# ## Public Interface ## #
type
  Statement = proc (
    vm        : VM,
    arguments : seq[string],
    commands  : seq[Node],
    pipes     : CommandPipes
  ): int

  Builtin = proc (
    vm        : VM,
    arguments : seq[string],
    pipes     : CommandPipes
  ): int


const statementMap = {
  "if"   : execIf,
  "while": execWhile,
  "def"  : execDefine,
}


proc isEndCommand(node: Node): bool =
  result = (
    node.kind == NKCommand  and
    len(node.children) == 1 and
    node.children[0].token.data == "end"
  )


proc getStatement(name: string): Option[Statement] =
  for pair in statementMap:
    let (statementName, statement) = pair
    if name == statementName:
      return some(Statement(statement))


proc isStatement(node: Node): bool =
  result = (
    # Do we have a simple command?
    node.kind == NKCommand and
    len(node.children) > 0 and

    # Is the first argument of the command a statement?
    node.children[0].kind == NKWord and
    isSome(getStatement(node.children[0].token.data))
  )


const builtinMap = {
  "echo"    : execEcho,
  "set"     : execSet,
  "unset"   : execUnset,
  "export"  : execExport,
  "add"     : execAdd,
  "delete"  : execDelete,
  "insert"  : execInsert,
}


proc getBuiltin(name: string): Option[Builtin] =
  for pair in builtinMap:
    let (builtinName, builtin) = pair
    if name == builtinName:
      return some(Builtin(builtin))
