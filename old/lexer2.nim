import parser2
import strutils
import strformat

type
  NodeKind = enum
    NKInvalid
    NKCommand
    NKWord
    NKString
    NKStringData
    NKCommandSub
    NKVariableSub

  Node = object
    kind    : NodeKind
    token   : Token
    unlinked: bool
    children: seq[Node]


proc add(parent: var Node, child: Node) =
  parent.children.add(child)

#[
proc lexExample(parser: ref Parser): Node =
  result = Node(kind: RootKind)

  while parser.hasNext():
    let token = parser.next()

    case token.kind
    of TKSpaces:
      discard
    of TKWord:
      discard
    of TKStringStart:
      discard
    of TKStringEnd:
      discard
    of TKStringData:
      discard
    of TKStringEscape:
      discard
    of TKCommandSubStart:
      discard
    of TKCommandSubEnd:
      discard
    of TKVariableSubStart:
      discard
    of TKVariableSubEnd:
      discard
    of TKInvalid:
      discard
    else:
      raise Exception()
]#
proc lexCommand*(parser: ref Parser): Node {.gcsafe.}
proc lexString(parser: ref Parser): Node {.gcsafe.}
proc lexVariableSub(parser: ref Parser): Node {.gcsafe.}
proc lexCommandSub(parser: ref Parser): Node {.gcsafe.}


proc lexCommand*(parser: ref Parser): Node =
  result = Node(kind: NKCommand)

  while true:
    let token = parser.next()

    case token.kind
    of TKEof, TKSeperator:
      break

    of TKSpaces:
      if len(result.children) > 0:
        result.children[^1].unlinked = true

    of TKWord:
      result.add(Node(
        kind : NKWord,
        token: token
      ))

    of TKStringStart:
      result.add(lexString(parser))
    of TKCommandSubStart:
      result.add(lexCommandSub(parser))
    of TKVariableSubStart:
      result.add(lexVariableSub(parser))

    of TKRedirect:
      result.add(lexRedirect(parser))

    else:
      raise newException(Exception, "88")


proc lexString(parser: ref Parser): Node =
  result = Node(
    kind: NKString,
    token: parser.tokens[parser.position - 1]
  )

  while true:
    let token = parser.next()

    case token.kind
    of TKStringEnd:
      break

    of TKStringData:
      result.add(Node(
        kind : NKStringData,
        token: token
      ))
    of TKStringEscape:
      result.add(Node(
        kind : NKStringData,
        token: token
      ))
      result.children[^1].token.data = unescape(token.data, "", "")

    of TKCommandSubStart:
      result.add(lexCommandSub(parser))
    of TKVariableSubStart:
      result.add(lexVariableSub(parser))

    else:
      raise newException(Exception, "118")


proc lexVariableSub(parser: ref Parser): Node =
  result = Node(kind: NKVariableSub)

  parser.skip(TKSpaces)
  result.token = parser.expect(TKWord)
  parser.skip(TKSpaces)
  discard parser.expect(TKVariableSubEnd)


proc lexCommandSub(parser: ref Parser): Node =
  result = Node(kind: NKCommandSub)

  while true:
    let token = parser.next()

    case token.kind
    of TKCommandSubEnd:
      break

    of TKSpaces:
      result.children[^1].unlinked = true

    of TKWord:
      result.add(Node(
        kind : NKWord,
        token: token
      ))

    of TKStringStart:
      result.add(lexString(parser))
    of TKCommandSubStart:
      result.add(lexCommandSub(parser))
    of TKVariableSubStart:
      result.add(lexVariableSub(parser))

    else:
      raise newException(Exception, "88")


proc reprTree*(node: Node, indent = 0) =
  let space = repeat(' ', indent)
  echo fmt"{space}{node.kind}:"
  echo fmt"{space}    unlinked: {node.unlinked}"
  if  node.token.kind != TKInvalid:
    echo fmt"{space}    token:"
    echo fmt"{space}        kind: {node.token.kind}"
    echo fmt"{space}        data: {node.token.data}"
    echo fmt"{space}        location: ({node.token.loc.line}, {node.token.loc.column})"
  if len(node.children) > 0:
    echo fmt"{space}    children: "
    for child in node.children:
      reprTree(child, indent + 8)