
# # # # # # import regex

# # # # # # const
# # # # # #   varRegex = toPattern("\\$([^ \\t]+)")
# # # # # #   input = "Hello $world how are you $today ?"

# # # # # # for match in findAll(input, varRegex):
# # # # # #   for g in group(match, 0):
# # # # # #     echo repr(g)

# # # # # import osproc, os

# # # # # let x = startProcess(findExe("nim"))
# # # # # discard waitForExit(x)

# # # # close(stdout)

# # # proc main =
# # #   let
# # #     c = 'h'
# # #     cs = {'e', 'y'}
# # #   if c notin cs and c notin {'_'}:
# # #     echo c

# # # main()
# # import sequtils

# # const validRanges = mapLiterals([
# #     48 .. 58,
# #     64 .. 73,
# #     73 .. 79,
# #     79 .. 91,
# #     96 .. 108,
# #     108 .. 123,
# # ], char)

# # for s in validRanges:
# #   echo repr s
# #   echo (char(50) in s)

# template twice(a: untyped) =
#   a
#   a

# twice(echo "hello")

import macros

proc rewritePowerOp(node: NimNode): NimNode =
    let funcIdent = node[1]
    let repeatLit = node[2][0]
    echo funcIdent
    expectKind(repeatLit, nnkIntLit)
    let call = newCall(funcIdent)
    for i in 1 ..< node[2].len:
        call.add(node[2][i])
    let stmts = newStmtList()
    for i in 1 .. repeatLit.intVal:
        let stmt = newNimNode(nnkDiscardStmt, node)
        stmt.add(call)
        stmts.add(stmt)
    result = newBlockStmt(stmts)

proc findPowerOp(node: NimNode): NimNode =
    if node.len < 1:
        result = node
    else:
        result = node
        for i in 0 ..< node.len:
            echo node[i].kind
            case node[i].kind
            of nnkInfix:
                case node[i][0].kind
                of nnkIdent:
                    if $result[i][0] == "^":
                        result[i] = rewritePowerOp(node[i])
                else:
                    result[i] = findPowerOp(node[i])
            else:
                result[i] = findPowerOp(node[i])
    
macro altPowerSyntax(body: untyped): untyped =
    return findPowerOp(body)
    
proc hexThingy(hex: string): string =
    echo "hexify side effect"
    return "hexify!"

proc foo(bar: int): int =
    echo "another function"
    return bar
    
altPowerSyntax:
    hexThingy^4("hi")
    foo^3(42)
    