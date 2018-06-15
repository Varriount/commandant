import commandant/[parser, lexer, treeutils]
import strformat
import strutils


when defined(release):
  # Handle CTRL-C
  proc handleQuit() {.noconv.}=
    stdout.write("\n")
    quit(0)

  setControlCHook(handleQuit)


proc main() =
  var parser: Parser
  initParser(parser)

  while true:
    # Print the prompt, then gather the AST from the parser
    stdout.write("> ")
    
    var nodes = parse(parser, readLine(stdin))
    echo stringRepr(nodes)

main()