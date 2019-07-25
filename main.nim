import strformat, strutils, rdstdin
import commandant/[vm/vm, parser, lexer]

when defined(release):
  # Handle CTRL-C
  proc handleQuit() {.noconv.}=
    stdout.write("\n")
    quit(0)

  setControlCHook(handleQuit)


# proc main() =
#   var lexer = newLexer()

#   var line = ""
#   while true:
#     # Print the prompt, then gather the AST from the parser
#     let breakLoop = not readLineFromStdin("> ", line)
#     if breakLoop:
#       break

#     # Strip whitespace
#     line = line.strip()
#     if line == "":
#       continue

#     # Parse the line
#     lexer.resetLexer()
#     lexer.lex(line)
#     var nodes = parseCommands(lexer)
#     nodeRepr(nodes)

proc main =
  proc getInput(vm: VM, output: var string): bool =
    result = readLineFromStdin("> ", output)

  var vm = newVm(getInput)
  vm.run()

main()