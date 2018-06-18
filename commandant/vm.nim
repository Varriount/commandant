import tables, parser

type
  VariableFrame* = Table[string, seq[AstNode]]
  CommandantVm* = ref object
    variables*: VariableFrame


proc newCommandantVm(): CommandantVm =
  new(result)
  result.variables = initTable[string, seq[AstNode]]()

