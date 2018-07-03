const
  useUnicode = true ## change this to deactivate proper UTF-8 support

import strutils, macros
export macros

when useUnicode:
  import unicode
  export unicode

const
  InlineThreshold = 5  ## number of leaves; -1 to disable inlining
  MaxSubpatterns* = 20 ## defines the maximum number of subpatterns that
                       ## can be captured. More subpatterns cannot be captured!

type
  PegKind* = enum
    pkEmpty,
    pkAny,              ## any character (.)
    pkAnyRune,          ## any Unicode character (_)
    pkNewLine,          ## CR-LF, LF, CR
    pkLetter,           ## Unicode letter
    pkLower,            ## Unicode lower case letter
    pkUpper,            ## Unicode upper case letter
    pkTitle,            ## Unicode title character
    pkWhitespace,       ## Unicode whitespace character
    pkTerminal,
    pkTerminalIgnoreCase,
    pkTerminalIgnoreStyle,
    pkChar,             ## single character to match
    pkCharChoice,
    pkNonTerminal,
    pkSequence,         ## a b c ... --> Internal DSL: peg(a, b, c)
    pkOrderedChoice,    ## a / b / ... --> Internal DSL: a / b or /[a, b, c]
    pkGreedyRep,        ## a*     --> Internal DSL: *a
                        ## a+     --> (a a*)
    pkGreedyRepChar,    ## x* where x is a single character (superop)
    pkGreedyRepSet,     ## [set]* (superop)
    pkGreedyAny,        ## .* or _* (superop)
    pkOption,           ## a?     --> Internal DSL: ?a
    pkAndPredicate,     ## &a     --> Internal DSL: &a
    pkNotPredicate,     ## !a     --> Internal DSL: !a
    pkCapture,          ## {a}    --> Internal DSL: capture(a)
    pkBackRef,          ## $i     --> Internal DSL: backref(i)
    pkBackRefIgnoreCase,
    pkBackRefIgnoreStyle,
    pkSearch,           ## @a     --> Internal DSL: !*a
    pkCapturedSearch,   ## {@} a  --> Internal DSL: !*\a
    pkRule,             ## a <- b
    pkList,             ## a, b
    pkStartAnchor       ## ^      --> Internal DSL: startAnchor()
  NonTerminalFlag* = enum
    ntDeclared, ntUsed
  NonTerminalObj = object         ## represents a non terminal symbol
    name: string                  ## the name of the symbol
    line: int                     ## line the symbol has been declared/used in
    col: int                      ## column the symbol has been declared/used in
    flags: set[NonTerminalFlag]   ## the nonterminal's flags
    rule: Peg                   ## the rule that the symbol refers to
  Peg* {.shallow.} = object ## type that represents a PEG
    case kind: PegKind
    of pkEmpty..pkWhitespace: nil
    of pkTerminal, pkTerminalIgnoreCase, pkTerminalIgnoreStyle: term: string
    of pkChar, pkGreedyRepChar: ch: char
    of pkCharChoice, pkGreedyRepSet: charChoice: ref set[char]
    of pkNonTerminal: nt: NonTerminal
    of pkBackRef..pkBackRefIgnoreStyle: index: range[0..MaxSubpatterns]
    else: sons: seq[Peg]
  NonTerminal* = ref NonTerminalObj

proc name*(nt: NonTerminal): string = nt.name
proc line*(nt: NonTerminal): int = nt.line
proc col*(nt: NonTerminal): int = nt.col
proc flags*(nt: NonTerminal): set[NonTerminalFlag] = nt.flags
proc rule*(nt: NonTerminal): Peg = nt.rule

proc kind*(p: Peg): PegKind = p.kind
proc term*(p: Peg): string = p.term
proc ch*(p: Peg): char = p.ch
proc charChoice*(p: Peg): ref set[char] = p.charChoice
proc nt*(p: Peg): NonTerminal = p.nt
proc index*(p: Peg): range[0..MaxSubpatterns] = p.index
iterator items*(p: Peg): Peg {.inline.} =
  for s in p.sons:
    yield s
iterator pairs*(p: Peg): (int, Peg) {.inline.} =
  for i in 0 ..< p.sons.len:
    yield (i, p.sons[i])

proc term*(t: string): Peg {.nosideEffect.} =
  ## constructs a PEG from a terminal string
  if t.len != 1:
    result.kind = pkTerminal
    result.term = t
  else:
    result.kind = pkChar
    result.ch = t[0]

proc termIgnoreCase*(t: string): Peg {.nosideEffect.} =
  ## constructs a PEG from a terminal string; ignore case for matching
  result.kind = pkTerminalIgnoreCase
  result.term = t

proc termIgnoreStyle*(t: string): Peg {.nosideEffect.} =
  ## constructs a PEG from a terminal string; ignore style for matching
  result.kind = pkTerminalIgnoreStyle
  result.term = t

proc term*(t: char): Peg {.nosideEffect.} =
  ## constructs a PEG from a terminal char
  assert t != '\0'
  result.kind = pkChar
  result.ch = t

proc charSet*(s: set[char]): Peg {.nosideEffect.} =
  ## constructs a PEG from a character set `s`
  assert '\0' notin s
  result.kind = pkCharChoice
  new(result.charChoice)
  result.charChoice[] = s

proc len(a: Peg): int {.inline.} = return a.sons.len
proc add(d: var Peg, s: Peg) {.inline.} = add(d.sons, s)

proc addChoice(dest: var Peg, elem: Peg) =
  var L = dest.len-1
  if L >= 0 and dest.sons[L].kind == pkCharChoice:
    # caution! Do not introduce false aliasing here!
    case elem.kind
    of pkCharChoice:
      dest.sons[L] = charSet(dest.sons[L].charChoice[] + elem.charChoice[])
    of pkChar:
      dest.sons[L] = charSet(dest.sons[L].charChoice[] + {elem.ch})
    else: add(dest, elem)
  else: add(dest, elem)

template multipleOp(k: PegKind, localOpt: untyped) =
  result.kind = k
  result.sons = @[]
  for x in items(a):
    if x.kind == k:
      for y in items(x.sons):
        localOpt(result, y)
    else:
      localOpt(result, x)
  if result.len == 1:
    result = result.sons[0]

proc `/`*(a: varargs[Peg]): Peg {.nosideEffect.} =
  ## constructs an ordered choice with the PEGs in `a`
  multipleOp(pkOrderedChoice, addChoice)

proc addSequence(dest: var Peg, elem: Peg) =
  var L = dest.len-1
  if L >= 0 and dest.sons[L].kind == pkTerminal:
    # caution! Do not introduce false aliasing here!
    case elem.kind
    of pkTerminal:
      dest.sons[L] = term(dest.sons[L].term & elem.term)
    of pkChar:
      dest.sons[L] = term(dest.sons[L].term & elem.ch)
    else: add(dest, elem)
  else: add(dest, elem)

proc sequence*(a: varargs[Peg]): Peg {.nosideEffect.} =
  ## constructs a sequence with all the PEGs from `a`
  multipleOp(pkSequence, addSequence)

proc `?`*(a: Peg): Peg {.nosideEffect.} =
  ## constructs an optional for the PEG `a`
  if a.kind in {pkOption, pkGreedyRep, pkGreedyAny, pkGreedyRepChar,
                pkGreedyRepSet}:
    # a* ?  --> a*
    # a? ?  --> a?
    result = a
  else:
    result.kind = pkOption
    result.sons = @[a]

proc `*`*(a: Peg): Peg {.nosideEffect.} =
  ## constructs a "greedy repetition" for the PEG `a`
  case a.kind
  of pkGreedyRep, pkGreedyRepChar, pkGreedyRepSet, pkGreedyAny, pkOption:
    assert false
    # produces endless loop!
  of pkChar:
    result.kind = pkGreedyRepChar
    result.ch = a.ch
  of pkCharChoice:
    result.kind = pkGreedyRepSet
    result.charChoice = a.charChoice # copying a reference suffices!
  of pkAny, pkAnyRune:
    result.kind = pkGreedyAny
  else:
    result.kind = pkGreedyRep
    result.sons = @[a]

proc `!*`*(a: Peg): Peg {.nosideEffect.} =
  ## constructs a "search" for the PEG `a`
  result.kind = pkSearch
  result.sons = @[a]

proc `!*\`*(a: Peg): Peg {.noSideEffect.} =
  ## constructs a "captured search" for the PEG `a`
  result.kind = pkCapturedSearch
  result.sons = @[a]

proc `+`*(a: Peg): Peg {.nosideEffect.} =
  ## constructs a "greedy positive repetition" with the PEG `a`
  return sequence(a, *a)

proc `&`*(a: Peg): Peg {.nosideEffect.} =
  ## constructs an "and predicate" with the PEG `a`
  result.kind = pkAndPredicate
  result.sons = @[a]

proc `!`*(a: Peg): Peg {.nosideEffect.} =
  ## constructs a "not predicate" with the PEG `a`
  result.kind = pkNotPredicate
  result.sons = @[a]

proc any*: Peg {.inline.} =
  ## constructs the PEG `any character`:idx: (``.``)
  result.kind = pkAny

proc anyRune*: Peg {.inline.} =
  ## constructs the PEG `any rune`:idx: (``_``)
  result.kind = pkAnyRune

proc newLine*: Peg {.inline.} =
  ## constructs the PEG `newline`:idx: (``\n``)
  result.kind = pkNewLine

proc unicodeLetter*: Peg {.inline.} =
  ## constructs the PEG ``\letter`` which matches any Unicode letter.
  result.kind = pkLetter

proc unicodeLower*: Peg {.inline.} =
  ## constructs the PEG ``\lower`` which matches any Unicode lowercase letter.
  result.kind = pkLower

proc unicodeUpper*: Peg {.inline.} =
  ## constructs the PEG ``\upper`` which matches any Unicode uppercase letter.
  result.kind = pkUpper

proc unicodeTitle*: Peg {.inline.} =
  ## constructs the PEG ``\title`` which matches any Unicode title letter.
  result.kind = pkTitle

proc unicodeWhitespace*: Peg {.inline.} =
  ## constructs the PEG ``\white`` which matches any Unicode
  ## whitespace character.
  result.kind = pkWhitespace

proc startAnchor*: Peg {.inline.} =
  ## constructs the PEG ``^`` which matches the start of the input.
  result.kind = pkStartAnchor

proc endAnchor*: Peg {.inline.} =
  ## constructs the PEG ``$`` which matches the end of the input.
  result = !any()

proc capture*(a: Peg): Peg {.nosideEffect.} =
  ## constructs a capture with the PEG `a`
  result.kind = pkCapture
  result.sons = @[a]

proc backref*(index: range[1..MaxSubpatterns]): Peg {.nosideEffect.} =
  ## constructs a back reference of the given `index`. `index` starts counting
  ## from 1.
  result.kind = pkBackRef
  result.index = index-1

proc backrefIgnoreCase*(index: range[1..MaxSubpatterns]): Peg {.nosideEffect.} =
  ## constructs a back reference of the given `index`. `index` starts counting
  ## from 1. Ignores case for matching.
  result.kind = pkBackRefIgnoreCase
  result.index = index-1

proc backrefIgnoreStyle*(index: range[1..MaxSubpatterns]): Peg {.nosideEffect.}=
  ## constructs a back reference of the given `index`. `index` starts counting
  ## from 1. Ignores style for matching.
  result.kind = pkBackRefIgnoreStyle
  result.index = index-1

proc spaceCost(n: Peg): int =
  case n.kind
  of pkEmpty: discard
  of pkTerminal, pkTerminalIgnoreCase, pkTerminalIgnoreStyle, pkChar,
     pkGreedyRepChar, pkCharChoice, pkGreedyRepSet,
     pkAny..pkWhitespace, pkGreedyAny:
    result = 1
  of pkNonTerminal:
    # we cannot inline a rule with a non-terminal
    result = InlineThreshold+1
  else:
    for i in 0..n.len-1:
      inc(result, spaceCost(n.sons[i]))
      if result >= InlineThreshold: break

proc nonterminal*(n: NonTerminal): Peg {.nosideEffect.} =
  ## constructs a PEG that consists of the nonterminal symbol
  assert n != nil
  if ntDeclared in n.flags and spaceCost(n.rule) < InlineThreshold:
    when false: echo "inlining symbol: ", n.name
    result = n.rule # inlining of rule enables better optimizations
  else:
    result.kind = pkNonTerminal
    result.nt = n

proc newNonTerminal*(name: string, line, column: int): NonTerminal {.nosideEffect.} =
  ## constructs a nonterminal symbol
  new(result)
  result.name = name
  result.line = line
  result.col = column

template letters*: Peg =
  ## expands to ``charset({'A'..'Z', 'a'..'z'})``
  charSet({'A'..'Z', 'a'..'z'})

template digits*: Peg =
  ## expands to ``charset({'0'..'9'})``
  charSet({'0'..'9'})

template whitespace*: Peg =
  ## expands to ``charset({' ', '\9'..'\13'})``
  charSet({' ', '\9'..'\13'})

template identChars*: Peg =
  ## expands to ``charset({'a'..'z', 'A'..'Z', '0'..'9', '_'})``
  charSet({'a'..'z', 'A'..'Z', '0'..'9', '_'})

template identStartChars*: Peg =
  ## expands to ``charset({'A'..'Z', 'a'..'z', '_'})``
  charSet({'a'..'z', 'A'..'Z', '_'})

template ident*: Peg =
  ## same as ``[a-zA-Z_][a-zA-z_0-9]*``; standard identifier
  sequence(charSet({'a'..'z', 'A'..'Z', '_'}),
           *charSet({'a'..'z', 'A'..'Z', '0'..'9', '_'}))

template natural*: Peg =
  ## same as ``\d+``
  +digits

# ------------------------- debugging -----------------------------------------

proc esc(c: char, reserved = {'\0'..'\255'}): string =
  case c
  of '\b': result = "\\b"
  of '\t': result = "\\t"
  of '\c': result = "\\c"
  of '\L': result = "\\l"
  of '\v': result = "\\v"
  of '\f': result = "\\f"
  of '\e': result = "\\e"
  of '\a': result = "\\a"
  of '\\': result = "\\\\"
  of 'a'..'z', 'A'..'Z', '0'..'9', '_': result = $c
  elif c < ' ' or c >= '\127': result = '\\' & $ord(c)
  elif c in reserved: result = '\\' & c
  else: result = $c

proc singleQuoteEsc(c: char): string = return "'" & esc(c, {'\''}) & "'"

proc singleQuoteEsc(str: string): string =
  result = "'"
  for c in items(str): add result, esc(c, {'\''})
  add result, '\''

proc charSetEscAux(cc: set[char]): string =
  const reserved = {'^', '-', ']'}
  result = ""
  var c1 = 0
  while c1 <= 0xff:
    if chr(c1) in cc:
      var c2 = c1
      while c2 < 0xff and chr(succ(c2)) in cc: inc(c2)
      if c1 == c2:
        add result, esc(chr(c1), reserved)
      elif c2 == succ(c1):
        add result, esc(chr(c1), reserved) & esc(chr(c2), reserved)
      else:
        add result, esc(chr(c1), reserved) & '-' & esc(chr(c2), reserved)
      c1 = c2
    inc(c1)

proc charSetEsc(cc: set[char]): string =
  if card(cc) >= 128+64:
    result = "[^" & charSetEscAux({'\1'..'\xFF'} - cc) & ']'
  else:
    result = '[' & charSetEscAux(cc) & ']'

proc toStrAux(r: Peg, res: var string) =
  case r.kind
  of pkEmpty: add(res, "()")
  of pkAny: add(res, '.')
  of pkAnyRune: add(res, '_')
  of pkLetter: add(res, "\\letter")
  of pkLower: add(res, "\\lower")
  of pkUpper: add(res, "\\upper")
  of pkTitle: add(res, "\\title")
  of pkWhitespace: add(res, "\\white")

  of pkNewLine: add(res, "\\n")
  of pkTerminal: add(res, singleQuoteEsc(r.term))
  of pkTerminalIgnoreCase:
    add(res, 'i')
    add(res, singleQuoteEsc(r.term))
  of pkTerminalIgnoreStyle:
    add(res, 'y')
    add(res, singleQuoteEsc(r.term))
  of pkChar: add(res, singleQuoteEsc(r.ch))
  of pkCharChoice: add(res, charSetEsc(r.charChoice[]))
  of pkNonTerminal: add(res, r.nt.name)
  of pkSequence:
    add(res, '(')
    toStrAux(r.sons[0], res)
    for i in 1 .. high(r.sons):
      add(res, ' ')
      toStrAux(r.sons[i], res)
    add(res, ')')
  of pkOrderedChoice:
    add(res, '(')
    toStrAux(r.sons[0], res)
    for i in 1 .. high(r.sons):
      add(res, " / ")
      toStrAux(r.sons[i], res)
    add(res, ')')
  of pkGreedyRep:
    toStrAux(r.sons[0], res)
    add(res, '*')
  of pkGreedyRepChar:
    add(res, singleQuoteEsc(r.ch))
    add(res, '*')
  of pkGreedyRepSet:
    add(res, charSetEsc(r.charChoice[]))
    add(res, '*')
  of pkGreedyAny:
    add(res, ".*")
  of pkOption:
    toStrAux(r.sons[0], res)
    add(res, '?')
  of pkAndPredicate:
    add(res, '&')
    toStrAux(r.sons[0], res)
  of pkNotPredicate:
    add(res, '!')
    toStrAux(r.sons[0], res)
  of pkSearch:
    add(res, '@')
    toStrAux(r.sons[0], res)
  of pkCapturedSearch:
    add(res, "{@}")
    toStrAux(r.sons[0], res)
  of pkCapture:
    add(res, '{')
    toStrAux(r.sons[0], res)
    add(res, '}')
  of pkBackRef:
    add(res, '$')
    add(res, $r.index)
  of pkBackRefIgnoreCase:
    add(res, "i$")
    add(res, $r.index)
  of pkBackRefIgnoreStyle:
    add(res, "y$")
    add(res, $r.index)
  of pkRule:
    toStrAux(r.sons[0], res)
    add(res, " <- ")
    toStrAux(r.sons[1], res)
  of pkList:
    for i in 0 .. high(r.sons):
      toStrAux(r.sons[i], res)
      add(res, "\n")
  of pkStartAnchor:
    add(res, '^')

proc `$` *(r: Peg): string {.nosideEffect.} =
  ## converts a PEG to its string representation
  result = ""
  toStrAux(r, result)

# --------------------- core engine -------------------------------------------

type
  Captures* = object ## contains the captured substrings.
    matches: array[0..MaxSubpatterns-1, tuple[first, last: int]]
    ml: int
    origStart: int

{.deprecated: [TCaptures: Captures].}

proc bounds*(c: Captures,
             i: range[0..MaxSubpatterns-1]): tuple[first, last: int] =
  ## returns the bounds ``[first..last]`` of the `i`'th capture.
  result = c.matches[i]

when not useUnicode:
  type
    Rune = char
  template fastRuneAt(s, i, ch) =
    ch = s[i]
    inc(i)
  template runeLenAt(s, i): untyped = 1

  proc isAlpha(a: char): bool {.inline.} = return a in {'a'..'z','A'..'Z'}
  proc isUpper(a: char): bool {.inline.} = return a in {'A'..'Z'}
  proc isLower(a: char): bool {.inline.} = return a in {'a'..'z'}
  proc isTitle(a: char): bool {.inline.} = return false
  proc isWhiteSpace(a: char): bool {.inline.} = return a in {' ', '\9'..'\13'}

template matchOrParse*(mopProc: untyped): untyped {.dirty.} =
  ## Internal use only.
  case p.kind
  of pkEmpty:
    enter(pkEmpty, p, start)
    result = 0 # match of length 0
    leave(pkEmpty, p, start, result)
  of pkAny:
    enter(pkAny, p, start)
    if start < s.len: result = 1
    else: result = -1
    leave(pkAny, p, start, result)
  of pkAnyRune:
    enter(pkAnyRune, p, start)
    if start < s.len:
      result = runeLenAt(s, start)
    else:
      result = -1
    leave(pkAnyRune, p, start, result)
  of pkLetter:
    enter(pkLetter, p, start)
    if start < s.len:
      var a: Rune
      result = start
      fastRuneAt(s, result, a)
      if isAlpha(a): dec(result, start)
      else: result = -1
    else:
      result = -1
    leave(pkLetter, p, start, result)
  of pkLower:
    enter(pkLower, p, start)
    if start < s.len:
      var a: Rune
      result = start
      fastRuneAt(s, result, a)
      if isLower(a): dec(result, start)
      else: result = -1
    else:
      result = -1
    leave(pkLower, p, start, result)
  of pkUpper:
    enter(pkUpper, p, start)
    if start < s.len:
      var a: Rune
      result = start
      fastRuneAt(s, result, a)
      if isUpper(a): dec(result, start)
      else: result = -1
    else:
      result = -1
    leave(pkUpper, p, start, result)
  of pkTitle:
    enter(pkTitle, p, start)
    if start < s.len:
      var a: Rune
      result = start
      fastRuneAt(s, result, a)
      if isTitle(a): dec(result, start)
      else: result = -1
    else:
      result = -1
    leave(pkTitle, p, start, result)
  of pkWhitespace:
    enter(pkWhitespace, p, start)
    if start < s.len:
      var a: Rune
      result = start
      fastRuneAt(s, result, a)
      if isWhiteSpace(a): dec(result, start)
      else: result = -1
    else:
      result = -1
    leave(pkWhitespace, p, start, result)
  of pkGreedyAny:
    enter(pkGreedyAny, p, start)
    result = len(s) - start
    leave(pkGreedyAny, p, start, result)
  of pkNewLine:
    enter(pkNewLine, p, start)
    if start < s.len and s[start] == '\L': result = 1
    elif start < s.len and s[start] == '\C':
      if start+1 < s.len and s[start+1] == '\L': result = 2
      else: result = 1
    else: result = -1
    leave(pkNewLine, p, start, result)
  of pkTerminal:
    enter(pkTerminal, p, start)
    result = len(p.term)
    for i in 0..result-1:
      if start+i >= s.len or p.term[i] != s[start+i]:
        result = -1
        break
    leave(pkTerminal, p, start, result)
  of pkTerminalIgnoreCase:
    enter(pkTerminalIgnoreCase, p, start)
    var
      i = 0
      a, b: Rune
    result = start
    while i < len(p.term):
      if result >= s.len:
        result = -1
        break
      fastRuneAt(p.term, i, a)
      fastRuneAt(s, result, b)
      if toLower(a) != toLower(b):
        result = -1
        break
    dec(result, start)
    leave(pkTerminalIgnoreCase, p, start, result)
  of pkTerminalIgnoreStyle:
    enter(pkTerminalIgnoreStyle, p, start)
    var
      i = 0
      a, b: Rune
    result = start
    while i < len(p.term):
      while i < len(p.term):
        fastRuneAt(p.term, i, a)
        if a != Rune('_'): break
      while result < s.len:
        fastRuneAt(s, result, b)
        if b != Rune('_'): break
      if result >= s.len:
        if i >= p.term.len: break
        else:
          result = -1
          break
      elif toLower(a) != toLower(b):
        result = -1
        break
    dec(result, start)
    leave(pkTerminalIgnoreStyle, p, start, result)
  of pkChar:
    enter(pkChar, p, start)
    if start < s.len and p.ch == s[start]: result = 1
    else: result = -1
    leave(pkChar, p, start, result)
  of pkCharChoice:
    enter(pkCharChoice, p, start)
    if start < s.len and contains(p.charChoice[], s[start]): result = 1
    else: result = -1
    leave(pkCharChoice, p, start, result)
  of pkNonTerminal:
    enter(pkNonTerminal, p, start)
    var oldMl = c.ml
    when false: echo "enter: ", p.nt.name
    result = mopProc(s, p.nt.rule, start, c)
    when false: echo "leave: ", p.nt.name
    if result < 0: c.ml = oldMl
    leave(pkNonTerminal, p, start, result)
  of pkSequence:
    enter(pkSequence, p, start)
    var oldMl = c.ml
    result = 0
    for i in 0..high(p.sons):
      var x = mopProc(s, p.sons[i], start+result, c)
      if x < 0:
        c.ml = oldMl
        result = -1
        break
      else: inc(result, x)
    leave(pkSequence, p, start, result)
  of pkOrderedChoice:
    enter(pkOrderedChoice, p, start)
    var oldMl = c.ml
    for i in 0..high(p.sons):
      result = mopProc(s, p.sons[i], start, c)
      if result >= 0: break
      c.ml = oldMl
    leave(pkOrderedChoice, p, start, result)
  of pkSearch:
    enter(pkSearch, p, start)
    var oldMl = c.ml
    result = 0
    while start+result <= s.len:
      var x = mopProc(s, p.sons[0], start+result, c)
      if x >= 0:
        inc(result, x)
        return
      inc(result)
    result = -1
    c.ml = oldMl
    leave(pkSearch, p, start, result)
  of pkCapturedSearch:
    enter(pkCapturedSearch, p, start)
    var idx = c.ml # reserve a slot for the subpattern
    inc(c.ml)
    result = 0
    while start+result <= s.len:
      var x = mopProc(s, p.sons[0], start+result, c)
      if x >= 0:
        if idx < MaxSubpatterns:
          c.matches[idx] = (start, start+result-1)
        #else: silently ignore the capture
        inc(result, x)
        return
      inc(result)
    result = -1
    c.ml = idx
    leave(pkCapturedSearch, p, start, result)
  of pkGreedyRep:
    enter(pkGreedyRep, p, start)
    result = 0
    while true:
      var x = mopProc(s, p.sons[0], start+result, c)
      # if x == 0, we have an endless loop; so the correct behaviour would be
      # not to break. But endless loops can be easily introduced:
      # ``(comment / \w*)*`` is such an example. Breaking for x == 0 does the
      # expected thing in this case.
      if x <= 0: break
      inc(result, x)
    leave(pkGreedyRep, p, start, result)
  of pkGreedyRepChar:
    enter(pkGreedyRepChar, p, start)
    result = 0
    var ch = p.ch
    while start+result < s.len and ch == s[start+result]: inc(result)
    leave(pkGreedyRepChar, p, start, result)
  of pkGreedyRepSet:
    enter(pkGreedyRepSet, p, start)
    result = 0
    while start+result < s.len and contains(p.charChoice[], s[start+result]): inc(result)
    leave(pkGreedyRepSet, p, start, result)
  of pkOption:
    enter(pkOption, p, start)
    result = max(0, mopProc(s, p.sons[0], start, c))
    leave(pkOption, p, start, result)
  of pkAndPredicate:
    enter(pkAndPredicate, p, start)
    var oldMl = c.ml
    result = mopProc(s, p.sons[0], start, c)
    if result >= 0: result = 0 # do not consume anything
    else: c.ml = oldMl
    leave(pkAndPredicate, p, start, result)
  of pkNotPredicate:
    enter(pkNotPredicate, p, start)
    var oldMl = c.ml
    result = mopProc(s, p.sons[0], start, c)
    if result < 0: result = 0
    else:
      c.ml = oldMl
      result = -1
    leave(pkNotPredicate, p, start, result)
  of pkCapture:
    enter(pkCapture, p, start)
    var idx = c.ml # reserve a slot for the subpattern
    inc(c.ml)
    result = mopProc(s, p.sons[0], start, c)
    if result >= 0:
      if idx < MaxSubpatterns:
        c.matches[idx] = (start, start+result-1)
      #else: silently ignore the capture
    else:
      c.ml = idx
    leave(pkCapture, p, start, result)
  of pkBackRef..pkBackRefIgnoreStyle:
    enter(pkBackRef, p, start)
    if p.index >= c.ml: return -1
    var (a, b) = c.matches[p.index]
    var n: Peg
    n.kind = succ(pkTerminal, ord(p.kind)-ord(pkBackRef))
    n.term = s.substr(a, b)
    result = mopProc(s, n, start, c)
    leave(pkBackRef, p, start, result)
  of pkStartAnchor:
    enter(pkStartAnchor, p, start)
    if c.origStart == start: result = 0
    else: result = -1
    leave(pkStartAnchor, p, start, result)
  of pkRule, pkList: assert false

proc rawMatch*(s: string, p: Peg, start: int, c: var Captures): int
      {.nosideEffect.} =
  ## low-level matching proc that implements the PEG interpreter. Use this
  ## for maximum efficiency (every other PEG operation ends up calling this
  ## proc).
  ## Returns -1 if it does not match, else the length of the match

  # Set the handlers to do-nothing.
  template enter(pk, p, start) =
    discard
  template leave(pk, p, start, length) =
    discard
  matchOrParse(rawMatch)

template eventParser*(pegAst, handlers: untyped): (proc(s: string): int) {.dirty.} =
  ## Generates an interpreting event parser proc according to the specified PEG
  ## AST and handler code blocks. The proc can be called with a text
  ## to be parsed and will execute the handler code blocks whenever their
  ## associated grammar element is matched. It returns -1 if the text does not
  ## match, else the length of the total match. The following example code
  ## evaluates an arithmetic expression defined by a simple PEG:
  ##
  ## .. code-block:: nim
  ##  import strutils, pegs
  ##
  ##  let
  ##    pegAst = """
  ##  Expr    <- Sum
  ##  Sum     <- Product (('+' / '-')Product)*
  ##  Product <- Value (('*' / '/')Value)*
  ##  Value   <- [0-9]+ / '(' Expr ')'
  ##    """.peg
  ##    txt = "(5+3)/2-7*22"
  ##
  ##  var
  ##    pStack: seq[string] = @[]
  ##    valStack: seq[float] = @[]
  ##    opStack = ""
  ##  let
  ##    parseArithExpr = pegAst.eventParser:
  ##      pkNonTerminal:
  ##        enter:
  ##          pStack.add p.nt.name
  ##        leave:
  ##          pStack.setLen pStack.high
  ##          if length > 0:
  ##            let matchStr = txt.substr(start, start+length-1)
  ##            case p.nt.name
  ##            of "Value":
  ##              try:
  ##                valStack.add matchStr.parseFloat
  ##                echo valStack
  ##              except ValueError:
  ##                discard
  ##            of "Sum", "Product":
  ##              try:
  ##                let val = matchStr.parseFloat
  ##              except ValueError:
  ##                if valStack.len > 1 and opStack.len > 0:
  ##                  valStack[^2] = case opStack[^1]
  ##                  of '+': valStack[^2] + valStack[^1]
  ##                  of '-': valStack[^2] - valStack[^1]
  ##                  of '*': valStack[^2] * valStack[^1]
  ##                  else: valStack[^2] / valStack[^1]
  ##                  valStack.setLen valStack.high
  ##                  echo valStack 
  ##                  opStack.setLen opStack.high
  ##                  echo opStack 
  ##      pkChar:
  ##        leave:
  ##          if length == 1 and "Value" != pStack[^1]:
  ##            let matchChar = txt[start]
  ##            opStack.add matchChar
  ##            echo opStack
  ##
  ##  let pLen = parseArithExpr(txt)
  ## 
  ## The *handlers* parameter consists of code blocks for *PegKinds*,
  ## which define the grammar elements of interest. Each block can contain
  ## handler code to be executed when the parser enters and leaves text
  ## matching the grammar element. An *enter* handler can access the specific
  ## PEG AST node being matched as *p* and the position of the matched text
  ## segment as *start*. A *leave* handler can access *p*, *start* and
  ## also the length of the matched text segment as *length*. Symbols
  ## declared in an *enter* handler can be made visible in the corresponding
  ## *leave* handler by annotating them with an *inject* pragma.
  template mkEnterCb(cbPostf, body) {.dirty.} =
    template `enter cbPostf`(p, start) =
      body

  template mkLeaveCb(cbPostf, body) {.dirty.} =
    template `leave cbPostf`(p, start, length) =
      body

  macro mkHandlers(hdlrs: untyped): untyped =
    let cbms = newStmtList()
    for co in hdlrs[0]:
      if nnkCall != co.kind:
        error("Call syntax expected.", co)
      let pk = co[0]
      if nnkIdent != pk.kind:
        error("PegKind expected.", pk)
      if 2 == co.len:
        for cb in co[1]:
          if nnkCall != cb.kind:
            error("Call syntax expected.", cb)
          if nnkIdent != cb[0].kind:
            error("Handler identifier expected.", cb[0])
          if 2 == cb.len:
            let cbPostf = toNimIdent(substr($pk.ident, 2))
            case $cb[0].ident
            of "enter":
              cbms.add getAst(mkEnterCb(cbPostf, cb[1]))
            of "leave":
              cbms.add getAst(mkLeaveCb(cbPostf, cb[1]))
            else:
              error(
                "Unsupported handler identifier, expected 'enter' or 'leave'.",
                cb[0]
              )
    cbms

  block:
    proc parser(s: string): int =
      var
        ms: array[MaxSubpatterns, (int, int)]
        cs = Captures(matches: ms, ml: 0, origStart: 0)
      proc parseIt(s: string, p: Peg, start: int, c: var Captures): int =

        mkHandlers:
          handlers

        macro enter(pk, p, start: untyped): untyped =
          template mkDoEnter(cbPostf, p, start) =
            when declared(`enter cbPostf`):
              `enter cbPostf`(p, start):
            else:
              discard
          let cbPostf = toNimIdent(substr($pk.ident, 2))
          getAst(mkDoEnter(cbPostf, p, start))

        macro leave(pk, p, start, length: untyped): untyped =
          template mkDoLeave(cbPostf, p, start, length) =
            when declared(`leave cbPostf`):
              `leave cbPostf`(p, start, length):
            else:
              discard
          let cbPostf = toNimIdent(substr($pk.ident, 2))
          getAst(mkDoLeave(cbPostf, p, start, length))

        matchOrParse(parseIt)
      parseIt(s, pegAst, 0, cs)
    parser

template fillMatches(s, caps, c) =
  for k in 0..c.ml-1:
    let startIdx = c.matches[k][0]
    let endIdx = c.matches[k][1]
    if startIdx != -1:
      caps[k] = substr(s, startIdx, endIdx)
    else:
      caps[k] = nil

proc matchLen*(s: string, pattern: Peg, matches: var openArray[string],
               start = 0): int {.nosideEffect.} =
  ## the same as ``match``, but it returns the length of the match,
  ## if there is no match, -1 is returned. Note that a match length
  ## of zero can happen. It's possible that a suffix of `s` remains
  ## that does not belong to the match.
  var c: Captures
  c.origStart = start
  result = rawMatch(s, pattern, start, c)
  if result >= 0: fillMatches(s, matches, c)

proc matchLen*(s: string, pattern: Peg,
               start = 0): int {.nosideEffect.} =
  ## the same as ``match``, but it returns the length of the match,
  ## if there is no match, -1 is returned. Note that a match length
  ## of zero can happen. It's possible that a suffix of `s` remains
  ## that does not belong to the match.
  var c: Captures
  c.origStart = start
  result = rawMatch(s, pattern, start, c)

proc match*(s: string, pattern: Peg, matches: var openArray[string],
            start = 0): bool {.nosideEffect.} =
  ## returns ``true`` if ``s[start..]`` matches the ``pattern`` and
  ## the captured substrings in the array ``matches``. If it does not
  ## match, nothing is written into ``matches`` and ``false`` is
  ## returned.
  result = matchLen(s, pattern, matches, start) != -1

proc match*(s: string, pattern: Peg,
            start = 0): bool {.nosideEffect.} =
  ## returns ``true`` if ``s`` matches the ``pattern`` beginning from ``start``.
  result = matchLen(s, pattern, start) != -1


proc find*(s: string, pattern: Peg, matches: var openArray[string],
           start = 0): int {.nosideEffect.} =
  ## returns the starting position of ``pattern`` in ``s`` and the captured
  ## substrings in the array ``matches``. If it does not match, nothing
  ## is written into ``matches`` and -1 is returned.
  var c: Captures
  c.origStart = start
  for i in start .. s.len-1:
    c.ml = 0
    if rawMatch(s, pattern, i, c) >= 0:
      fillMatches(s, matches, c)
      return i
  return -1
  # could also use the pattern here: (!P .)* P

proc findBounds*(s: string, pattern: Peg, matches: var openArray[string],
                 start = 0): tuple[first, last: int] {.nosideEffect.} =
  ## returns the starting position and end position of ``pattern`` in ``s``
  ## and the captured
  ## substrings in the array ``matches``. If it does not match, nothing
  ## is written into ``matches`` and (-1,0) is returned.
  var c: Captures
  c.origStart = start
  for i in start .. s.len-1:
    c.ml = 0
    var L = rawMatch(s, pattern, i, c)
    if L >= 0:
      fillMatches(s, matches, c)
      return (i, i+L-1)
  return (-1, 0)

proc find*(s: string, pattern: Peg,
           start = 0): int {.nosideEffect.} =
  ## returns the starting position of ``pattern`` in ``s``. If it does not
  ## match, -1 is returned.
  var c: Captures
  c.origStart = start
  for i in start .. s.len-1:
    if rawMatch(s, pattern, i, c) >= 0: return i
  return -1

iterator findAll*(s: string, pattern: Peg, start = 0): string =
  ## yields all matching *substrings* of `s` that match `pattern`.
  var c: Captures
  c.origStart = start
  var i = start
  while i < s.len:
    c.ml = 0
    var L = rawMatch(s, pattern, i, c)
    if L < 0:
      inc(i, 1)
    else:
      yield substr(s, i, i+L-1)
      inc(i, L)

proc findAll*(s: string, pattern: Peg, start = 0): seq[string] {.nosideEffect.} =
  ## returns all matching *substrings* of `s` that match `pattern`.
  ## If it does not match, @[] is returned.
  accumulateResult(findAll(s, pattern, start))

when not defined(nimhygiene):
  {.pragma: inject.}

template `=~`*(s: string, pattern: Peg): bool =
  ## This calls ``match`` with an implicit declared ``matches`` array that
  ## can be used in the scope of the ``=~`` call:
  ##
  ## .. code-block:: nim
  ##
  ##   if line =~ peg"\s* {\w+} \s* '=' \s* {\w+}":
  ##     # matches a key=value pair:
  ##     echo("Key: ", matches[0])
  ##     echo("Value: ", matches[1])
  ##   elif line =~ peg"\s*{'#'.*}":
  ##     # matches a comment
  ##     # note that the implicit ``matches`` array is different from the
  ##     # ``matches`` array of the first branch
  ##     echo("comment: ", matches[0])
  ##   else:
  ##     echo("syntax error")
  ##
  bind MaxSubpatterns
  when not declaredInScope(matches):
    var matches {.inject.}: array[0..MaxSubpatterns-1, string]
  match(s, pattern, matches)

# ------------------------- more string handling ------------------------------

proc contains*(s: string, pattern: Peg, start = 0): bool {.nosideEffect.} =
  ## same as ``find(s, pattern, start) >= 0``
  return find(s, pattern, start) >= 0

proc contains*(s: string, pattern: Peg, matches: var openArray[string],
              start = 0): bool {.nosideEffect.} =
  ## same as ``find(s, pattern, matches, start) >= 0``
  return find(s, pattern, matches, start) >= 0

proc startsWith*(s: string, prefix: Peg, start = 0): bool {.nosideEffect.} =
  ## returns true if `s` starts with the pattern `prefix`
  result = matchLen(s, prefix, start) >= 0

proc endsWith*(s: string, suffix: Peg, start = 0): bool {.nosideEffect.} =
  ## returns true if `s` ends with the pattern `suffix`
  var c: Captures
  c.origStart = start
  for i in start .. s.len-1:
    if rawMatch(s, suffix, i, c) == s.len - i: return true

proc replacef*(s: string, sub: Peg, by: string): string {.nosideEffect.} =
  ## Replaces `sub` in `s` by the string `by`. Captures can be accessed in `by`
  ## with the notation ``$i`` and ``$#`` (see strutils.`%`). Examples:
  ##
  ## .. code-block:: nim
  ##   "var1=key; var2=key2".replacef(peg"{\ident}'='{\ident}", "$1<-$2$2")
  ##
  ## Results in:
  ##
  ## .. code-block:: nim
  ##
  ##   "var1<-keykey; val2<-key2key2"
  result = ""
  var i = 0
  var caps: array[0..MaxSubpatterns-1, string]
  var c: Captures
  while i < s.len:
    c.ml = 0
    var x = rawMatch(s, sub, i, c)
    if x <= 0:
      add(result, s[i])
      inc(i)
    else:
      fillMatches(s, caps, c)
      addf(result, by, caps)
      inc(i, x)
  add(result, substr(s, i))

proc replace*(s: string, sub: Peg, by = ""): string {.nosideEffect.} =
  ## Replaces `sub` in `s` by the string `by`. Captures cannot be accessed
  ## in `by`.
  result = ""
  var i = 0
  var c: Captures
  while i < s.len:
    var x = rawMatch(s, sub, i, c)
    if x <= 0:
      add(result, s[i])
      inc(i)
    else:
      add(result, by)
      inc(i, x)
  add(result, substr(s, i))

proc parallelReplace*(s: string, subs: varargs[
                      tuple[pattern: Peg, repl: string]]): string {.
                      nosideEffect.} =
  ## Returns a modified copy of `s` with the substitutions in `subs`
  ## applied in parallel.
  result = ""
  var i = 0
  var c: Captures
  var caps: array[0..MaxSubpatterns-1, string]
  while i < s.len:
    block searchSubs:
      for j in 0..high(subs):
        c.ml = 0
        var x = rawMatch(s, subs[j][0], i, c)
        if x > 0:
          fillMatches(s, caps, c)
          addf(result, subs[j][1], caps)
          inc(i, x)
          break searchSubs
      add(result, s[i])
      inc(i)
  # copy the rest:
  add(result, substr(s, i))

proc replace*(s: string, sub: Peg, cb: proc(
              match: int, cnt: int, caps: openArray[string]): string): string =
  ## Replaces `sub` in `s` by the resulting strings from the callback.
  ## The callback proc receives the index of the current match (starting with 0),
  ## the count of captures and an open array with the captures of each match. Examples:
  ##
  ## .. code-block:: nim
  ##
  ##   proc handleMatches*(m: int, n: int, c: openArray[string]): string =
  ##     result = ""
  ##     if m > 0:
  ##       result.add ", "
  ##     result.add case n:
  ##       of 2: c[0].toLower & ": '" & c[1] & "'"
  ##       of 1: c[0].toLower & ": ''"
  ##       else: ""
  ##
  ##   let s = "Var1=key1;var2=Key2;   VAR3"
  ##   echo s.replace(peg"{\ident}('='{\ident})* ';'* \s*", handleMatches)
  ##
  ## Results in:
  ##
  ## .. code-block:: nim
  ##
  ##   "var1: 'key1', var2: 'Key2', var3: ''"
  result = ""
  var i = 0
  var caps: array[0..MaxSubpatterns-1, string]
  var c: Captures
  var m = 0
  while i < s.len:
    c.ml = 0
    var x = rawMatch(s, sub, i, c)
    if x <= 0:
      add(result, s[i])
      inc(i)
    else:
      fillMatches(s, caps, c)
      add(result, cb(m, c.ml, caps))
      inc(i, x)
      inc(m)
  add(result, substr(s, i))

when not defined(js):
  proc transformFile*(infile, outfile: string,
                      subs: varargs[tuple[pattern: Peg, repl: string]]) =
    ## reads in the file `infile`, performs a parallel replacement (calls
    ## `parallelReplace`) and writes back to `outfile`. Raises ``EIO`` if an
    ## error occurs. This is supposed to be used for quick scripting.
    ##
    ## **Note**: this proc does not exist while using the JS backend.
    var x = readFile(infile).string
    writeFile(outfile, x.parallelReplace(subs))


iterator split*(s: string, sep: Peg): string =
  ## Splits the string `s` into substrings.
  ##
  ## Substrings are separated by the PEG `sep`.
  ## Examples:
  ##
  ## .. code-block:: nim
  ##   for word in split("00232this02939is39an22example111", peg"\d+"):
  ##     writeLine(stdout, word)
  ##
  ## Results in:
  ##
  ## .. code-block:: nim
  ##   "this"
  ##   "is"
  ##   "an"
  ##   "example"
  ##
  var c: Captures
  var
    first = 0
    last = 0
  while last < len(s):
    c.ml = 0
    var x = rawMatch(s, sep, last, c)
    if x > 0: inc(last, x)
    first = last
    while last < len(s):
      inc(last)
      c.ml = 0
      x = rawMatch(s, sep, last, c)
      if x > 0: break
    if first < last:
      yield substr(s, first, last-1)

proc split*(s: string, sep: Peg): seq[string] {.nosideEffect.} =
  ## Splits the string `s` into substrings.
  accumulateResult(split(s, sep))

# ------------------- scanner -------------------------------------------------

type
  Modifier = enum
    modNone,
    modVerbatim,
    modIgnoreCase,
    modIgnoreStyle
  TokKind = enum       ## enumeration of all tokens
    tkInvalid,          ## invalid token
    tkEof,              ## end of file reached
    tkAny,              ## .
    tkAnyRune,          ## _
    tkIdentifier,       ## abc
    tkStringLit,        ## "abc" or 'abc'
    tkCharSet,          ## [^A-Z]
    tkParLe,            ## '('
    tkParRi,            ## ')'
    tkCurlyLe,          ## '{'
    tkCurlyRi,          ## '}'
    tkCurlyAt,          ## '{@}'
    tkArrow,            ## '<-'
    tkBar,              ## '/'
    tkStar,             ## '*'
    tkPlus,             ## '+'
    tkAmp,              ## '&'
    tkNot,              ## '!'
    tkOption,           ## '?'
    tkAt,               ## '@'
    tkBuiltin,          ## \identifier
    tkEscaped,          ## \\
    tkBackref,          ## '$'
    tkDollar,           ## '$'
    tkHat               ## '^'

  Token {.final.} = object  ## a token
    kind: TokKind           ## the type of the token
    modifier: Modifier
    literal: string          ## the parsed (string) literal
    charset: set[char]       ## if kind == tkCharSet
    index: int               ## if kind == tkBackref

  PegLexer {.inheritable.} = object          ## the lexer object.
    bufpos: int               ## the current position within the buffer
    buf: cstring              ## the buffer itself
    lineNumber: int           ## the current line number
    lineStart: int            ## index of last line start in buffer
    colOffset: int            ## column to add
    filename: string

const
  tokKindToStr: array[TokKind, string] = [
    "invalid", "[EOF]", ".", "_", "identifier", "string literal",
    "character set", "(", ")", "{", "}", "{@}",
    "<-", "/", "*", "+", "&", "!", "?",
    "@", "built-in", "escaped", "$", "$", "^"
  ]

proc handleCR(L: var PegLexer, pos: int): int =
  assert(L.buf[pos] == '\c')
  inc(L.lineNumber)
  result = pos+1
  if result < L.buf.len and L.buf[result] == '\L': inc(result)
  L.lineStart = result

proc handleLF(L: var PegLexer, pos: int): int =
  assert(L.buf[pos] == '\L')
  inc(L.lineNumber)
  result = pos+1
  L.lineStart = result

proc init(L: var PegLexer, input, filename: string, line = 1, col = 0) =
  L.buf = input
  L.bufpos = 0
  L.lineNumber = line
  L.colOffset = col
  L.lineStart = 0
  L.filename = filename

proc getColumn(L: PegLexer): int {.inline.} =
  result = abs(L.bufpos - L.lineStart) + L.colOffset

proc getLine(L: PegLexer): int {.inline.} =
  result = L.lineNumber

proc errorStr(L: PegLexer, msg: string, line = -1, col = -1): string =
  var line = if line < 0: getLine(L) else: line
  var col = if col < 0: getColumn(L) else: col
  result = "$1($2, $3) Error: $4" % [L.filename, $line, $col, msg]

proc handleHexChar(c: var PegLexer, xi: var int) =
  case c.buf[c.bufpos]
  of '0'..'9':
    xi = (xi shl 4) or (ord(c.buf[c.bufpos]) - ord('0'))
    inc(c.bufpos)
  of 'a'..'f':
    xi = (xi shl 4) or (ord(c.buf[c.bufpos]) - ord('a') + 10)
    inc(c.bufpos)
  of 'A'..'F':
    xi = (xi shl 4) or (ord(c.buf[c.bufpos]) - ord('A') + 10)
    inc(c.bufpos)
  else: discard

proc getEscapedChar(c: var PegLexer, tok: var Token) =
  inc(c.bufpos)
  case c.buf[c.bufpos]
  of 'r', 'R', 'c', 'C':
    add(tok.literal, '\c')
    inc(c.bufpos)
  of 'l', 'L':
    add(tok.literal, '\L')
    inc(c.bufpos)
  of 'f', 'F':
    add(tok.literal, '\f')
    inc(c.bufpos)
  of 'e', 'E':
    add(tok.literal, '\e')
    inc(c.bufpos)
  of 'a', 'A':
    add(tok.literal, '\a')
    inc(c.bufpos)
  of 'b', 'B':
    add(tok.literal, '\b')
    inc(c.bufpos)
  of 'v', 'V':
    add(tok.literal, '\v')
    inc(c.bufpos)
  of 't', 'T':
    add(tok.literal, '\t')
    inc(c.bufpos)
  of 'x', 'X':
    inc(c.bufpos)
    var xi = 0
    handleHexChar(c, xi)
    handleHexChar(c, xi)
    if xi == 0: tok.kind = tkInvalid
    else: add(tok.literal, chr(xi))
  of '0'..'9':
    var val = ord(c.buf[c.bufpos]) - ord('0')
    inc(c.bufpos)
    var i = 1
    while (i <= 3) and (c.buf[c.bufpos] in {'0'..'9'}):
      val = val * 10 + ord(c.buf[c.bufpos]) - ord('0')
      inc(c.bufpos)
      inc(i)
    if val > 0 and val <= 255: add(tok.literal, chr(val))
    else: tok.kind = tkInvalid
  of '\0'..'\31':
    tok.kind = tkInvalid
  elif c.buf[c.bufpos] in strutils.Letters:
    tok.kind = tkInvalid
  else:
    add(tok.literal, c.buf[c.bufpos])
    inc(c.bufpos)

proc skip(c: var PegLexer) =
  var pos = c.bufpos
  var buf = c.buf
  while pos < c.buf.len:
    case buf[pos]
    of ' ', '\t':
      inc(pos)
    of '#':
      while (pos < c.buf.len) and
             not (buf[pos] in {'\c', '\L', '\0'}): inc(pos)
    of '\c':
      pos = handleCR(c, pos)
      buf = c.buf
    of '\L':
      pos = handleLF(c, pos)
      buf = c.buf
    else:
      break                   # EndOfFile also leaves the loop
  c.bufpos = pos

proc getString(c: var PegLexer, tok: var Token) =
  tok.kind = tkStringLit
  var pos = c.bufpos + 1
  var buf = c.buf
  var quote = buf[pos-1]
  while pos < c.buf.len:
    case buf[pos]
    of '\\':
      c.bufpos = pos
      getEscapedChar(c, tok)
      pos = c.bufpos
    of '\c', '\L', '\0':
      tok.kind = tkInvalid
      break
    elif buf[pos] == quote:
      inc(pos)
      break
    else:
      add(tok.literal, buf[pos])
      inc(pos)
  c.bufpos = pos

proc getDollar(c: var PegLexer, tok: var Token) =
  var pos = c.bufpos + 1
  var buf = c.buf
  if buf[pos] in {'0'..'9'}:
    tok.kind = tkBackref
    tok.index = 0
    while pos < c.buf.len and buf[pos] in {'0'..'9'}:
      tok.index = tok.index * 10 + ord(buf[pos]) - ord('0')
      inc(pos)
  else:
    tok.kind = tkDollar
  c.bufpos = pos

proc getCharSet(c: var PegLexer, tok: var Token) =
  tok.kind = tkCharSet
  tok.charset = {}
  var pos = c.bufpos + 1
  var buf = c.buf
  var caret = false
  if buf[pos] == '^':
    inc(pos)
    caret = true
  while pos < c.buf.len:
    var ch: char
    case buf[pos]
    of ']':
      if pos < c.buf.len: inc(pos)
      break
    of '\\':
      c.bufpos = pos
      getEscapedChar(c, tok)
      pos = c.bufpos
      ch = tok.literal[tok.literal.len-1]
    of '\C', '\L', '\0':
      tok.kind = tkInvalid
      break
    else:
      ch = buf[pos]
      inc(pos)
    incl(tok.charset, ch)
    if buf[pos] == '-':
      if pos+1 < c.buf.len and buf[pos+1] == ']':
        incl(tok.charset, '-')
        inc(pos)
      else:
        if pos+1 < c.buf.len:
          inc(pos)
        else:
          break
        var ch2: char
        case buf[pos]
        of '\\':
          c.bufpos = pos
          getEscapedChar(c, tok)
          pos = c.bufpos
          ch2 = tok.literal[tok.literal.len-1]
        of '\C', '\L', '\0':
          tok.kind = tkInvalid
          break
        else:
          if pos+1 < c.buf.len:
            ch2 = buf[pos]
            inc(pos)
          else:
            break
        for i in ord(ch)+1 .. ord(ch2):
          incl(tok.charset, chr(i))
  c.bufpos = pos
  if caret: tok.charset = {'\1'..'\xFF'} - tok.charset

proc getSymbol(c: var PegLexer, tok: var Token) =
  var pos = c.bufpos
  var buf = c.buf
  while pos < c.buf.len:
    add(tok.literal, buf[pos])
    inc(pos)
    if pos < buf.len and buf[pos] notin strutils.IdentChars: break
  c.bufpos = pos
  tok.kind = tkIdentifier

proc getBuiltin(c: var PegLexer, tok: var Token) =
  if c.bufpos+1 < c.buf.len and c.buf[c.bufpos+1] in strutils.Letters:
    inc(c.bufpos)
    getSymbol(c, tok)
    tok.kind = tkBuiltin
  else:
    tok.kind = tkEscaped
    getEscapedChar(c, tok) # may set tok.kind to tkInvalid

proc getTok(c: var PegLexer, tok: var Token) =
  tok.kind = tkInvalid
  tok.modifier = modNone
  setLen(tok.literal, 0)
  skip(c)

  case c.buf[c.bufpos]
  of '{':
    inc(c.bufpos)
    if c.buf[c.bufpos] == '@' and c.bufpos+2 < c.buf.len and
      c.buf[c.bufpos+1] == '}':
      tok.kind = tkCurlyAt
      inc(c.bufpos, 2)
      add(tok.literal, "{@}")
    else:
      tok.kind = tkCurlyLe
      add(tok.literal, '{')
  of '}':
    tok.kind = tkCurlyRi
    inc(c.bufpos)
    add(tok.literal, '}')
  of '[':
    getCharSet(c, tok)
  of '(':
    tok.kind = tkParLe
    inc(c.bufpos)
    add(tok.literal, '(')
  of ')':
    tok.kind = tkParRi
    inc(c.bufpos)
    add(tok.literal, ')')
  of '.':
    tok.kind = tkAny
    inc(c.bufpos)
    add(tok.literal, '.')
  of '_':
    tok.kind = tkAnyRune
    inc(c.bufpos)
    add(tok.literal, '_')
  of '\\':
    getBuiltin(c, tok)
  of '\'', '"': getString(c, tok)
  of '$': getDollar(c, tok)
  of 'a'..'z', 'A'..'Z', '\128'..'\255':
    getSymbol(c, tok)
    if c.buf[c.bufpos] in {'\'', '"'} or
        c.buf[c.bufpos] == '$' and c.bufpos+1 < c.buf.len and
        c.buf[c.bufpos+1] in {'0'..'9'}:
      case tok.literal
      of "i": tok.modifier = modIgnoreCase
      of "y": tok.modifier = modIgnoreStyle
      of "v": tok.modifier = modVerbatim
      else: discard
      setLen(tok.literal, 0)
      if c.buf[c.bufpos] == '$':
        getDollar(c, tok)
      else:
        getString(c, tok)
      if tok.modifier == modNone: tok.kind = tkInvalid
  of '+':
    tok.kind = tkPlus
    inc(c.bufpos)
    add(tok.literal, '+')
  of '*':
    tok.kind = tkStar
    inc(c.bufpos)
    add(tok.literal, '+')
  of '<':
    if c.bufpos+2 < c.buf.len and c.buf[c.bufpos+1] == '-':
      inc(c.bufpos, 2)
      tok.kind = tkArrow
      add(tok.literal, "<-")
    else:
      add(tok.literal, '<')
  of '/':
    tok.kind = tkBar
    inc(c.bufpos)
    add(tok.literal, '/')
  of '?':
    tok.kind = tkOption
    inc(c.bufpos)
    add(tok.literal, '?')
  of '!':
    tok.kind = tkNot
    inc(c.bufpos)
    add(tok.literal, '!')
  of '&':
    tok.kind = tkAmp
    inc(c.bufpos)
    add(tok.literal, '!')
  of '@':
    tok.kind = tkAt
    inc(c.bufpos)
    add(tok.literal, '@')
    if c.buf[c.bufpos] == '@':
      tok.kind = tkCurlyAt
      inc(c.bufpos)
      add(tok.literal, '@')
  of '^':
    tok.kind = tkHat
    inc(c.bufpos)
    add(tok.literal, '^')
  else:
    if c.bufpos >= c.buf.len:
      tok.kind = tkEof
      tok.literal = "[EOF]"
    add(tok.literal, c.buf[c.bufpos])
    inc(c.bufpos)

proc arrowIsNextTok(c: PegLexer): bool =
  # the only look ahead we need
  var pos = c.bufpos
  while pos < c.buf.len and c.buf[pos] in {'\t', ' '}: inc(pos)
  result = c.buf[pos] == '<' and (pos+1 < c.buf.len) and c.buf[pos+1] == '-'

# ----------------------------- parser ----------------------------------------

type
  EInvalidPeg* = object of ValueError ## raised if an invalid
                                         ## PEG has been detected
  PegParser = object of PegLexer ## the PEG parser object
    tok: Token
    nonterms: seq[NonTerminal]
    modifier: Modifier
    captures: int
    identIsVerbatim: bool
    skip: Peg

proc pegError(p: PegParser, msg: string, line = -1, col = -1) =
  var e: ref EInvalidPeg
  new(e)
  e.msg = errorStr(p, msg, line, col)
  raise e

proc getTok(p: var PegParser) =
  getTok(p, p.tok)
  if p.tok.kind == tkInvalid: pegError(p, "'" & p.tok.literal & "' is invalid token")

proc eat(p: var PegParser, kind: TokKind) =
  if p.tok.kind == kind: getTok(p)
  else: pegError(p, tokKindToStr[kind] & " expected")

proc parseExpr(p: var PegParser): Peg {.gcsafe.}

proc getNonTerminal(p: var PegParser, name: string): NonTerminal =
  for i in 0..high(p.nonterms):
    result = p.nonterms[i]
    if cmpIgnoreStyle(result.name, name) == 0: return
  # forward reference:
  result = newNonTerminal(name, getLine(p), getColumn(p))
  add(p.nonterms, result)

proc modifiedTerm(s: string, m: Modifier): Peg =
  case m
  of modNone, modVerbatim: result = term(s)
  of modIgnoreCase: result = termIgnoreCase(s)
  of modIgnoreStyle: result = termIgnoreStyle(s)

proc modifiedBackref(s: int, m: Modifier): Peg =
  case m
  of modNone, modVerbatim: result = backref(s)
  of modIgnoreCase: result = backrefIgnoreCase(s)
  of modIgnoreStyle: result = backrefIgnoreStyle(s)

proc builtin(p: var PegParser): Peg =
  # do not use "y", "skip" or "i" as these would be ambiguous
  case p.tok.literal
  of "n": result = newLine()
  of "d": result = charSet({'0'..'9'})
  of "D": result = charSet({'\1'..'\xff'} - {'0'..'9'})
  of "s": result = charSet({' ', '\9'..'\13'})
  of "S": result = charSet({'\1'..'\xff'} - {' ', '\9'..'\13'})
  of "w": result = charSet({'a'..'z', 'A'..'Z', '_', '0'..'9'})
  of "W": result = charSet({'\1'..'\xff'} - {'a'..'z','A'..'Z','_','0'..'9'})
  of "a": result = charSet({'a'..'z', 'A'..'Z'})
  of "A": result = charSet({'\1'..'\xff'} - {'a'..'z', 'A'..'Z'})
  of "ident": result = extpegs.ident
  of "letter": result = unicodeLetter()
  of "upper": result = unicodeUpper()
  of "lower": result = unicodeLower()
  of "title": result = unicodeTitle()
  of "white": result = unicodeWhitespace()
  else: pegError(p, "unknown built-in: " & p.tok.literal)

proc token(terminal: Peg, p: PegParser): Peg =
  if p.skip.kind == pkEmpty: result = terminal
  else: result = sequence(p.skip, terminal)

proc primary(p: var PegParser): Peg =
  case p.tok.kind
  of tkAmp:
    getTok(p)
    return &primary(p)
  of tkNot:
    getTok(p)
    return !primary(p)
  of tkAt:
    getTok(p)
    return !*primary(p)
  of tkCurlyAt:
    getTok(p)
    return !*\primary(p).token(p)
  else: discard
  case p.tok.kind
  of tkIdentifier:
    if p.identIsVerbatim:
      var m = p.tok.modifier
      if m == modNone: m = p.modifier
      result = modifiedTerm(p.tok.literal, m).token(p)
      getTok(p)
    elif not arrowIsNextTok(p):
      var nt = getNonTerminal(p, p.tok.literal)
      incl(nt.flags, ntUsed)
      result = nonterminal(nt).token(p)
      getTok(p)
    else:
      pegError(p, "expression expected, but found: " & p.tok.literal)
  of tkStringLit:
    var m = p.tok.modifier
    if m == modNone: m = p.modifier
    result = modifiedTerm(p.tok.literal, m).token(p)
    getTok(p)
  of tkCharSet:
    if '\0' in p.tok.charset:
      pegError(p, "binary zero ('\\0') not allowed in character class")
    result = charSet(p.tok.charset).token(p)
    getTok(p)
  of tkParLe:
    getTok(p)
    result = parseExpr(p)
    eat(p, tkParRi)
  of tkCurlyLe:
    getTok(p)
    result = capture(parseExpr(p)).token(p)
    eat(p, tkCurlyRi)
    inc(p.captures)
  of tkAny:
    result = any().token(p)
    getTok(p)
  of tkAnyRune:
    result = anyRune().token(p)
    getTok(p)
  of tkBuiltin:
    result = builtin(p).token(p)
    getTok(p)
  of tkEscaped:
    result = term(p.tok.literal[0]).token(p)
    getTok(p)
  of tkDollar:
    result = endAnchor()
    getTok(p)
  of tkHat:
    result = startAnchor()
    getTok(p)
  of tkBackref:
    var m = p.tok.modifier
    if m == modNone: m = p.modifier
    result = modifiedBackref(p.tok.index, m).token(p)
    if p.tok.index < 0 or p.tok.index > p.captures:
      pegError(p, "invalid back reference index: " & $p.tok.index)
    getTok(p)
  else:
    pegError(p, "expression expected, but found: " & p.tok.literal)
    getTok(p) # we must consume a token here to prevent endless loops!
  while true:
    case p.tok.kind
    of tkOption:
      result = ?result
      getTok(p)
    of tkStar:
      result = *result
      getTok(p)
    of tkPlus:
      result = +result
      getTok(p)
    else: break

proc seqExpr(p: var PegParser): Peg =
  result = primary(p)
  while true:
    case p.tok.kind
    of tkAmp, tkNot, tkAt, tkStringLit, tkCharSet, tkParLe, tkCurlyLe,
       tkAny, tkAnyRune, tkBuiltin, tkEscaped, tkDollar, tkBackref,
       tkHat, tkCurlyAt:
      result = sequence(result, primary(p))
    of tkIdentifier:
      if not arrowIsNextTok(p):
        result = sequence(result, primary(p))
      else: break
    else: break

proc parseExpr(p: var PegParser): Peg =
  result = seqExpr(p)
  while p.tok.kind == tkBar:
    getTok(p)
    result = result / seqExpr(p)

proc parseRule(p: var PegParser): NonTerminal =
  if p.tok.kind == tkIdentifier and arrowIsNextTok(p):
    result = getNonTerminal(p, p.tok.literal)
    if ntDeclared in result.flags:
      pegError(p, "attempt to redefine: " & result.name)
    result.line = getLine(p)
    result.col = getColumn(p)
    getTok(p)
    eat(p, tkArrow)
    result.rule = parseExpr(p)
    incl(result.flags, ntDeclared) # NOW inlining may be attempted
  else:
    pegError(p, "rule expected, but found: " & p.tok.literal)

proc rawParse(p: var PegParser): Peg =
  ## parses a rule or a PEG expression
  while p.tok.kind == tkBuiltin:
    case p.tok.literal
    of "i":
      p.modifier = modIgnoreCase
      getTok(p)
    of "y":
      p.modifier = modIgnoreStyle
      getTok(p)
    of "skip":
      getTok(p)
      p.skip = ?primary(p)
    else: break
  if p.tok.kind == tkIdentifier and arrowIsNextTok(p):
    result = parseRule(p).rule
    while p.tok.kind != tkEof:
      discard parseRule(p)
  else:
    p.identIsVerbatim = true
    result = parseExpr(p)
  if p.tok.kind != tkEof:
    pegError(p, "EOF expected, but found: " & p.tok.literal)
  for i in 0..high(p.nonterms):
    var nt = p.nonterms[i]
    if ntDeclared notin nt.flags:
      pegError(p, "undeclared identifier: " & nt.name, nt.line, nt.col)
    elif ntUsed notin nt.flags and i > 0:
      pegError(p, "unused rule: " & nt.name, nt.line, nt.col)

proc parsePeg*(pattern: string, filename = "pattern", line = 1, col = 0): Peg =
  ## constructs a Peg object from `pattern`. `filename`, `line`, `col` are
  ## used for error messages, but they only provide start offsets. `parsePeg`
  ## keeps track of line and column numbers within `pattern`.
  var p: PegParser
  init(PegLexer(p), pattern, filename, line, col)
  p.tok.kind = tkInvalid
  p.tok.modifier = modNone
  p.tok.literal = ""
  p.tok.charset = {}
  p.nonterms = @[]
  p.identIsVerbatim = false
  getTok(p)
  result = rawParse(p)

proc peg*(pattern: string): Peg =
  ## constructs a Peg object from the `pattern`. The short name has been
  ## chosen to encourage its use as a raw string modifier::
  ##
  ##   peg"{\ident} \s* '=' \s* {.*}"
  result = parsePeg(pattern, "pattern")

proc escapePeg*(s: string): string =
  ## escapes `s` so that it is matched verbatim when used as a peg.
  result = ""
  var inQuote = false
  for c in items(s):
    case c
    of '\0'..'\31', '\'', '"', '\\':
      if inQuote:
        result.add('\'')
        inQuote = false
      result.add("\\x")
      result.add(toHex(ord(c), 2))
    else:
      if not inQuote:
        result.add('\'')
        inQuote = true
      result.add(c)
  if inQuote: result.add('\'')

when isMainModule:
  assert escapePeg("abc''def'") == r"'abc'\x27\x27'def'\x27"
  assert match("(a b c)", peg"'(' @ ')'")
  assert match("W_HI_Le", peg"\y 'while'")
  assert(not match("W_HI_L", peg"\y 'while'"))
  assert(not match("W_HI_Le", peg"\y v'while'"))
  assert match("W_HI_Le", peg"y'while'")

  assert($ +digits == $peg"\d+")
  assert "0158787".match(peg"\d+")
  assert "ABC 0232".match(peg"\w+\s+\d+")
  assert "ABC".match(peg"\d+ / \w+")

  var accum: seq[string] = @[]
  for word in split("00232this02939is39an22example111", peg"\d+"):
    accum.add(word)
  assert(accum == @["this", "is", "an", "example"])

  assert matchLen("key", ident) == 3

  var pattern = sequence(ident, *whitespace, term('='), *whitespace, ident)
  assert matchLen("key1=  cal9", pattern) == 11

  var ws = newNonTerminal("ws", 1, 1)
  ws.rule = *whitespace

  var expr = newNonTerminal("expr", 1, 1)
  expr.rule = sequence(capture(ident), *sequence(
                nonterminal(ws), term('+'), nonterminal(ws), nonterminal(expr)))

  var c: Captures
  var s = "a+b +  c +d+e+f"
  assert rawMatch(s, expr.rule, 0, c) == len(s)
  var a = ""
  for i in 0..c.ml-1:
    a.add(substr(s, c.matches[i][0], c.matches[i][1]))
  assert a == "abcdef"
  #echo expr.rule

  #const filename = "lib/devel/peg/grammar.txt"
  #var grammar = parsePeg(newFileStream(filename, fmRead), filename)
  #echo "a <- [abc]*?".match(grammar)
  assert find("_____abc_______", term("abc"), 2) == 5
  assert match("_______ana", peg"A <- 'ana' / . A")
  assert match("abcs%%%", peg"A <- ..A / .A / '%'")

  var matches: array[0..MaxSubpatterns-1, string]
  if "abc" =~ peg"{'a'}'bc' 'xyz' / {\ident}":
    assert matches[0] == "abc"
  else:
    assert false

  var g2 = peg"""S <- A B / C D
                 A <- 'a'+
                 B <- 'b'+
                 C <- 'c'+
                 D <- 'd'+
              """
  assert($g2 == "((A B) / (C D))")
  assert match("cccccdddddd", g2)
  assert("var1=key; var2=key2".replacef(peg"{\ident}'='{\ident}", "$1<-$2$2") ==
         "var1<-keykey; var2<-key2key2")
  assert("var1=key; var2=key2".replace(peg"{\ident}'='{\ident}", "$1<-$2$2") ==
         "$1<-$2$2; $1<-$2$2")
  assert "var1=key; var2=key2".endsWith(peg"{\ident}'='{\ident}")

  if "aaaaaa" =~ peg"'aa' !. / ({'a'})+":
    assert matches[0] == "a"
  else:
    assert false

  if match("abcdefg", peg"c {d} ef {g}", matches, 2):
    assert matches[0] == "d"
    assert matches[1] == "g"
  else:
    assert false

  accum = @[]
  for x in findAll("abcdef", peg".", 3):
    accum.add(x)
  assert(accum == @["d", "e", "f"])

  for x in findAll("abcdef", peg"^{.}", 3):
    assert x == "d"

  if "f(a, b)" =~ peg"{[0-9]+} / ({\ident} '(' {@} ')')":
    assert matches[0] == "f"
    assert matches[1] == "a, b"
  else:
    assert false

  assert match("eine übersicht und außerdem", peg"(\letter \white*)+")
  # ß is not a lower cased letter?!
  assert match("eine übersicht und auerdem", peg"(\lower \white*)+")
  assert match("EINE ÜBERSICHT UND AUSSERDEM", peg"(\upper \white*)+")
  assert(not match("456678", peg"(\letter)+"))

  assert("var1 = key; var2 = key2".replacef(
    peg"\skip(\s*) {\ident}'='{\ident}", "$1<-$2$2") ==
         "var1<-keykey;var2<-key2key2")

  assert match("prefix/start", peg"^start$", 7)

  if "foo" =~ peg"{'a'}?.*":
    assert matches[0] == nil
  else: assert false

  if "foo" =~ peg"{''}.*":
    assert matches[0] == ""
  else: assert false

  if "foo" =~ peg"{'foo'}":
    assert matches[0] == "foo"
  else: assert false

  let empty_test = peg"^\d*"
  let str = "XYZ"

  assert(str.find(empty_test) == 0)
  assert(str.match(empty_test))

  proc handleMatches*(m: int, n: int, c: openArray[string]): string =
    result = ""

    if m > 0:
      result.add ", "

    result.add case n:
      of 2: toLowerAscii(c[0]) & ": '" & c[1] & "'"
      of 1: toLowerAscii(c[0]) & ": ''"
      else: ""

  assert("Var1=key1;var2=Key2;   VAR3".
         replace(peg"{\ident}('='{\ident})* ';'* \s*",
         handleMatches)=="var1: 'key1', var2: 'Key2', var3: ''")


  doAssert "test1".match(peg"""{@}$""")
  doAssert "test2".match(peg"""{(!$ .)*} $""")