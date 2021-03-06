import strutils, strformat
import lexer

type
  NodeKind* = enum
    NKInvalid
    NKSeperator
    NKRedirect
    NKCommand
    NKWord
    NKString
    NKStringData
    NKCommandSub
    NKVariableSub
    NKStatement
    NKBody
    NKEof

  Node* = object
    token*: Token
    unlinked*: bool
    
    case kind*: NodeKind
    of NKWord, NKStringData:
      discard
    else:
      children*: seq[Node]


proc add(parent: var Node, child: Node) =
  parent.children.add(child)


# ## Parsing Procedures ## #
proc parseCommands*(lexer: Lexer, precedenceLimit: int = 0): Node
proc parseCommand(lexer: Lexer): Node
proc parseString(lexer: Lexer): Node
proc parseVariableSub(lexer: Lexer): Node
proc parseCommandSub(lexer: Lexer): Node
proc parseRedirect(lexer: Lexer): Node
proc parseWord(lexer: Lexer): Node


proc unexpectedToken(t: Token) =
  raise newException(
    Exception,
    fmt"""Unexpected token of kind {t.kind}: "{t.data}" at """ &
    fmt"""line {t.loc.line}, column {t.loc.column}"""
  )


proc parse*(lexer: Lexer, data: string): Node =
  resetLexer(lexer)
  lexer.lex(data)
  result = parseCommands(lexer)


proc parseCommands*(lexer: Lexer, precedenceLimit: int = 0): Node =
  result = parseCommand(lexer)

  var
    sepToken = lexer.token
    precedence = getPrecedence(sepToken)

  while sepToken.kind notin {TKEof, TKCommandSubEnd} and
        precedence >= precedenceLimit:

    inc precedence
    lexer.next()

    let
      rightCommand = parseCommands(lexer, precedence)
      leftCommand  = result

    result = Node(
      kind: NKSeperator,
      token: sepToken,
      children: @[
        leftCommand,
        rightCommand
      ]
    )

    sepToken = lexer.token
    precedence = getPrecedence(sepToken)


proc parseCommand(lexer: Lexer): Node =
  result = Node(kind: NKCommand)

  while true:
    let token = lexer.token

    case token.kind
    of TKEof, TKSeperator, TKCommandSubEnd:
      break

    of TKSpaces:
      if len(result.children) > 0:
        result.children[^1].unlinked = true

    of TKWord:
      result.add(parseWord(lexer))

    of TKStringStart:
      result.add(parseString(lexer))
    of TKCommandSubStart:
      result.add(parseCommandSub(lexer))
    of TKVariableSubStart:
      result.add(parseVariableSub(lexer))

    of TKRedirect:
      result.add(parseRedirect(lexer))

    else:
      unexpectedToken(token)

    lexer.next()


proc parseString(lexer: Lexer): Node =
  result = Node(
    kind: NKString,
    token: lexer.token,
    children: @[]
  )

  lexer.next() # Skip over string start

  while true:
    let token = lexer.token

    case token.kind
    of TKStringEnd:
      break

    of TKStringData, TKStringEscape:
      result.add(Node(
        kind: NKStringData,
        token: lexer.token
      ))

    of TKCommandSubStart:
      result.add(parseCommandSub(lexer))
    of TKVariableSubStart:
      result.add(parseVariableSub(lexer))

    else:
      unexpectedToken(token)

    lexer.next()


proc parseWord(lexer: Lexer): Node =
  result = Node(
    kind: NKWord,
    token: lexer.expect(TKWord)
  )


proc parseVariableSub(lexer: Lexer): Node =
  result = Node(
    kind: NKVariableSub,
    token: lexer.token
  )

  lexer.next()
  lexer.skip(TKSpaces)

  result.add(parseWord(lexer))

  lexer.next()
  lexer.skip(TKSpaces)

  discard lexer.expect(TKVariableSubEnd)


proc parseCommandSub(lexer: Lexer): Node =
  result = Node(
    kind: NKCommandSub,
    token: lexer.token
  )

  lexer.next()
  lexer.skip(TKSpaces)

  result.add(parseCommands(lexer))


proc parseRedirect(lexer: Lexer): Node =
  result = Node(
    kind: NKRedirect,
    token: lexer.token
  )

  lexer.next()
  lexer.skip(TKSpaces)

  let token = lexer.token
  case token.kind
  of TKWord:
    result.add(parseWord(lexer))
  of TKStringStart:
    result.add(parseString(lexer))
  else:
    unexpectedToken(token)


proc nodeRepr*(node: Node, indent = 0) =
  let space = repeat(' ', indent)
  echo fmt"{space}{node.kind}:"
  echo fmt"{space}    unlinked: {node.unlinked}"
  if  node.token.kind != TKInvalid:
    echo fmt"{space}    token:"
    echo fmt"{space}        kind: {node.token.kind}"
    echo fmt"{space}        data: {node.token.data}"
    echo fmt"{space}        location: ({node.token.loc.line}, {node.token.loc.column})"
  if node.kind notin {NKWord, NKStringData} and len(node.children) > 0:
    echo fmt"{space}    children: "
    for child in node.children:
      nodeRepr(child, indent + 8)