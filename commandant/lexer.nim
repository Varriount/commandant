import std/strformat

# Handle CTRL-C
proc handleQuit() {.noconv.}=
  stdout.write("\n")
  quit(0)

setControlCHook(handleQuit)


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
    wordToken
    strToken
    errToken
    emptyToken

    # Keywords/Symbols
    andSepToken    # '&&'
    orSepToken     # '||'
    sepToken       # ';'

    stdoutToken    # '>'
    stdoutAppToken # '>>'
    stdinToken     # '<'

  Token* = object
    kind*     : TokenKind  ## The type of the token
    data*     : string     ## The contents of the token
    position* : int        ## Start position of the token


const
  kwMapLow   = ord(andSepToken)
  kwMapHigh  = ord(stdinToken)
  kwMapLength = kwMapHigh - kwMapLow + 1
  keywordMap: array[kwMapLength, string] = [
    "&&", # andSepToken
    "||", # orSepToken
    ";",  # sepToken
    ">",  # stdoutToken
    ">>", # stdoutAppToken
    "<"   # stdinToken
  ]


proc reset*(result: var Token) =
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


# Lexer implementation
type Lexer* = object
  buffer*  : string ## Current data being lexed
  position*: int    ## Position that data is being read from.


proc reset*(lexer: var Lexer, line = "") =
  ## Initializes the passed in lexer object.
  lexer.position = 0
  lexer.buffer = line
  lexer.buffer &= '\0' # Added as a signal to the lexing code to stop.


template currentChar(lexer: Lexer): untyped =
  lexer.buffer[lexer.position]


template nextChar(lexer: Lexer): untyped =
  lexer.buffer[lexer.position + 1]


template hasChar(lexer: Lexer): untyped =
  lexer.currentChar != '\0'


template incPosition(lexer: var Lexer) =
  inc lexer.position


# Lexing Routines
proc lexString(lexer: var Lexer, result: var Token) =  
  result.position = lexer.position
  result.kind = strToken

  incPosition(lexer) # Skip over the initial quote
  while true:
    let character = lexer.currentChar

    # Handle quotes
    if character == '"':
      lexer.incPosition
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
      if lexer.nextChar in {'\\', '"'}:
        add(result, lexer.nextChar)
        incPosition(lexer)
      else:
        fillWithError(
          result,
          fmt"Unexpected escape at position {lexer.position}."
        )
        break

    else:
      add(result, character)

    incPosition(lexer)


proc lexSkip(lexer: var Lexer, result: var Token) =
  while true:
    case lexer.currentChar
    of spaceChars:
      inc lexer.position

    of carriageReturn, lineFeed:
      fillWithError(
        result,
        fmt"Illegal character '{repr(lexer.currentChar)}' " &
        fmt"at position {lexer.position}"
      )
      break

    else:
      break


proc lexWord(lexer: var Lexer, result: var Token) =  
  result.position = lexer.position
  result.kind = wordToken

  while true:
    let character = lexer.currentChar

    # Handle spaces/eof
    case character
    of spaceChars, endOfFile:
      break
    else:
      add(result, character)

    incPosition(lexer)


proc specializeWord(result: var Token) =
  for index, value in keywordMap:
    if result.data == value:
      result.kind = TokenKind(kwMapLow + index)
      break


proc nextToken*(lexer: var Lexer, result: var Token) =
  reset(result)

  if lexer.currentChar == endOfFile:
    return

  lexSkip(lexer, result)

  if result.kind == errToken:
    return

  if lexer.currentChar == '"':
    lexString(lexer, result)
  else:
    lexWord(lexer, result)
    specializeWord(result)