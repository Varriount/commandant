import lexer, parser

type CommandStreams = tuple[
  stdout, stderr, stdin: File
]


template setHandle*(handleExpr: File, value: File) =
  let replace = (
    handleExpr != stdout and
    handleExpr != stderr and
    handleExpr != stdin
  )
  if replace:
    close(handleExpr)
    handleExpr = value


proc openFileToken*(fileToken: Token, mode: FileMode): File =
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


proc getCmdStreams*(command: AstNode): CommandStreams =
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