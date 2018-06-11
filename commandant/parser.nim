import lexer

type
  AstNodeKind* = enum
    commandNode
    statementNode
    seperatorNode
    redirectionNode

  AstNode* = object
    case kind: AstNodeKind
    of commandNode:
      words: seq[Token]
    else:
      children: seq[AstNode]
    

proc addWord(node: var AstNode, word: Token) =
  node.words.add(word)


proc addChild(node: var AstNode, child: AstNode) =
  node.children.add(child)


proc addChild(node: var AstNode, word: Token) =
  node.addChild(
    AstNode(
      kind: commandNode,
      words: @[word]
    )
  )


type
  Parser* = object
    lexer: Lexer
    token: Token


proc initParser*(result: var Parser) =
  result = Parser(
    lexer: Lexer(),
    token: Token()
  )
  reset(result.lexer)
  reset(result.token)


proc nextTokenOpt(parser: var Parser) =
  parser.lexer.nextToken(parser.token)


proc nextToken(parser: var Parser) =
  nextTokenOpt(parser)
  if parser.token.kind == emptyToken:
    raise newException(ValueError, "Expected one or more tokens.")


proc handleErrToken(parser: var Parser) =
  raise newException(ValueError, parser.token.data)


# Parsing routines
proc parseCommand(parser: var Parser): AstNode
proc parseRedirection(parser: var Parser, currentCommand: AstNode): AstNode
proc parseSeperator(parser: var Parser, currentCommand: AstNode): AstNode


proc parseSeperator(parser: var Parser, currentCommand: AstNode): AstNode =
  result = AstNode(
    kind: seperatorNode,
    children: @[]
  )
  result.addChild(parser.token)
  result.addChild(currentCommand)

  # Ensure that there is at least one token on the other side of the operator.
  parser.nextToken()
  result.addChild(parseCommand(parser))


proc parseCommand(parser: var Parser, result: var AstNode) =
  while true:
    case parser.token.kind
    of wordToken, strToken:
      result.addWord(parser.token)
    of andSepToken, orSepToken, sepToken:
      result = parseSeperator(parser, result)
      break
    of stdoutToken, stdoutAppToken, stdinToken:
      result = parseRedirection(parser, result)
      nextTokenOpt(parser)
      parseCommand(parser, result.children[^1])
      break
    of emptyToken:
      break
    of errToken:
      handleErrToken(parser)

    nextTokenOpt(parser)


proc parseCommand(parser: var Parser): AstNode =
  result = AstNode(
    kind: commandNode,
    words: @[]
  )
  parseCommand(parser, result)
  

proc parseRedirection(parser: var Parser, currentCommand: AstNode): AstNode =
  result = AstNode(
    kind: seperatorNode,
    children: @[]
  )
  result.addChild(parser.token)
  nextToken(parser)
  result.children[0].addWord(parser.token)
  result.addChild(currentCommand)


proc parse*(parser: var Parser, s: string): AstNode =
  reset(parser.lexer, s)
  nextTokenOpt(parser)
  result = parseCommand(parser)