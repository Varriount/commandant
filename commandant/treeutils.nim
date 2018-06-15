import lexer, parser, strformat

const
  newLine = "\n"
  reprIndent = "    "


type Indent = string


proc `+`(i: Indent, n: int): Indent =
  result = i
  for x in 1..n:
    result &= reprIndent


proc addStringRepr(term: Token, indent: Indent, result: var string) =
  let nextIndent = indent + 1

  var quotedData = ""
  addQuoted(quotedData, term.data)

  result.add(fmt(
    "{indent}term:\n"                         &
    "{nextIndent}kind:     {term.kind}\n"     &
    "{nextIndent}data:     {quotedData}\n"    &
    "{nextIndent}position: {term.position}\n"
  ))


proc addStringRepr(n: AstNode, indent: Indent, result: var string) =
  let nextIndent = indent + 1

  result.add(fmt("{indent}{n.kind}:\n"))

  case n.kind
  of termNode:
    addStringRepr(n.term, nextIndent, result)

  else:
    for child in n.children:
      addStringRepr(child, nextIndent, result)


proc stringRepr*(n: AstNode): string =
  result = ""
  addStringRepr(n, Indent(""), result)