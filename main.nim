import commandant/parser
import strformat

proc main() =
  var parser: Parser
  initParser(parser)

  while true:
    # Print the prompt, then reset the lexer with the next line typed in.
    stdout.write("> ")
    
    # Emulate bash handling of multi-line commands
    # Read the last token of the input line for an escape
    var nodes = parse(parser, readLine(stdin))
    echo repr(nodes)

main()