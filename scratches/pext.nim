import extpegs, strformat

let grammer = peg"""
  \skip(\s+)

  multicommand  <- command (SEPERATOR command)*
  command       <- (WORD_LIT / STRING_LIT)+ redirection?
  redirection   <- REDIRECTOR (WORD_LIT / STRING_LIT)

  WORD_LIT      <- \S+
  STRING_LIT    <- DQ_STRING_LIT / SQ_STRING_LIT
  DQ_STRING_LIT <- DQUOTE (BSLASH . / [^"])* DQUOTE
  SQ_STRING_LIT <- SQUOTE (BSLASH . / [^'])* SQUOTE

  SEPERATOR     <- ( "||" \ "&&" )
  REDIRECTOR    <- ( ">" \ ">>" \ "!>" \ "!>>" \ "<" )

  DQUOTE        <- "\""
  SQUOTE        <- "'"

  BSLASH        <- "\\"
  # LPAREN        <- "("
  # RPAREN        <- ")"
  # END           <- "end"
"""

type
  TokenKind* = enum
    tkWord
    tkString

  Token* = object
    data*   : string ## The contents of the token
    kind*   : TokenKind
    line*   : int
    column* : int

  AstNodeKind* = enum
    emptyNode
    nkTerm
    nkCommand
    nkRedirection
    nkMulticommand

  AstNodeObj* = object
    case kind*: AstNodeKind
    of nkTerm:
      token*: Token
    else:
      children*: seq[AstNode]

  AstNode = ref AstNodeObj


proc main =
  var
    rootNode = AstNode(
      kind: nkMulticommand,
      children: @[]
    )
    currentNode = rootNode

  let nodePath = newSeq[AstNode]()


  # Push/Pop Helpers
  template pushNode(n: AstNode) =
    nodePath.add(n)
    add(currentNode.children, n)

  template popNode() =
    setLen(nodePath, high(nodePath))
    currentNode = nodePath[high(nodePath)]


  # Token Helpers
  template addToken(nodeKind) =
    mixin length
    add(
      currentNode.children,
      AstNode(
        kind: nodeKind,
        token: Token(
          data: s[start..start+length-1],
          kind: tkind,
          line: p.nt.line,
          column: p.nt.col
        )
      )
    )


  let parser = grammer.eventParser:
    pkNonTerminal:
      leave:
        case p.nt.name
          of "WORD_LIT":
            addToken(makeToken(tkWord))
          of "STRING_LIT":
            addToken(makeToken(
              tkString))
          of "SEPERATOR":
            addToken(makeToken(tkWord))
          of "REDIRECTOR":
            addToken(makeToken(tkWord))

  discard parser("Hello world")


main()