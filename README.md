# commandant #
A command-oriented command shell

# Motivation
The commandant shell language was designed based on this stream of reasoning:
  - Other shell languages, while powerful, often have useful capabilities hidden
    behind odd or obscure syntax.
  - Thus, a better shell language might be one where all the capabilities of
    the language are expressed through a familier, often used construct.
  - Since the most often used language construct in a command shell is a
    command, why not make as many syntactic constructs as possible behave like
    ordinary commands?
  - Also, stringly typed variables are so limiting. Lets use proper arrays
    instead.


# Language
In the context of this document, a "command" is defined as a string of arguments
separated by whitespace characters. Each argument is either a string (a run of
characters surrounded by double-quotes) or a word (any other run of
non-whitespace characters). Words may be further specialized into either
separators, which chain commands, and redirections, which modify the standard
IO streams an invoked command uses.

Commandant's lexical pass is fairly simple, using the following PEG grammer:
```
token            <- strToken / seperator / redirection / word
wordToken        <- [A-Za-z0-9_]+
strToken         <- ('"' (BACKSLASH . / [^'"'])* '"')
separatorToken   <- ";" / "&&" / "||"
redirectionToken <- ">" | ">>" | "!>" | "!>>" | "<"
```

The parsing grammer is also simple:
```
start        <- multicommand / command
multicommand <- command separatorToken command
redirection  <- redirectionToken ( wordToken / stringToken )
command      <- ( redirection / wordToken )+
```

Note that this grammer doesn't define language elements such as conditionals,
variable setting, and control-flow constructs. The VM handles these contructs
itself, using a series of built-in command handlers.


# The VM #

## Builtins ##
Commandant has two kinds of built-in commands, intrinsic commands and statements.
Each kind of built-in command is implemented as a function that the VM calls
when the first argument of an input matches the built-in command's name.


#### Intrinsic Commands ####
Intrinsic commands behave almost exactly like normally invoked commands.
Intrinsic Commands receive approximately the same amount of information when
invoked, along with a reference to the virtual machine. 

A command builtin function recieves the following pieces of data:
  - A reference to the VM that invoked the command.
  - The "executable" of the command, which is the first word or string token
    parsed on the line.
  - The other arguments that were invoked with the command.
  - The streams that the command is using for standard IO.

Examples of command builtins include "set", to set a variable, and "export", to
export a variable into the environment of invoked commands.
  
#### Statement Commands ####
Statement commands are used for language constructs that are represented as
"blocks" of commands. They typically start with some form of prelude command,
contain a number of arbitrary commands, then end with the "end" command.
Statements may be nested, and in some cases (such as functions) the body of a
statement may be stored in the VM rather than run immediately.

Due to these constraints, the VM must be able to determine the start and end of
the statement without evaluating it's block of commands. This means that
statement commands may not be chained with other commands.

Statement builtins are used to implement "if" and "while" statements, as well
as functions.


# Functions #
The VM currently has basic support for functions. Functions act like commands -
they recieve a list of arguments, have a set of IO streams, and return an exit
code.

Internally, function definitions are stored as an array of abstract syntax
tree nodes, with each node in the array representing a command. A hash map then
maps strings (function names) to this array. To support execution of functions,
the VM maintains a dynamically-sized array of frame objects, with each frame
object containing the information required to execute a function, such as the
instruction pointer, the map of local variables, etc.


# Variables #
Commandant variables are arrays of strings, rather than just strings.
They can be set using the "set" command.

Variable substitution is performed by using the expressions `$var` or
`$var[index]`. Using `$var` will concatenate all the elements in the array before
substitution, while $var[x] will substitute only that element.


Notes:

This project was mainly about learning how command shells ran. I learned quite
a bit about parsers (such as the different methods for implementing operator
precedence) as well as how bash works internally. Some of the key implementation
difference I made from bash was using dynamic arrays, instead of linked lists.