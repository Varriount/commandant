import strformat
import npeg

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

  Lexer* = ref object
    tokens*   : seq[Token]
    position* : int


proc newLexer*(): Lexer =
  result = Lexer()


proc resetLexer*(lexer: Lexer) =
  setLen(lexer.tokens, 0)
  lexer.position = 0


proc hasNext*(lexer: Lexer): bool =
  result = lexer.position < len(lexer.tokens)


proc next*(lexer: Lexer) =
  inc lexer.position


proc token*(lexer: Lexer): Token =
  result = lexer.tokens[lexer.position]


proc skip*(lexer: Lexer, kind: TokenKind) =
  while true:
    let token = lexer.token()

    if token.kind != kind:
      break
    lexer.next()


proc expect*(lexer: Lexer, kind: TokenKind): Token =
  result = lexer.token()
  if result.kind != kind:
    raise newException(Exception, fmt"Expected {kind}, got {result.kind}.")


proc lex*(lexer: Lexer, input: string) =
  var lineNumber   = 1
  var linePosition = 0

  template addMarkerToken(tkind: TokenKind) =
    let position = capture[0].si

    lexer.tokens.add(Token(
      kind: tkind,
      loc : LineInfo(
        position: position,
        line    : lineNumber,
        column  : position - linePosition + 1
      )
    ))

  template addDataToken(tkind: TokenKind) =
    addMarkerToken(tkind)
    lexer.tokens[^1].data = capture[0].s

  let lexer = peg "COMMANDS":
    COMMANDS <- COMMAND * *( SEPERATOR_LIT * COMMAND ) * (EndOfInput | &COMMAND_SUB_END_SYM)

    EndOfInput <- >( EOF ):
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
      REDIRECT_EXPR |
      WORD_LIT
    )

    SEPERATOR_LIT <- >( SEPERATOR_SYM ) :
      addDataToken(TKSeperator)

    SPACES <- >( +AltSpace ) :
      addMarkerToken(TKSpaces)

    # Redirection
    REDIRECT_EXPR <- REDIRECT_LIT * SPACES * REDIRECT_TARGET
    
    REDIRECT_LIT <- >( REDIRECT_SYM ) :
      addDataToken(TKRedirect)

    REDIRECT_TARGET <- ( DQ_STRING_LIT | SQ_STRING_LIT | WORD_LIT ) | E_MISSING_TARGET

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
      SQ_STRING_START_SYM    |
      SEPERATOR_SYM
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

    DQ_STRING_DATA <- >( +(ANY - (
      COMMAND_SUB_START_SYM  |
      VARIABLE_SUB_START_SYM |
      DQ_STRING_ESCAPE_SYM   |
      DQ_STRING_END_SYM
    )) ):
      addDataToken(TKStringData)

    DQ_STRING_ESCAPE <- >( DQ_STRING_ESCAPE_SYM ) :
      addDataToken(TKStringEscape)

    DQ_STRING_ESCAPE_SYM <- '\\' * >(
      DQ_STRING_END_SYM      |
      COMMAND_SUB_START_SYM  |
      VARIABLE_SUB_START_SYM |
      CHAR_ESCAPE            |
      UTF8_ESCAPE
    ) :
      addDataToken(TKStringEscape)


    # Single Quoted Strings
    SQ_STRING_LIT <-
      SQ_STRING_START *
      SQ_STRING_MIDDLE  *
      SQ_STRING_END

    SQ_STRING_START <- >( SQ_STRING_START_SYM ) :
      addMarkerToken(TKStringStart)

    SQ_STRING_END <- >( SQ_STRING_END_SYM | E_MISSING_QUOTE ) :
      addMarkerToken(TKStringEnd)

    SQ_STRING_MIDDLE <- *(
      SQ_STRING_ESCAPE |
      SQ_STRING_DATA
    )

    SQ_STRING_DATA <- >+( ANY - (
      SQ_STRING_ESCAPE_SYM |
      SQ_STRING_END_SYM
    ) ) :
      addDataToken(TKStringData)

    SQ_STRING_ESCAPE <- >( SQ_STRING_ESCAPE_SYM ):
      addDataToken(TKStringEscape)

    SQ_STRING_ESCAPE_SYM <- '\\' * (
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

    COMMAND_SUB_DATA <- COMMANDS | E_INVALID_SUB


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
    E_INVALID_SUB    <- E"Invalid substitution."
    E_MISSING_CBRACE <- E"Missing curly brace."
    E_MISSING_PAREN  <- E"Missing parenthesis."
    E_MISSING_QUOTE  <- E"Missinq quotation mark."
    E_MISSING_TARGET <- E"Missing redirection target."

  let res = lexer.match(input)
  if res.matchLen != len(input):
    echo "Warning, unable to tokenize entire output."
    echo fmt"End of match occured around {res.matchLen} and {res.matchMax}"


proc getPrecedence*(t: Token): int =
  if t.data == "|":
    result = 1