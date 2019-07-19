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


proc nodeRepr*(n: AstNode, indentLevel: int = 0): string =
  let startIndent = repeat(reprIndent, indentLevel)
  addnodeRepr(n, startIndent, result)


proc stringifyAux(n: AstNode, result: var string) =
  case n.kind
  of termNode:
    if n.term.kind == strToken:
      result.add(fmt("\"{n.term.data}\""))
    else:
      result.add(n.term.data)
    result.add(' ')
  else:
    for child in n.children:
      stringifyAux(child, result)


proc `$`*(n: AstNode): string =
  result = ""
  stringifyAux(n, result)
  result.setLen(high(result))

