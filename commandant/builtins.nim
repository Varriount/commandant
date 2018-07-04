import parser, lexer, tables, strutils, strformat

#[
Planned Commands
  Set a variable:
    set <x> = <y> ... <z> 

  Unset a variable:
    unset <x> ... <z>

  Echo a variable:
    echo <x> ... <z>

  Export a variable:
    export x [ = <y> ... <z> ]

  Unexport a variable:
    unexport x

  Print VM state:
    state <category> ...

]#

type BuiltinIdent = enum
  biUnknown
  biEcho
  biSet
  biUnset
  biExport
  biUnexport
  biState


const builtinMap: array[BuiltinIdent, string] = [
    "",         # biUnknown
    "echo",     # biEcho
    "set",      # biSet
    "unset",    # biUnset
    "export",   # biExport
    "unexport", # biUnexport
    "state", # biUnexport
  ]


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


template emitErrorIf(condition, errorString) =
  if condition:
    cmdFiles.errput.write(errorString)
    return 1


proc execEcho(
    vm        : CommandantVm,
    arguments : seq[string],
    cmdFiles  : CommandFiles): int =

  for i in 0..high(arguments):
    cmdFiles.output.write(arguments[0])
    break

  for i in 1..high(arguments):
    cmdFiles.output.write(' ')
    cmdFiles.output.write(arguments[0])

  result = 0


proc execSet(
    vm        : CommandantVm,
    arguments : seq[string],
    cmdFiles  : CommandFiles): int =

  # Check that the number of words is correct
  let valid = (
    len(arguments) >= 3 and
    arguments[1] == "=" and
    validIdentifier(arguments[0])
  )
  emitErrorIf(not valid):
    "Error: Expected an expression of the form '<x> = <y> [... <z>]'."

  # Set the variable
  let 
    target = arguments[0]
    values = arguments[2..^1]

  vm.variables[target] = values


proc execUnset(
    vm        : CommandantVm,
    arguments : seq[string],
    cmdFiles  : CommandFiles): int =

  emitErrorIf(len(arguments) > 0):
    "Error: Expected an expression of the form '<x> [<y> ... <z>]'."

  for arg in arguments:
    # Check that it's a valid identifier
    emitErrorIf(not validIdentifier(arg)):
      fmt"Error: {arg} is not a valid variable name."

    # Check that the variable exists
    emitErrorIf(arg notin vm.variables):
      fmt"Error: {arg} is not a set variable."

  for arg in arguments:
    del(vm.variables, arg)


proc execExport(
    vm        : CommandantVm,
    arguments : seq[string],
    cmdFiles  : CommandFiles): int =
  discard


proc execUnexport(
    vm           : CommandantVm,
    arguments    : seq[string],
    cmdFiles     : CommandFiles): int =
  discard


proc execState(
    vm           : CommandantVm,
    arguments    : seq[string],
    cmdFiles     : CommandFiles): int =
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
proc findBuiltin(name: string): BuiltinIdent =
  for ident, identName in builtinMap:
    echo fmt"Input: {name}, Kind: {ident}, Against: {identName}"
    if name == identName:
      return ident
  return biUnknown


proc callBuiltin*(
    vm        : CommandantVm,
    builtin   : BuiltinIdent,
    arguments : seq[string],
    cmdFiles  : CommandFiles) =

  template execBuiltin(procname: untyped) =
    vm.lastExitCode = $procname(vm, arguments, cmdFiles)

  case builtin
  of biEcho    : execBuiltin(execEcho)
  of biSet     : execBuiltin(execSet)
  of biUnset   : execBuiltin(execUnset)
  of biExport  : execBuiltin(execExport)
  of biState   : execBuiltin(execState)
  of biUnexport: execBuiltin(execUnexport)
  of biUnknown:
    raise newException(ValueError, "Unknown builtin called.")

