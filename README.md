# commandant #
A command-oriented command shell

Note: This was mainly created for learning purposes. I wanted to see how far
I could go with the "everything is a command" approach.

If you have questions about the implementation, want to improve it, etc., 
feel free to either submit an issue, or contact me on the [Gitter/IRC/Discord
Nim community](https://github.com/nim-lang/Nim#community)


## Motivation ##
The commandant shell language was designed based on this stream of reasoning:
  - Other shell languages, while powerful, often have useful capabilities
    hidden behind odd or obscure syntax.
  - Thus, a better shell language might be one where all the capabilities of
    the language are expressed through a familier, often used construct.
  - Since the most often used language construct in a command shell is a
    command, why not make as many syntactic constructs as possible behave like
    ordinary commands?
  - Also, stringly typed variables are so limiting. Lets use proper arrays
    instead.


## Language ##
In the context of this document, a "command" is defined as a string of 
arguments separated by whitespace characters. 

Each argument in a command falls into one of six categories:

  - **Redirection Expression**  
    An expression consisting of a redirection operator, followed by a string or
    word describing the file to use for the redirection.  
    *Example*:
      ```
      echo hello world > "output.log"
      ```
    Available output operators:
    - `< `: Redirect standard input to the given file.
    - `> `: Redirect standard output to the given file.
            Creates the file if it doesn't exist, otherwise the file is
            truncated upon opening.
    - `>>`: Redirect standard input to the given file.
            Creates the file if it doesn't exist, however if the file already
            exists, it is appended to.
    - `!>`: The same as `>`, however standard error is redirected, rather than
            standard output.
    - `!>>`: The same as `>>`, however standard error is redirected, rather
             than standard output.
    - `&>`: The same as `>`, however both standard output and standard error
            are redirected.
    - `&>>`: The same as `>>`, however both standard output and standard error
             are redirected.

  - **Variable Substitution**  
    A word surrounded by a pair of double-nested square braces. May occur both
    alone and inside a string.

    The data associated with the variable named inside the square brackets will
    be retrieved. If the variable substitution occurs alone, each element of
    the variable's data will then be inserted as a seperate argument into the
    surrounding command. If the variable substitution occurs within a string,
    each element of the variable's data will be joined by a space, then
    inserted directly into the string's text.

    *Example*:
      ```
      echo [[variable_containing_hello_world]]
      echo hello "[[variable_containing_world]]"
      ```

  - **Command Substitution**  
    A command surrounded by a pair doubly-nested parenthesis. May occur both
    alone and inside a string.

    The command within the parenthesis will be run and the output captured. If
    the command substitution occurs alone, the output will be split into
    arguments as if the output had been directly written as part of the 
    command.
    If the command substitution occurs within a string, the output will be
    directly inserted into the string's text.

    *Example*: 
      ```
      echo ((echo hello world))
      echo hello "((echo world))"
      ```

  - **String**  
    A consecutive run of characters surrounded by a pair of either 
    single-quotes or double-quotes. 

    *Example*:
      ```
      echo hello world > "output.log"
      ```

  - **Word**  
    A run of characters that are not spaces, nor command substitions, variables
    substitutions, or strings.

    *Example*:
      ```
      echo hello world
      ```

Note that the lexical and parsing phases do not define language elements such
as `if`, statements, function definitions, etc. This is because such elements
are defined as built-in commands, rather than specific syntactic structures.


## VM ##

### Builtins ###
Commandant has two kinds of built-in commands: intrinsic commands and statement
commands.
Each kind of built-in command is implemented as a function that the VM calls
when the first argument of an input matches the built-in command's name.


#### Intrinsic Commands ####
Intrinsic commands behave almost exactly like normally invoked commands, with
the exception that they can directly read and modify the shell state.

An intrinsic command recieves the following pieces of data:
  - A reference to the VM that invoked the command.
  - The list of arguments that were used to invoke the command (including the
    name of the command itself).
  - The input/output/error streams.

Commandant currently has the following intrinsic commands:

  - **Echo**  
    Echo arguments.
    
    Syntax: `echo [<x>...]`

  - **Set**  
    Set a variable's value.
    
    Syntax: `set <x> = <y> ... <z>`

  - **Unset**  
    Unset a variable.
    
    Syntax: `unset <x> ... <z>`

  - **Export**  
    Export and set a variable.
    
    Syntax: `export x [ = <y> ... <z> ]`

  - **Unexport**  
    Unexport a variable.
    
    Syntax: `unexport x`
    
  - **Delete**  
    Delete an element from a variable.
    If the given index doesn't exist, the variable will remain 
    unchanged.
    
    Syntax: `delete <x> from <z>`
    
  - **Insert**  
    Insert an element into a variable.
    
    Syntax: `insert <x> into <y> at <z>`
    
  - **Add**  
    Add an element to a variable.
    
    Syntax: `add <x> to <y>`

  
#### Statement Commands ####
Statement commands are used for language constructs that are represented as
"blocks" of commands. They are comprised of three parts: a prelude command 
(such as `if x then`) a body containing a number of arbitrary commands, and an 
"end" command Statements may be nested, and in some cases (such as functions) 
the body of  statement may be stored for later use rather than run immediately.

Due to these constraints, the VM must be able to determine the start and end of
the statement without evaluating it's block of commands. This means that
statement commands may not be chained with other commands.

Statement commands receive the same pieces of data as intrinsic commands, plus 
a list of commands that make up the statement command's "body".

Commandant currently has the following statement commands:

  - **If**  
    Conditionally execute a block of commands.
    
    Syntax: `if <command> then`

  - **While**  
    Repeatedly execute a block of commands while a particular command is true.
    
    Syntax: `while <command> do`

  - **Define**  
    Define a function.
    
    Syntax: `define <x> =`


### Functions ###
The VM currently has basic support for functions. Functions act like commands -
they recieve a list of arguments, have a set of IO streams, and return an exit
code.
Function arguments are stored in a local `args` variable, and the exit code of 
a function is the exit code of its last command.

Internally, function definitions are stored as an array of abstract syntax
tree nodes, with each node in the array representing a command. A hash map then
maps strings (function names) to this array. To support execution of functions,
the VM maintains a dynamically-sized array of frame objects, with each frame
object containing the information required to execute a function, such as the
instruction pointer, the map of local variables, etc. 


## Version 2 Changes ##
As of version 2, nearly all of Commandants core logic has been rewritten. NPeg 
library is now used to tokenize input in the lexer, and the parsing logic has 
been greatly expanded to support new language constructs. Process creation now 
makes use of posix_spawn, rather than `execCommand` from the standard library. 
As a consequence of this, process input/output/error stream handling is much 
improved.

## Notes:
This project was mainly about learning how command shells ran. I learned quite
a bit about parsers (such as the different methods for implementing operator
precedence) as well as how bash works internally. Some of the key implementation
difference I made from bash was using dynamic arrays, instead of linked lists.


# Compilation Instructions #
This program requires the development version of [Nim](https://github.com/nim-lang/Nim).

```
# Download development branch
git clone --depth 1 https://github.com/nim-lang/Nim.git
cd Nim

# Build Nim
bash build_all.sh
export PATH=$PATH:$(pwd)/bin

cd ..
git clone https://github.com/varriount/commandant.git
cd commandant
nimble install npeg
nim c -d:release --stacktrace:on --linetrace:on main.nim
mv main commandant
```

You may then symlink the resulting executable into your bin directory.
