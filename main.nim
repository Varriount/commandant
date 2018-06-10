import std/strformat

# Handle ctrl c
var exit = false

proc handleQuit() {.noconv.}=
  stdout.write("\n")
  quit(0)

setControlCHook(handleQuit)


# Lexing routines
const
  carriageReturn = '\r'
  lineFeed       = '\l'
  endOfFile      = '\0'
  illegalChars   = {carriageReturn, lineFeed, endOfFile}
  spaceChars     = {' ', '\t'}

type
  TokenKind = enum
    wordToken
    strToken
    eofToken
    errToken
    emptyToken

  Token = object
    kind     : TokenKind # The type of the token
    data     : string    # The contents of the token
    position : int

  Lexer = object
    buffer  : string
    position: int
    tokens  : seq[Token]


template currentChar(lexer: Lexer): untyped =
  lexer.buffer[lexer.position]

template nextChar(lexer: Lexer): untyped =
  lexer.buffer[lexer.position + 1]

template hasChar(lexer: Lexer): untyped =
  lexer.currentChar != '\0'

template incPosition(lexer: var Lexer) =
  inc lexer.position


proc lexString(lexer: var Lexer, result: var Token) =
  var
    target    = lexer.currentChar
    sawEscape = false
    data      = ""
  
  result.position = lexer.position
  result.kind = strToken

  incPosition(lexer)
  while true:
    if lexer.currentChar == '\"':
      incPosition(lexer)
      break
    elif lexer.currentChar in illegalChars:
      result.kind = errToken
      result.data = "Closing \" expected."
      break
    elif lexer.currentChar == '\\':
      if lexer.nextChar in {'"', '\\'}:
        add(data, lexer.nextChar)
        incPosition(lexer)
    else:
      add(data, lexer.currentChar)
    incPosition(lexer)

  result.data = data


proc lexSkip(lexer: var Lexer, result: var Token) =
  while true:
    case lexer.currentChar
    of spaceChars:
      inc lexer.position
    of carriageReturn, lineFeed:
      result.kind = errToken
      result.data = fmt"Illegal character '{repr(lexer.currentChar)}'"
      break
    else:
      break


proc lexWord(lexer: var Lexer, result: var Token) =
  var data = ""

  while true:
    case lexer.currentChar
    of spaceChars, endOfFile:
      break
    else:
      data.add(lexer.currentChar)
    incPosition(lexer)

  result.kind = wordToken
  result.data = data


proc parse(lexer: var Lexer): seq[Token] =
  result = @[]

  while lexer.currentChar != endOfFile:
    var token = Token(
      data: "",
      kind: emptyToken,
      position: lexer.position
    )

    lexSkip(lexer, token)

    if token.kind == errToken:
      result.add(token)
      break
    elif lexer.currentChar == '"':
      lexString(lexer, token)
    else:
      lexWord(lexer, token)
    
    result.add(token)



proc main() =
  var lexer = Lexer(
    buffer: "",
    position: 0,
    tokens: @[]
  )

  while not exit:
    stdout.write("> ")
    
    lexer.position = 0
    lexer.buffer = readLine(stdin)
    lexer.buffer &= '\0'

    let tokens = lexer.parse()
    echo fmt("Your input was {tokens}")

main()