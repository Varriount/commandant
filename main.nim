import commandant/[parser, lexer, treeutils, vm]
import strformat, strutils
import rdstdin

when defined(release):
  # Handle CTRL-C
  proc handleQuit() {.noconv.}=
    stdout.write("\n")
    quit(0)

  setControlCHook(handleQuit)


proc main() =
  var
    parser: Parser
    vm = newCommandantVm()

  initParser(parser)

  var line = ""
  while true:
    # Print the prompt, then gather the AST from the parser
    let breakLoop = not readLineFromStdin("> ", line)
    if breakLoop:
      echo "Unable to read from stdin"
      break

    # Strip whitespace
    line = line.strip()
    if line == "":
      continue

    # Parse the line
    var nodes = parse(parser, line)
    if parser.errorFound:
      parser.errorFound = false
      continue

    # Execute the line if no error was encountered during the parse.
    # echo nodeRepr(nodes)
    vm.execNode(nodes)
      

main()