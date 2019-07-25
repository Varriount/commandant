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
  result = 0

  let valid = (
    len(arguments) == 3 and
    arguments[2] == "="
  )
  emitErrorIf(not valid):
    "Error: Expected an expression of the form 'def <function name> ='."

  var name = arguments[1]

  emitErrorIf(not validIdentifier(arguments[1])):
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
  result = 0

  let valid = (
    len(arguments) >= 4   and
    arguments[1] == "("   and
    arguments[^2] == ")"  and
    arguments[^1] == "then"
  )
  emitErrorIf(not valid):
    "Error: Expected an expression of the form 'if ( <command> ) then'."

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
  result = 0

  let valid = (
    len(arguments) >= 5   and
    arguments[1] == "("   and
    arguments[^2] == ")"  and
    arguments[^1] == "do"
  )
  emitErrorIf(not valid):
    "Error: Expected an expression of the form 'while ( <command> ) do'."

  let conditionCommand = arguments[2..^3]

  while true:
    var job = callCommand(vm, conditionCommand, pipes)
    wait(vm, job)
    if vm.lastExitCode != "0":
      break

    for command in commands:
      var job = execNode(vm, command, pipes)
      wait(vm, job)


proc execFor(
    vm        : VM,
    arguments : seq[string],
    commands  : seq[Node],
    pipes     : CommandPipes): int =
  ## Run a series of commands, once for each token output by a single command.
  ## Syntax:
  ##   0   1     2  3   4      ^3 ^2  ^1
  ##   for ident in "(" <command> ")" do =
  ##      ...
  ##   end
  result = 0

  let valid = (
    len(arguments) >= 7   and
    arguments[2] == "in"   and
    arguments[3] == "("   and
    arguments[^2] == ")"  and
    arguments[^1] == "do"
  )
  emitErrorIf(not valid):
    "Error: Expected an expression of the form 'for <regex> in ( <command> ) do'."

  let
    rawRegex = arguments[1]
    command = arguments[4..^3]

  var regex: Regex
  try:
    regex = toPattern(rawRegex)
  except RegexError:
    emitError:
      fmt"Regex Error: {getCurrentException().msg}"


# ### Utility Commands ### #
proc execEcho(
    vm        : VM,
    arguments : seq[string],
    pipes     : CommandPipes): int =
  ## Set a variable.
  ## Syntax:
  ##  0    1        ^1
  ##  echo <x> ... <z>
  result = 0

  for i in 1..high(arguments):
    writeOut(arguments[i])
    break

  for i in 2..high(arguments):
    writeOut(' ')
    writeOut(arguments[i])
  writeOut("\n")

  result = 0


# ### VM/Environment Variable Procedures ### #
proc execSet(
    vm        : VM,
    arguments : seq[string],
    pipes     : CommandPipes): int =
  ## Echo a variable.
  ## Syntax:
  ##   0   1   2 3        ^1
  ##   set <x> = <y> ... <z>
  result = 0

  let valid = (
    len(arguments) >= 3 and
    arguments[1] == "="
  )
  emitErrorIf(not valid):
    "Error: Expected an expression of the form '<x> = <y> [... <z>]'."

  let 
    target = arguments[0]
    values = arguments[2..^1]

  emitErrorIf(not validIdentifier(target)):
    fmt("Error: \"{target}\" is not a valid identifier.")

  vm.setVar(target, values)


proc execUnset(
    vm        : VM,
    arguments : seq[string],
    pipes     : CommandPipes): int =
  ## Unset a variable.
  ## Syntax:
  ##   unset <x> ... <z>
  result = 0

  emitErrorIf(len(arguments) > 0):
    "Error: Expected an expression of the form '<x> [<y> ... <z>]'."

  var errored = true
  for arg in arguments:
    if not validIdentifier(arg):
      writeErr("Error: {arg} is not a valid variable name.\n")
      errored = false

  if errored:
    return 1

  for arg in arguments:
    vm.delVar(arg)


proc execExport(
    vm        : VM,
    arguments : seq[string],
    pipes     : CommandPipes): int =
  ## Export and set a variable.
  ## Syntax:
  ##   export x [ = <y> ... <z> ]
  result = 0

  let 
    exportMultiple = (len(arguments) > 0)
    exportAndSet = (
      len(arguments) >= 3 and
      arguments[1] == "="
    )

  emitErrorIf(not (exportMultiple or exportAndSet)):
    "Error: Expected an expression of the form '<x> [ = <y> ... <z>]'."

  if exportAndSet:
    let
      target = arguments[0]
      values = arguments[2..^1]
    
    emitErrorIf(not validIdentifier(target)):
      fmt("Error: \"{target}\" is not a valid identifier.")

    vm.setVar(target, values)
    putEnv(target, join(values, " "))
  
  else: # exportMultiple
    var invalidTargets = newSeq[string]()
    # Identifier checks
    for target in arguments:
      if not validIdentifier(target):
        invalidTargets.add(target)

    emitErrorIf(len(invalidTargets) > 0):
      fmt("Error: {invalidTargets} are not valid indentifier(s).")

    # Value checks
    for target in arguments:
      if not vm.hasVar(target):
        invalidTargets.add(target)

    emitErrorIf(len(invalidTargets) > 0):
      fmt("Error: {invalidTargets} are not set variables.")

    # Export
    for target in arguments:
      let values = vm.getVar(target).get()
      os.putEnv(target, join(values, " "))


proc execUnexport(
    vm        : VM,
    arguments : seq[string],
    pipes     : CommandPipes): int =
  ## Unexport a variable.
  ## Syntax:
  ##   unexport x
  result = 0

  discard


proc execState(
    vm        : VM,
    arguments : seq[string],
    pipes     : CommandPipes): int =
  ## Print VM state.
  ## Syntax:
  ##   state <category> ...
  result = 0

  const
    listStart = "["
    listEnd   = "]"
    listSep   = ", "
  
  # Variables
  # writeOutLn("Variables:")
  # for key, values in vm.variables:
  #   writeOut(fmt("    \"{key}\": "))
  #   writeOut(listStart)

  #   for i in 0..high(values):
  #     writeQuoted(writeOut, values[i])
  #     break

  #   for i in 1..high(values):
  #     writeOut(listSep)
  #     writeQuoted(writeOut, values[i])
      
  #   writeOutLn(listEnd)
  
  # # Functions
  # writeOutLn("Functions:")
  # for key, values in vm.functions:
  #   writeOutLn(fmt("    \"{key}\": "))
  #   for value in values:
  #     writeOutLn(fmt"      {value}")


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
  "for"  : execFor,
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
  "unexport": execUnexport,
  "state"   : execState,
}


proc getBuiltin(name: string): Option[Builtin] =
  for pair in builtinMap:
    let (builtinName, builtin) = pair
    if name == builtinName:
      return some(Builtin(builtin))
