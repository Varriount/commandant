## builtins.nim - Implements shell builtins.
## 
## Note that this file is *included* in vm.nim due to
## a circular dependancy between the virtual machine type
## and the builtin routines.
## 
import parser, lexer, tables, strutils, strformat, options


# ## Builtin Implementations ## #
template writeQuoted(outSym, s) =
  outSym("\"")
  outSym(s)
  outSym("\"")


template writeOut(outputString) =
  cmdFiles.output.write(outputString)


template writeOutLn(outputString) =
  cmdFiles.output.write(outputString)
  cmdFiles.output.write("\n")


template writeErr(errorString) =
  cmdFiles.errput.write(errorString)


template writeErrLn(errorString) =
  cmdFiles.errput.write(errorString)
  cmdFiles.errput.write("\n")


template emitErrorIf(condition, errorString) =
  if condition:
    cmdFiles.errput.write(errorString)
    return 1


template addFmt(s: var string, value: static[string]) =
  s.add(fmt(value))


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

  vm.variables[target] = values


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
    del(vm.variables, arg)


proc execExport(
    vm        : CommandantVm,
    executable: string,
    arguments : seq[string],
    cmdFiles  : CommandFiles): int =
  ## Export a variable.
  ## Syntax:
  ##   export x [ = <y> ... <z> ]
  result = 0
  discard


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
  
  writeOutLn("Variables:")
  for key, values in vm.variables:
    writeOut(fmt("    \"{key}\": "))
    writeOut(listStart)

    for i in 0..high(values):
      writeQuoted(writeOut, values[i])
      break

    for i in 1..high(values):
      writeOut(listSep)
      writeQuoted(writeOut, values[i])
      
    writeOutLn(listEnd)


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

