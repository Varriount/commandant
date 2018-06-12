import commandant/parser
import commandant/lexer
import strformat
import strutils


const
  newLine = "\n"
  reprIndent = "    "


type Indent = string

proc `+`(i: Indent, n: int): Indent =
  result = i
  for x in 1..n:
    result &= reprIndent

proc `-`(i: Indent, n: int): Indent =
  for x in 1..n:
    if len(result) >= 2:
      result.setLen(len(result) - len(reprIndent))


proc addStringRepr(t: Token, indent: Indent, result: var string) =
  let nextIndent = indent + 1

  var quotedData = ""
  addQuoted(quotedData, t.data)

  result.add(fmt(
    "{indent}Token(\n"                   &
    "{nextIndent}kind:     {t.kind}\n"     &
    "{nextIndent}data:     {quotedData}\n" &
    "{nextIndent}position: {t.position}\n" &
    "{indent})"
  ))


proc addStringRepr(n: AstNode, indent: Indent, result: var string) =
  const
    itemsStart = ": ["
    itemsSep   = ",\n"
    itemsEnd   = "]\n"

  let nextIndent = indent + 1

  result.add(fmt("{indent}AstNode(\n"))
  result.add(fmt("{nextIndent}kind: {n.kind}\n"))

  template processItems(fieldName, itemExpr: untyped): untyped =
    result &= nextIndent & fieldName & itemsStart
    #TODO Note bug about having to use static

    if len(itemExpr) > 0:
      result &= newLine
      addStringRepr(itemExpr[0], nextIndent+1, result)

      for i in 1..high(itemExpr):
        result.add(itemsSep)
        addStringRepr(itemExpr[i], nextIndent+1, result)
      
      result &= newLine & nextIndent
    result &= itemsEnd
  
  case n.kind
  of commandNode:
    processItems("word", n.words)

  of statementNode, seperatorNode, redirectionNode:
    processItems("children", n.children)

  result &= indent & ")"


proc stringRepr(n: AstNode): string =
  result = ""

  addStringRepr(n, Indent(""), result)


proc main() =
  var parser: Parser
  initParser(parser)

  while true:
    # Print the prompt, then reset the lexer with the next line typed in.
    stdout.write("> ")
    
    # Emulate bash handling of multi-line commands
    # Read the last token of the input line for an escape
    var nodes = parse(parser, readLine(stdin))
    echo stringRepr(nodes)

main()