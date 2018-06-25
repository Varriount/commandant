import lexer, parser
import strformat, strutils

const
  newLine = "\n"
  reprIndent = "    "


type Indent = string


proc `+`(i: Indent, n: int): Indent =
  result = i
  for x in 1..n:
    result &= reprIndent


proc addnodeRepr(term: Token, indent: Indent, result: var string) =
  let nextIndent = indent + 1

  var quotedData = ""
  addQuoted(quotedData, term.data)

  result.add(fmt(
    "{indent}term:\n"                         &
    "{nextIndent}kind:     {term.kind}\n"     &
    "{nextIndent}data:     {quotedData}\n"    &
    "{nextIndent}position: {term.position}\n"
  ))


proc addnodeRepr(n: AstNode, indent: Indent, result: var string) =
  let nextIndent = indent + 1

  result.add(fmt("{indent}{n.kind}:\n"))

  case n.kind
  of termNode:
    addnodeRepr(n.term, nextIndent, result)

  else:
    for child in n.children:
      addnodeRepr(child, nextIndent, result)


proc nodeRepr*(n: AstNode, indentLevel = 0): string =
  let startIndent = repeat(reprIndent, indentLevel)
  addnodeRepr(n, startIndent, result)
