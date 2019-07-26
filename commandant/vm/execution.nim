{.experimental: "codeReordering".}
import ".." / subprocess

proc execNode(vm: VM, node: Node, pipes: CommandPipes): Job
proc execSeperator(vm: VM, node: Node, pipes: CommandPipes): Job
proc execCommand(vm: VM, node: Node, pipes: CommandPipes): Job


# ## Execution Procedures ## #
iterator resolveCommandSub(vm: VM, node: Node, pipes: CommandPipes): char =
  # Setup the pipes
  var
    connectingPipe = initPipe()
    subPipes       = duplicate(pipes)

  defer:
    close(connectingPipe)
    close(subPipes)

  swap(subPipes.output.writeEnd, connectingPipe.writeEnd)

  # Spawn the subprocess
  var job = execCommand(vm, node.children[0], subPipes)
  close(subPipes.output.writeEnd)

  # Read the output
  var buffer = ""
  for character in read(connectingPipe.readEnd):
    if character in {'\c', '\l'}:
      buffer.add(character)
      continue

    for character in buffer:
      yield character
    setLen(buffer, 0)
    yield character
  
  wait(vm, job)


iterator resolveVariableSub(vm: VM, node: Node, pipes: CommandPipes): string =
  let
    variableWord = node.children[0].token.data
    variableOpt  = getVar(vm, variableWord)

  if not isNone(variableOpt):
    let variable = variableOpt.get()

    for element in variable:
      yield element


proc resolveString(vm: VM, node: Node, pipes: CommandPipes, result: var string) =
  for child in node.children:
    case child.kind
    of NKStringData:
      add(result, child.token.data)

    of NKVariableSub:
      for piece in resolveVariableSub(vm, child, pipes):
        result.add(piece)
        result.add(' ')
      setLen(result, high(result))

    of NKCommandSub:
      for character in resolveCommandSub(vm, child, pipes):
        result.add(character)

    else:
      raise newException(Exception, fmt"Bad node: {child.kind}")


proc execNode(vm: VM, node: Node, pipes: CommandPipes): Job =
  case node.kind
  of NKCommand, NKStatement:
    result = execCommand(vm, node, pipes)
  of NKSeperator:
    result = execSeperator(vm, node, pipes)
  else:
    raise newException(Exception, fmt"Bad node: {node.kind}")


proc execSeperator(vm: VM, node: Node, pipes: CommandPipes): Job =
  case node.token.data
  of "&&":
    result = execNode(vm, node.children[0], pipes)
    vm.wait(result)
    if result.exitCode == 0:
      result = execNode(vm, node.children[1], pipes)

  of "||":
    result = execNode(vm, node.children[0], pipes)
    vm.wait(result)
    if result.exitCode != 0:
      discard execNode(vm, node.children[1], pipes)

  of ";":
    discard execNode(vm, node.children[0], pipes)
    discard execNode(vm, node.children[1], pipes)

  of "|":
    var 
      leftPipes      = duplicate(pipes)
      rightPipes     = duplicate(pipes)
      connectingPipe = initPipe()

    defer:
      close(leftPipes)
      close(rightPipes)
      close(connectingPipe)

    swap(leftPipes.output.writeEnd, connectingPipe.writeEnd)
    swap(rightPipes.input.readEnd, connectingPipe.readEnd)
    close(connectingPipe)
    
    discard execNode(vm, node.children[0], leftpipes)
    close(leftPipes)

    result = execNode(vm, node.children[1], rightpipes)
    close(rightPipes)
  else:
    raise newException(Exception, "Bad seperator")


proc execCommand(vm: VM, node: Node, pipes: CommandPipes): Job =
  var
    arguments = newSeq[string]()
    pipes     = duplicate(pipes)

  defer: close(pipes)

  var unlinked = true
  for index, child in node.children:
    if unlinked:
      arguments.add("")
    let removeIfEmpty = unlinked
    unlinked = child.unlinked

    case child.kind
    of NKWord:
      arguments[^1].add(child.token.data)

    of NKString:
      resolveString(vm, child, pipes, arguments[^1])

    of NKCommandSub:
      for character in resolveCommandSub(vm, child, pipes):
        if character in {' ', '\c', '\l', '\t'}:
          if arguments[^1] != "":
            arguments.add("")
        else:
          arguments[^1].add(character)

      if removeIfEmpty and arguments[^1] == "":
        setLen(arguments, high(arguments))

    of NKVariableSub:
      for piece in resolveVariableSub(vm, child, pipes):
        arguments[^1].add(piece)
        arguments.add("")
      if unlinked:
        arguments.setLen(high(arguments))

      if removeIfEmpty and arguments[^1] == "":
        arguments.setLen(high(arguments))

    of NKRedirect:
      modRedirect(vm, child, pipes)

    of NKBody:
      continue
    else:
      raise newException(Exception, fmt"Bad node: {child.kind}")

  case node.kind
  of NKCommand:
    callCommand(vm, arguments, pipes)
  of NKStatement:
    callStatement(vm, arguments, node.children[^1].children, pipes)
  else:
    raise newException(Exception, fmt"Bad node: {node.kind}")


proc modRedirect(vm: VM, node: Node, pipes: var CommandPipes) =
  template openTarget(mode): auto =
    let
      accessMode = (
        S_IRUSR or S_IWUSR or
        S_IRGRP or S_IWGRP or
        S_IROTH or S_IWOTH
      )

      target = node.children[0].token.data
      fd = posix.open(target, mode, accessMode)

    if fd == -1:
      raiseOSError(osLastError())
    PipeEnd(fd)

  case node.token.data
  # Set input to file
  of "<":  
    let targetFd = openTarget(O_RDONLY)
    close(pipes.input.readEnd)
    pipes.input.readEnd = targetFd

  # Set output to file (write)
  of ">":  
    let targetFd = openTarget(O_WRONLY or O_CREAT or O_TRUNC)
    close(pipes.output.writeEnd)
    pipes.output.writeEnd = targetFd

  # Set output to file (append)
  of ">>": 
    let targetFd = openTarget(O_WRONLY or O_CREAT or O_APPEND)
    close(pipes.output.writeEnd)
    pipes.output.writeEnd = targetFd

  # Set errput to file (write)
  of "!>": 
    let targetFd = openTarget(O_WRONLY or O_CREAT or O_TRUNC)
    close(pipes.errput.writeEnd)
    pipes.errput.writeEnd = targetFd

  # Set errput to file (append)
  of "!>>":
    let targetFd = openTarget(O_WRONLY or O_CREAT or O_APPEND)
    close(pipes.errput.writeEnd)
    pipes.errput.writeEnd = targetFd

  # Set output and errput to file (write)
  of "&>": 
    let targetFd = openTarget(O_WRONLY or O_CREAT or O_TRUNC)
    close(pipes.output.writeEnd)
    pipes.output.writeEnd = targetFd
    close(pipes.errput.writeEnd)
    pipes.errput.writeEnd = targetFd

  # Set output and errput to file (append)
  of "&>>":
    let targetFd = openTarget(O_WRONLY or O_CREAT or O_APPEND)
    close(pipes.output.writeEnd)
    pipes.output.writeEnd = targetFd
    close(pipes.errput.writeEnd)
    pipes.errput.writeEnd = targetFd

  else:
    raise newException(
      Exception,
      "Invalid redirection operator: {node.token.data}."
    )
