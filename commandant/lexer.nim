import std/strformat


# Character and character set constants
const
  carriageReturn = '\r'
  lineFeed       = '\l'
  endOfFile      = '\0'
  illegalChars   = {carriageReturn, lineFeed, endOfFile}
  spaceChars     = {' ', '\t'}


# Token Implementation
type
  TokenKind* = enum
    emptyToken
    errToken
    eofToken

    wordToken
    strToken

    # Keywords/Symbols
    andSepToken    # '&&'  SEPERATOR LOW, KEYWORD LOW
    orSepToken     # '||'
    semiSepToken   # ';'   SEPERATOR HIGH

    stdoutToken    # '>'   STREAMOPT LOW
    stdoutAppToken # '>>' 
    stderrToken    # '!>'
    stderrAppToken # '!>>'
    stdinToken     # '<'   STREAMOPT HIGH, KEYWORD HIGH

  Token* = object
    kind*     : TokenKind  ## The type of the token
    data*     : string     ## The contents of the token
    position* : int        ## Start position of the token


const
  kwMapLow   = ord(andSepToken)
  kwMapHigh  = ord(stdinToken)
  kwMapLength = kwMapHigh - kwMapLow + 1
  keywordMap: array[kwMapLength, string] = [
    "&&",  # andSepToken
    "||",  # orSepToken
    ";",   # semiSepToken
    ">",   # stdoutToken
    ">>",  # stdoutAppToken
    "!>",  # stdoutToken
    "!>>", # stdoutAppToken
    "<"    # stdinToken
  ]

  streamOptSet* = {stdoutToken..stdinToken}
  streamOptLow = ord(stdoutToken)
  streamOptHigh = ord(stdinToken)

  precMapLow   = ord(andSepToken)
  precMapHigh  = ord(semiSepToken)
  precMapLength = precMapHigh - precMapLow + 1
  precedenceMap: array[precMapLength, int] = [
    3, # andSepToken
    2, # orSepToken
    1, # semiSepToken
  ]


proc initToken*(result: var Token) =
  ## Reset/Reinitialize the contents of the passed in token.
  result.kind = emptyToken
  result.position = 0
  if isNil(result.data):
    result.data = ""
  else:
    setLen(result.data, 0)


proc fillWithError*(token: var Token, msg: string) =
  ## Fill in the given token with error data.
  token.kind = errToken
  token.data = msg


proc add*(token: var Token, c: char) =
  ## Add a character to the token's data.
  token.data.add(c)

proc add*(token: var Token, s: string) =
  ## Add a string to the token's data.
  token.data.add(s)


proc isLeftAssociative*(token: Token): bool =
  result = true


proc getPrecedence*(token: Token): int =
  if ord(token.kind) notin precMapLow..precMapHigh:
    result = -1
  else:
    result = precedenceMap[ord(token.kind) - precMapLow]


# Lexer implementation
type Lexer* = object
  buffer*  : string ## Current data being lexed
  position*: int    ## Position that data is being read from.


proc initLexer*(lexer: var Lexer, line = "") =
  ## Initializes the passed in lexer object.
  lexer.position = 0
  lexer.buffer = line
  lexer.buffer &= '\0' # Added as a signal to the lexing code to stop.


proc character(lexer: Lexer): char =
  result = lexer.buffer[lexer.position]


proc peek(lexer: Lexer): char =
  result = lexer.buffer[lexer.position + 1]


proc atEnd(lexer: Lexer): bool =
  result = (lexer.character != '\0')


proc read(lexer: var Lexer): char =
  inc lexer.position
  result = lexer.character


proc blindRead(lexer: var Lexer) =
  inc lexer.position


# Lexing Routines
proc lexString(lexer: var Lexer, result: var Token) =
  initToken(result)
  result.position = lexer.position
  result.kind = strToken

  blindRead(lexer) # Skip over initial quote

  while true:
    let character = lexer.character

    # Handle quotes
    if character == '"':
      blindRead(lexer)
      break

    # Handle end-of-input
    elif character == endOfFile:
      fillWithError(
        result,
        fmt"Ending quote expected to match beginning " &
        fmt"quote at position {result.position}."
      )
      break

    #  Handle escapes
    elif character == '\\':
      if peek(lexer) in {'\\', '"'}:
        add(result, peek(lexer))
        blindRead(lexer) # Lexer is at '\' or '"'
      else:
        fillWithError(
          result,
          fmt"Unexpected escape at position {lexer.position}."
        )
        break

    else:
      add(result, character)

    blindRead(lexer)


proc lexSkip(lexer: var Lexer, result: var Token) =
  while true:
    case lexer.character
    of spaceChars:
      inc lexer.position

    of carriageReturn, lineFeed:
      fillWithError(
        result,
        fmt"Illegal character '{repr(lexer.character)}' " &
        fmt"at position {lexer.position}"
      )
      break

    else:
      break


proc lexWord(lexer: var Lexer, result: var Token) =  
  result.position = lexer.position
  result.kind = wordToken

  while true:
    let character = lexer.character

    # Handle spaces/eof
    case character
    of spaceChars, endOfFile, lineFeed, carriageReturn:
      break
    else:
      add(result, character)

    blindRead(lexer)


proc specializeWord(result: var Token) =
  for index, value in keywordMap:
    if result.data == value:
      result.kind = TokenKind(kwMapLow + index)
      break


proc nextToken*(lexer: var Lexer, result: var Token) =
  initToken(result)

  if lexer.character == endOfFile:
    result.kind = eofToken
    return

  lexSkip(lexer, result)

  if result.kind == errToken:
    return

  if lexer.character == '"':
    lexString(lexer, result)
  else:
    lexWord(lexer, result)
    specializeWord(result)