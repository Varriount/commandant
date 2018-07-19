## builtins.nim - Implements shell builtins.
## 
## Note that this file is *included* in vm.nim due to
## a circular dependancy between the virtual machine type
## and the builtin routines.
## 
import parser, lexer, tables, strutils, strformat, options, os
import parseutils, sequtils

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


# ## Builtin Definitions ## #
# iterator chainedString(
#       stringSeq : seq[string],
#       startIndex: i): tuple[index, position: int, value: char] =
#   var position = 0
#   for index in startIndex..high(stringSeq):
#     for character in stringSeq[index]:
#       yield index, position, character
#       inc position
# let
#   functionGrammer = peg"""
#     \skip \s*
#     function <- \ident "(" \ident* ")" "="
#   """
proc execDefine(
    vm        : CommandantVm,
    executable: string,
    arguments : seq[string],
    cmdFiles  : CommandFiles): int =
  ## Define a function.
  ## Syntax:
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

  var
    name = arguments[0]
    commands = newSeq[AstNode]()

  emitErrorIf(not validIdentifier(arguments[0])):
    fmt("Error: \"{name}\" is not a valid identifier.")

  while true:
    let commandAst = vm.nextCommand()
    emitErrorIf(isNone(commandAst)):
      "Error: Function not terminated with 'end' before EOF."

    var command = commandAst.get()
    # echo nodeRepr(command)

    let isEndOfFunction = (
      command.kind == commandNode and
      len(command.children) == 2  and
      command.children[1].term.data == "end"
    )
    if isEndOfFunction:
      break

    commands.add(command)

  vm.setFunc(name, commands)


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
type Builtin = proc (
    vm        : CommandantVm,
    executable: string,
    arguments : seq[string],
    cmdFiles  : CommandFiles
  ): int


const builtinMap = {
  "echo"    : execEcho,
  "set"     : execSet,
  "unset"   : execUnset,
  "export"  : execExport,
  "unexport": execUnexport,
  "state"   : execState,
  "def"     : execDefine,
}


proc getBuiltin(name: string): Option[Builtin] =
  for pair in builtinMap:
    let (builtin_name, builtin) = pair
    if name == builtin_name:
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

