import lexer, strformat

#[
# Node Expressions
expression  <- if_stmt | for_stmt | while_stmt
commands    <- command [ SEPERATOR_LIT command ]*
command     <- ( WORD_LIT | STRING_LIT | redirection )+
redirection <- REDIRECT_LIT ( word | string )
if_stmt     <- "if"    LPAREN_LIT commands RPARENT_LIT () END_LIT
while_stmt  <- "while" LPAREN_LIT commands RPARENT_LIT () END_LIT
for_stmt    <- "for" WORD_LIT "in" LPAREN_LIT commands RPARENT_LIT () END_LIT

# Token expressions
WORD_LIT      <- \[^\s\t]\
STRING_LIT    <- \"(\\.|[^"\\])*"\
SEPERATOR_LIT <- ( "||" | "&&" )
REDIRECT_LIT  <- ( ">" | ">>" | "!>" | "!>>" | "<" )
LPAREN_LIT    <- "("
RPAREN_LIT    <- ")"
END_LIT       <- "end"
]#

# ## AstNode Implementation ## #
type
  AstNodeKind* = enum
    emptyNode
    termNode
    expressionNode
    statementNode
    commandNode
    seperatorNode
    outputNode

  AstNode* = object
    case kind*: AstNodeKind
    of termNode:
      term*: Token
    else:
      children*: seq[AstNode]


template makeNode*(nodeKind: static[AstNodeKind], nodeValue): AstNode =
  when nodeKind == termNode:
    AstNode(kind: nodeKind, term: nodeValue)
  else:
    AstNode(kind: nodeKind, children: nodeValue)
    

template addNewNode*(parent: AstNode, kind: static[AstNodeKind], value) =
  parent.children.add(makeNode(kind, value))


template add*(parent: AstNode, child: AstNode) =
  parent.children.add(child)


iterator terms*(node: AstNode): Token =
  assert node.kind == commandNode
  for i in 1..high(node.children):
    yield node.children[i].term


iterator termsData*(node: AstNode): string =
  assert node.kind == commandNode
  for term in node.terms:
    yield term.data


proc makeTermNode(nodeValue: string|Token): AstNode =
  when nodeValue is string:
    makeNode(termNode, Token(kind: strToken, data: nodeValue, position: 0))
  else:
    makeNode(termNode, nodeValue)


proc skipTypes*(node: AstNode, kinds: set[AstNodeKind]): AstNode =
  result = node
  while result.kind in kinds:
    result = result.children[^1]


# ## Parser Implementation ## #
type
  Parser* = ref object
    lexer*: Lexer
    token*: Token
    errorFound*: bool


proc newParser*(): Parser =
  new(result)
  initLexer(result.lexer)
  initToken(result.token)


proc readToken(parser: var Parser) =
  nextToken(parser.lexer, parser.token)


# template matchTokenExpr(
#       parser: Parser,
#       matchExpr: string): Token =
#   let
#     token {.inject.} = parser.token 
#     data {.inject.} = parser.token.data
#     kind {.inject.} = parser.token.kind

#   if matchExpr:
#     result = parser.token
#   else:
#     initToken(result)


# proc matchToken(
#       parser        : Parser,
#       expectedKind  : TokenKind,
#       expectedData  : string): Option[Token] =
#   result = matchTokenExpr(
#     expectedKind == kind
#     expectedData == data
#   )


# proc matchToken(
#       parser: Parser,
#       data  : string,
#       kind  : TokenKind): Token =
#   result = matchTokenExpr(
#     expectedKind == kind
#     expectedData == data
#   )


# proc matchToken(
#       parser: Parser,
#       data  : string): Token =
#   result = matchTokenExpr(expectedData == data)


# proc matchToken(
#       parser: Parser,
#       kind  : TokenKind): Token =
#   result = matchTokenExpr(expectedKind == kind)


proc reportError(parser: var Parser, msg: string) =
  echo fmt"Error (Column {parser.lexer.position}): ", msg
  parser.errorFound = true


# ## Core Parsing routines ## #
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

  if len(result.children) < 2:
    parser.reportError("Command expected.")


proc parseMultiCommand(parser: var Parser, precedenceLimit: int): AstNode =
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
      rightExpression = parseMultiCommand(parser, precedence)
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


# proc parseDef(parser: var Parser): Optional[AstNode] =
#   let start = matchToken(parser, wordToken, "if")
#   if not valid:
#     return none(AstNode)

#   readToken(parser)
#   let target 
#   if not valid:
#     parser.reportError("Identifier expected.")
#     return none(AstNode)


#   let commands = parseMultiCommand(parser, 0)


# proc parseIf(parser: var Parser): Optional[AstNode] =
#   if not parser.expect(wordToken, "if"):
#     return none(AstNode)

#   let commands = parseMultiCommand(parser, 0)


# proc parseWhile(parser: var Parser): Optional[AstNode] =
#   if not parser.expect(wordToken, "while"):
#     return none(AstNode)

#   let commands = parseMultiCommand(parser, 0)


# proc parseFor(parser: var Parser): Optional[AstNode] =
#   if not parser.expect(wordToken, "for"):
#     return none(AstNode)

#   let commands = parseMultiCommand(parser, 0)


proc parse*(parser: var Parser, s: string): AstNode =
  result = AstNode(kind: emptyNode)

  initLexer(parser.lexer, s)
  readToken(parser)
  result = parseMultiCommand(parser, 0)