import npeg
import strformat

type
  TokenKind* = enum
    TKInvalid
    TKSeperator
    TKRedirect
    TKCommand
    TKSpaces
    TKWord
    TKStringStart
    TKStringEnd
    TKStringData
    TKStringEscape
    TKCommandSubStart
    TKCommandSubEnd
    TKVariableSubStart
    TKVariableSubEnd
    TKEof

  LineInfo* = object
    position* : int
    line*     : int
    column*   : int

  Token* = object
    kind* : TokenKind
    data* : string
    loc*  : LineInfo

  Parser* = ref object
    tokens*   : seq[Token]
    position* : int


proc initParser*(): Parser =
  result = Parser()


proc resetParser*(parser: Parser) =
  setLen(parser.tokens, 0)
  parser.position = 0


proc hasNext*(parser: Parser): bool =
  result = parser.position < len(parser.tokens)


proc next*(parser: Parser): Token {.discardable.} =
  result = parser.current()
  inc parser.position


proc current*(parser: Parser): Token =
  result = parser.tokens[parser.position]


proc skip*(parser: Parser, kind: TokenKind) =
  while parser.hasNext():
    let token = parser.tokens[parser.position]

    if token.kind != kind:
      echo repr(token)
      break
    inc parser.position


proc expect*(parser: Parser, kind: TokenKind): Token =
  result = parser.current()
  if result.kind != kind:
    raise newException(Exception, fmt"Expected {kind}, got {result.kind}.")


proc parse*(parser: Parser, input: string) =
  var lineNumber   = 1
  var linePosition = 0

  template addMarkerToken(tkind: TokenKind) =
    let position = capture[0].si

    parser.tokens.add(Token(
      kind: tkind,
      loc : LineInfo(
        position: position,
        line    : lineNumber,
        column  : position - linePosition + 1
      )
    ))

  template addDataToken(tkind: TokenKind) =
    addMarkerToken(tkind)
    parser.tokens[^1].data = capture[0].s

  let parser = peg "COMMANDS":
    COMMANDS <- COMMAND * *( SEPERATOR_LIT * COMMAND ) * >( EOF ):
      addMarkerToken(TKEof)

    COMMAND <- +(
      SPACES        |
      # Substitutions
      COMMAND_SUB   |
      VARIABLE_SUB  |
      # Literals
      DQ_STRING_LIT |
      SQ_STRING_LIT |
      # Other
      REDIRECT_LIT  |
      WORD_LIT
    )

    SEPERATOR_LIT <- >SEPERATOR_SYM :
      addDataToken(TKSeperator)

    SPACES <- >( +AltSpace ) :
      addMarkerToken(TKSpaces)

    REDIRECT_LIT <- >REDIRECT_SYM :
      addDataToken(TKRedirect)

    # Words
    WORD_LIT <- >( +WORD_CHAR ) :
      addDataToken(TKWord)

    WORD_CHAR <- ANY - (
      SPACES_SYM             |
      # Substitutions
      COMMAND_SUB_START_SYM  |
      COMMAND_SUB_END_SYM    |
      VARIABLE_SUB_START_SYM |
      VARIABLE_SUB_END_SYM   |
      # Literals
      DQ_STRING_START_SYM    |
      SQ_STRING_START_SYM
    )


    # Double Quoted Strings
    DQ_STRING_LIT <-
      DQ_STRING_START  *
      DQ_STRING_MIDDLE *
      DQ_STRING_END

    DQ_STRING_START <- >( DQ_STRING_START_SYM ) :
      addMarkerToken(TKStringStart)

    DQ_STRING_END <- >( DQ_STRING_END_SYM | E_MISSING_QUOTE ) :
      addMarkerToken(TKStringEnd)

    DQ_STRING_MIDDLE <- *(
      COMMAND_SUB      |
      VARIABLE_SUB     |
      DQ_STRING_ESCAPE |
      DQ_STRING_DATA
    )

    DQ_STRING_DATA <- >(+(ANY - (
      COMMAND_SUB_START_SYM  |
      VARIABLE_SUB_START_SYM |
      DQ_STRING_ESCAPE_SYM   |
      DQ_STRING_END_SYM
    ))):
      addDataToken(TKStringData)

    DQ_STRING_ESCAPE <- DQ_STRING_ESCAPE_SYM:
      addDataToken(TKStringEscape)

    DQ_STRING_ESCAPE_SYM <- '\\' * >(
      DQ_STRING_END_SYM      |
      COMMAND_SUB_START_SYM  |
      VARIABLE_SUB_START_SYM |
      CHAR_ESCAPE            |
      UTF8_ESCAPE
    ):
      addDataToken(TKStringEscape)


    # Single Quoted Strings
    SQ_STRING_LIT <-
      SQ_STRING_START *
      SQ_STRING_MIDDLE  *
      SQ_STRING_END

    SQ_STRING_START <- SQ_STRING_START_SYM :
      addMarkerToken(TKStringStart)

    SQ_STRING_END <- SQ_STRING_END_SYM | E_MISSING_QUOTE :
      addMarkerToken(TKStringEnd)

    SQ_STRING_MIDDLE <- *(
      SQ_STRING_ESCAPE |
      SQ_STRING_DATA
    )

    SQ_STRING_DATA <- >+(ANY - (
      SQ_STRING_ESCAPE_SYM |
      SQ_STRING_END_SYM
    )):
      addDataToken(TKStringData)

    SQ_STRING_ESCAPE <- SQ_STRING_ESCAPE_SYM:
      addDataToken(TKStringEscape)

    SQ_STRING_ESCAPE_SYM <- '\\' * >(
      SQ_STRING_END_SYM |
      CHAR_ESCAPE       |
      UTF8_ESCAPE
    )


    # Command Substitutions
    COMMAND_SUB <-
      COMMAND_SUB_START * ?SPACES *
      COMMAND_SUB_DATA  * ?SPACES *
      COMMAND_SUB_END

    COMMAND_SUB_START <- >( COMMAND_SUB_START_SYM ) :
      addMarkerToken(TKCommandSubStart)

    COMMAND_SUB_END <- >( COMMAND_SUB_END_SYM ) | E_MISSING_CBRACE :
      addMarkerToken(TKCommandSubEnd)

    COMMAND_SUB_DATA <- COMMAND | E_INVALID_SUB


    # Variable Substitutions
    VARIABLE_SUB <-
      VARIABLE_SUB_START * ?SPACES *
      VARIABLE_SUB_DATA  * ?SPACES *
      VARIABLE_SUB_END

    VARIABLE_SUB_START <- >( VARIABLE_SUB_START_SYM ) :
      addMarkerToken(TKVariableSubStart)

    VARIABLE_SUB_END <- >( VARIABLE_SUB_END_SYM | E_MISSING_PAREN ) :
      addMarkerToken(TKVariableSubEnd)

    VARIABLE_SUB_DATA <- WORD_LIT | E_INVALID_SUB


    # Escapes
    CHAR_ESCAPE <- { '\\', 'b', 'f', 'n', 'r', 't' }
    UTF8_ESCAPE <- ('u' * Xdigit[4])
    SUB_MARKER_ESCAPE <- SUB_MARKER_SYM

    SPACES_SYM <- +AltSpace

    # Symbols
    SUB_MARKER_SYM <- (
      COMMAND_SUB_START_SYM  |
      COMMAND_SUB_END_SYM    |
      VARIABLE_SUB_START_SYM |
      VARIABLE_SUB_END_SYM
    )

    DQ_STRING_START_SYM <- '"'
    DQ_STRING_END_SYM   <- '"'
    SQ_STRING_START_SYM <- '\''
    SQ_STRING_END_SYM   <- '\''

    COMMAND_SUB_START_SYM  <- "(("
    COMMAND_SUB_END_SYM    <- "))"
    VARIABLE_SUB_START_SYM <- "[["
    VARIABLE_SUB_END_SYM   <- "]]"

    SEPERATOR_SYM <- ( "&&" | "||" | ";" | "|" )
    REDIRECT_SYM  <- ( "&>" | "&>>" | "!>" | "!>>" | ">>" | ">" | "<" )

    EOF <- !1
    ANY <- NL | 1
    AltSpace <- NL | Space
    NL  <- >( '\c' * ?'\l' ):
      lineNumber += 1
      linePosition = capture[0].si

    # Errors
    E_MISSING_QUOTE  <- E"Missinq quotation mark."
    E_MISSING_CBRACE <- E"Missing curly brace."
    E_MISSING_PAREN  <- E"Missing parenthesis."
    E_INVALID_SUB    <- E"Invalid substitution."

  let res = parser.match(input)
  if res.matchLen != len(input):
    echo "Warning, unable to tokenize entire output."
    echo fmt"End of match occured around {res.matchLen} and {res.matchMax}"


proc getPrecedence*(t: Token): int =
  if token.data == '|':
    result = 1