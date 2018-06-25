import lexer, strformat


# AstNode Implementation
type
  AstNodeKind* = enum
    termNode
    expressionNode
    commandNode
    seperatorNode
    outputNode

  AstNode* = object
    case kind*: AstNodeKind
    of termNode:
      term*: Token
    else:
      children*: seq[AstNode]


template makeNode(nodeKind: static[AstNodeKind], nodeValue): AstNode =
  when nodeKind == termNode:
    AstNode(kind: nodeKind, term: nodeValue)
  else:
    AstNode(kind: nodeKind, children: nodeValue)
    

template addNewNode(parent: AstNode, kind: static[AstNodeKind], value) =
  parent.children.add(makeNode(kind, value))


template add(parent: AstNode, child: AstNode) =
  parent.children.add(child)


# Node Creation Procs
proc makeTermNode(nodeValue: string|Token): AstNode =
  when nodeValue is string:
    makeNode(termNode, Token(kind: strToken, data: nodeValue, position: 0))
  else:
    makeNode(termNode, nodeValue)
# Parser Implementation
type
  Parser* = ref object
    lexer: Lexer
    token: Token


proc initParser*(result: var Parser) =
  result = Parser(
    lexer: Lexer(),
    token: Token()
  )
  initLexer(result.lexer)
  initToken(result.token)


proc readToken(parser: var Parser) =
  nextToken(parser.lexer, parser.token)


# proc hasToken(parser: var Parser): bool =
#   result = (parser.token.kind != eofToken)


# proc handleErrToken(parser: var Parser) =
#   raise newException(ValueError, parser.token.data)


# Parsing routines
# proc parseRedirection(parser: var Parser, currentCommand: AstNode): AstNode =
#   result = AstNode(
#     kind: redirectionNode,
#     children: @[]
#   )
#   result.addChild(parser.token)
#   nextToken(parser)
#   result.children[0].addTerm(parser.token)
#   result.addChild(currentCommand)


proc parseCommand(parser: var Parser): AstNode =
  result = makeNode(
    commandNode,
    @[
      makeNode(outputNode, @[])
    ]
  )
  while true:
    case parser.token.kind
    of wordToken, strToken:
      result.addNewNode(termNode, parser.token)

    of streamOptSet:
      var streamOptNode = makeNode(commandNode, @[])
      streamOptNode.addNewNode(termNode, parser.token)

      readToken(parser)
      streamOptNode.addNewNode(termNode, parser.token)
      result.children[0].add(streamOptNode)

    else:
      break

    readToken(parser)


proc parseExpression(parser: var Parser, precedenceLimit: int): AstNode =
  result = parseCommand(parser)

  var
    opToken = parser.token
    precedence = getPrecedence(opToken)

  while opToken.kind != eofToken and precedence >= precedenceLimit:
    echo precedence, " : ", precedenceLimit
    if isLeftAssociative(opToken):
      inc precedence

    readToken(parser)

    let
      rightExpression = parseExpression(parser, precedence)
      leftExpression = result

    result = makeNode(
      seperatorNode,
      @[
        makeNode(termNode, opToken),
        leftExpression,
        rightExpression
      ]
    )

    opToken = parser.token
    precedence = getPrecedence(opToken)

      

proc parse*(parser: var Parser, s: string): AstNode =
  initLexer(parser.lexer, s)
  readToken(parser)
  result = parseExpression(parser, 0)