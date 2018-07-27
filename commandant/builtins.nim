## builtins.nim - Implements shell builtins.
## 
## Note that this file is *included* in vm.nim due to
## a circular dependancy between the virtual machine type
## and the builtin routines.
## 
import parser, lexer, tables, strutils, strformat, os
import parseutils, sequtils, pegs

import regex except Option
# ## Builtin Implementations ## #
template writeQuoted(outSym, s) =
  outSym("\"")
  outSym(s)
  outSym("\"")


template writeOut(outputString) =
  stdout.write(outputString)


template writeOutLn(outputString) =
  stdout.write(outputString)
  stdout.write("\n")


template writeErr(errorString) =
  stderr.write(errorString)


template writeErrLn(errorString) =
  stderr.write(errorString)
  stderr.write("\n")


template emitError(errorString) =
  stderr.write(errorString)
  echo "\n"
  return 1


template emitErrorIf(condition, errorString) =
  if condition:
    emitError(errorString)


template addFmt(s: var string, value: static[string]) =
  s.add(fmt(value))


# ### Flow-Control Commands ### #
proc execDefine(
    vm        : CommandantVm,
    executable: string,
    arguments : seq[string],
    commands  : seq[AstNode],
    cmdFiles  : CommandFiles): int =
  ## Define a function.
  ## Syntax:
  ##       0               ^1
  ##   def <function name> =
  ##      ...
  ##   end
  result = 0

  let valid = (
    len(arguments) == 2 and
    arguments[1] == "="
  )
  emitErrorIf(not valid):
    "Error: Expected an expression of the form 'def <function name> ='."

  var name = arguments[0]

  emitErrorIf(not validIdentifier(arguments[0])):
    fmt("Error: \"{name}\" is not a valid identifier.")

  vm.setFunc(name, commands)


proc execIf(
    vm        : CommandantVm,
    executable: string,
    arguments : seq[string],
    commands  : seq[AstNode],
    cmdFiles  : CommandFiles): int =
  # echo "here"
  ## Run a series of commands, based on whether a single command returns
  ## success.
  ## Syntax:
  ##      0   1      ^3 ^2  ^1
  ##   if "(" <command> ")" then
  ##      ...
  ##   end
  let valid = (
    len(arguments) >= 3   and
    arguments[0] == "("   and
    arguments[^2] == ")"  and
    arguments[^1] == "then"
  )
  emitErrorIf(not valid):
    "Error: Expected an expression of the form 'if ( <command> ) then'."

  let conditionCommand = arguments[1..^3]

  tryCallCommand(vm, conditionCommand, cmdFiles)
  if vm.lastExitCode == "0":
    for command in commands:
      execLine(vm, command)


proc execWhile(
    vm        : CommandantVm,
    executable: string,
    arguments : seq[string],
    commands  : seq[AstNode],
    cmdFiles  : CommandFiles): int =
  ## Run a series of commands, while a single command returns 0
  ## Syntax:
  ##         0   1      ^3 ^2  ^2
  ##   while "(" <command> ")" do
  ##      ...
  ##   end
  let valid = (
    len(arguments) >= 4   and
    arguments[0] == "("   and
    arguments[^2] == ")"  and
    arguments[^1] == "do"
  )
  emitErrorIf(not valid):
    "Error: Expected an expression of the form 'while ( <command> ) do'."

  let conditionCommand = arguments[1..^3]

  while true:
    tryCallCommand(vm, conditionCommand, cmdFiles)
    if vm.lastExitCode != "0":
      break

    for command in commands:
      execLine(vm, command)


proc execFor(
    vm        : CommandantVm,
    executable: string,
    arguments : seq[string],
    commands  : seq[AstNode],
    cmdFiles  : CommandFiles): int =
  ## Run a series of commands, once for each token output by a single command.
  ## Syntax:
  ##       0       1  2   3      ^3 ^2  ^1
  ##   for ident in "(" <command> ")" do =
  ##      ...
  ##   end
  let valid = (
    len(arguments) >= 6   and
    arguments[1] == "in"   and
    arguments[2] == "("   and
    arguments[^2] == ")"  and
    arguments[^1] == "do"
  )
  emitErrorIf(not valid):
    "Error: Expected an expression of the form 'for <regex> in ( <command> ) do'."

  let
    rawRegex = arguments[0]
    command = arguments[3..^3]

  var regex: Regex
  try:
    regex = toPattern(rawRegex)
  except RegexError:
    emitError:
      fmt"Regex Error: {getCurrentException().msg}"


# ### Utility Commands ### #
proc execEcho(
    vm        : CommandantVm,
    executable: string,
    arguments : seq[string],
    cmdFiles  : CommandFiles): int =
  ## Echo a variable.
  ## Syntax:
  ##   set <x> = <y> ... <z>
  result = 0

  for i in 0..high(arguments):
    writeOut(arguments[i])
    break

  for i in 1..high(arguments):
    writeOut(' ')
    writeOut(arguments[i])
  writeOut("\n")

  result = 0


# ### VM/Environment Variable Procedures ### #
proc execSet(
    vm        : CommandantVm,
    executable: string,
    arguments : seq[string],
    cmdFiles  : CommandFiles): int =
  ## Set a variable.
  ## Syntax:
  ##  echo <x> ... <z>
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
    vm        : CommandantVm, 
    executable: string,
    arguments : seq[string],
    cmdFiles  : CommandFiles): int =
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
    vm        : CommandantVm,
    executable: string,
    arguments : seq[string],
    cmdFiles  : CommandFiles): int =
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
    vm        : CommandantVm,
    executable: string,
    arguments : seq[string],
    cmdFiles  : CommandFiles): int =
  ## Unexport a variable.
  ## Syntax:
  ##   unexport x
  result = 0

  discard


proc execState(
    vm        : CommandantVm,
    executable: string,
    arguments : seq[string],
    cmdFiles  : CommandFiles): int =
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
    vm        : CommandantVm,
    executable: string,
    arguments : seq[string],
    commands  : seq[AstNode],
    cmdFiles  : CommandFiles
  ): int

  Builtin = proc (
    vm        : CommandantVm,
    executable: string,
    arguments : seq[string],
    cmdFiles  : CommandFiles
  ): int


const statementMap = {
  "if"   : execIf,
  "while": execWhile,
  "for"  : execFor,
  "def"  : execDefine,
}


proc getStatement(name: string): Option[Statement] =
  for pair in statementMap:
    let (statementName, statement) = pair
    if name == statementName:
      return some(Statement(statement))


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


# proc callBuiltin*(
#     vm        : CommandantVm,
#     builtin   : BuiltinIdent,
#     arguments : seq[string],
#     cmdFiles  : CommandFiles) =

#   template execBuiltin(procname: untyped) =
#     vm.lastExitCode = $procname(vm, arguments, cmdFiles)

#   case builtin
#   of biEcho    : execBuiltin(execEcho)
#   of biSet     : execBuiltin(execSet)
#   of biUnset   : execBuiltin(execUnset)
#   of biExport  : execBuiltin(execExport)
#   of biState   : execBuiltin(execState)
#   of biUnexport: execBuiltin(execUnsetexport)
#   of biUnknown:
#     raise newException(ValueError, "Unknown builtin called.")

