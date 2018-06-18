import parser, lexer, vm, tables

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

]#

type CommandStreams = tuple[
  stdout, stderr, stdin: File
]


template setHandle(handleExpr: File, value: File) =
  let replace = (
    handleExpr != stdout and
    handleExpr != stderr and
    handleExpr != stdin
  )
  if replace:
    close(handleExpr)
    handleExpr = value


proc openFileToken(fileToken: Token, mode: FileMode): File =
  case fileToken.kind
  of strToken:
    result = open(fileToken.data, mode)
  of wordToken:
    case fileToken.data:
    of "stdout": result = stdout
    of "stderr": result = stderr
    of "stdin":  result = stdin
    else:
      result = open(fileToken.data, mode)
  else:
    raise newException(ValueError, "openFile: Invalid file token.")


proc getCmdStreams(command: AstNode): CommandStreams =
  let outputNode = command.children[0]

  for child in outputNode.children:
    let
      operatorKind = child.children[0].term.kind
      fileToken = child.children[1].term

    var
      fileMode: FileMode
      streamIndex: int

    case operatorKind
    of stdoutToken:
      setHandle(result[0], openFileToken(fileToken, fmWrite))

    of stdoutAppToken:
      setHandle(result[0], openFileToken(fileToken, fmAppend))

    of stderrToken:
      setHandle(result[1], openFileToken(fileToken, fmWrite))

    of stderrAppToken:
      setHandle(result[1], openFileToken(fileToken, fmAppend))

    of stdinToken:
      setHandle(result[2], openFileToken(fileToken, fmRead))
    else:
      raise newException(ValueError, "Unexpected output token.")


proc execEcho(vm: CommandantVm, command: AstNode): int =
  let (output, _, _) = getCmdStreams(command)
  var buffer = ""

  for i in 1..high(command.children):
    buffer.add(command.children[i].term.data)
    buffer.add(" ")

  buffer.setLen(len(buffer) - 1)
  buffer.add("\n")
  output.write(buffer)


proc execSet(vm: CommandantVm, command: AstNode): int =
  let (output, errput, _) = getCmdStreams(command)

  # Check that the number of words is correct
  let valid = (
    len(command.children) < 4                  and
    command.children[2].kind == termNode       and
    command.children[2].term.kind == wordToken and
    command.children[2].term.data == "="
  )
  if not valid:
    errput.write("Error: Expected an expression of the form '<x> = <y> [... <z>]'.")
    return 1

  # Set the variable
  let
    target = command.children[1]
    sign = command.children[2]

  vm.variables[target.term.data] = command.children[3..^0]


proc execUnset(vm: CommandantVm, command: AstNode): int =
  let (output, errput, _) = getCmdStreams(command)

  if len(command.children) < 3:
    errput.write("Error: Expected an expression of the form '<x> [<y> ... <z>]'.")
    return 1

  # Check that all stated variables are in the table
  for i in 2..high(command.children):
    let key = command.children[i].term.data
    if key notin vm.variables:
      errput.write("Error: {} is not a set variable.")
      return 1

  for i in 2..high(command.children):
    let key = command.children[i].term.data
    del(vm.variables, key)


proc execExport(vm: CommandantVm, command: AstNode): int =
  let (output, errput, _) = getCmdStreams(command)
  discard


proc execUnexport(vm: CommandantVm, command: AstNode): int =
  let (output, errput, _) = getCmdStreams(command)
  discard