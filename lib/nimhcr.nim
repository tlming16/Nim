#
#
#            Nim's Runtime Library
#        (c) Copyright 2018 Nim Contributors
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## This is the Nim hot code reloading run-time for the native targets.
##
## This minimal dynamic library is not subject to reloading when the
## `hotCodeReloading` build mode is enabled. It's responsible for providing
## a permanent memory location for all globals and procs within a program
## and orchestrating the reloading. For globals, this is easily achieved
## by storing them on the heap. For procs, we produce on the fly simple
## trampolines that can be dynamically overwritten to jump to a different
## target. In the host program, all globals and procs are first registered
## here with ``registerGlobal`` and ``registerProc`` and then the returned
## permanent locations are used in every reference to these symbols onwards.

discard """

== Detailed description:

When code is compiled with the hotCodeReloading option for native targets
a couple of things happen for all modules in a project:
- the useNimRtl option is forced (including when building the HCR runtime too)
- all modules of a target get built into separate shared libraries
  - the smallest granularity of reloads is modules
  - for each .c (or .cpp) in the corresponding nimcache folder of the project
    a shared object is built with the name of the source file + DLL extension
  - only the main module produces whatever the original project type intends
    (again in nimcache) and is then copied to its original destination
  - linking is done in parallel - just like compilation
- function calls to functions from the same project go through function pointers:
  - with a few exceptions - see the nonReloadable pragma
  - the forward declarations of the original functions become function
    pointers as static globals with the same names
  - the original function definitions get prefixed with <name>_actual
  - the function pointers get initialized with the address of the corresponding
    function in the DatInit of their module through a call to either registerProc
    or getProc. When being registered, the <name>_actual address is passed to
    registerProc and a permanent location is returned and assigned to the pointer.
    This way the implementation (<name>_actual) can change but the address for it
    will be the same - this works by just updating a jump instruction (trampoline).
    For functions from other modules getProc is used (after they are registered).
- globals are initialized only once and their state is preserved
  - including locals with the {.global.} pragma
  - their definitions are changed into pointer definitions which are initialized
    in the DatInit() of their module with calls to registerGlobal (supplying the
    size of the type that this HCR runtime should allocate) and a bool is returned
    which when true triggers the initialization code for the global (only once).
    Globals from other modules: a global pointer coupled with a getGlobal call.
  - globals which have already been initialized cannot have their values changed
    by changing their initialization - use a handler or some other mechanism
  - new globals can be introduced when reloading
- top-level code (global scope) is executed only once - at the first module load
- the runtime knows every symbol's module owner (globals and procs)
- both the RTL and HCR shared libraries need to be near the program for execution
  - same folder, in the PATH or LD_LIBRARY_PATH env var, etc (depending on OS)
- the main module is responsible for initializing the HCR runtime
  - the main module loads the HCR runtime with a call to its HcrInit function
  - after that a call to initRuntime() is done in the main module which triggers
    the loading of all modules the main one imports, and doing that for the
    dependencies of each module recursively. A module is not initialized twice
    (for example when 2 modules both import a 3rd one). Basically a DFS traversal.
  - the initialization of a module is comprised of the following steps:
    - initialize all import dependencies for that module
    - call HcrInit - sets up the register/get proc/global pointers
    - call DatInit - usual dat init + register/get procs and get globals
    - call Init - it does the following multiplexed operations:
      - register globals (if already registered - then just retrieve pointer)
      - execute top level scope (only if loaded for the first time)
  - when modules are loaded the originally built shared libraries get copied in
    the same folder and the copies are loaded instead of the original files
  - a module import tree is built in the runtime (and maintained when reloading)
- performCodeReload
  - explicitly called by the user - the current active callstack shouldn't contain
    any functions which are defined in modules that will be reloaded (or crash!).
    The reason is that old dynalic libraries get unloaded.
    Example:
      if A is the main module and it imports B, then only B is reloadable and only
      if when calling performCodeReload there is no function defined in B in the
      current active callstack at the point of the call (it has to be done from A)
  - for reloading to take place the user has to have rebuilt parts of the application
    without changes affecting the main module in any way - it shouldn't be rebuilt.
  - to determine what needs to be reloaded the runtime starts traversing the import
    tree from the root and checks the timestamps of the loaded shared objects
  - modules that are no longer referenced are unloaded and cleaned up properly
  - symbols (procs/globals) that have been removed in the code are also cleaned up
    - so changing the init of a global does nothing, but removing it, reloading,
      and then re-introducing it with a new initializer works
  - new modules can be imported, and imports can also be reodereded/removed
  - hasAnyModuleChanged() can be used to determine if any module needs reloading
- code in the beforeCodeReload/afterCodeReload handlers is executed on each reload
  - such handlers can be added and removed
  - before each reload all "beforeCodeReload" handlers are executed and after
    that all handlers (including "after") from the particular module are deleted
  - the order of execution is the same as the order of top-level code execution.
    Example: if A imports B which imports C, then all handlers in C will be executed
    first (from top to bottom) followed by all from B and lastly all from A
  - since new globals can be introduced, the handlers are actually registered
    when a dummy global is initialized, and on each reload all such dummy globals
    are removed from the runtime so they can be re-registered with the same name
    and their init code gets ran which triggers a call to registerHandler
  - after the reload all "after" handlers are executed the same way as "before"

== TODO - immediate:

- documentation in nimc.rst
- tests
  - extend nimhcr_usage with more unit-test-like cases
  - implement a full runtime-reloadable test case
- profile
  - build speed with and without hot code reloading - difference should be small
  - runtime degradation of HCR-enabled code - important!!!

== TODO - after first merge in upstream Nim:

- migrate the js target to the new before/afterCodeReload API
- ARM support for the trampolines
- implement hasModuleChanged (perhaps with a magic returning SigHash)
- pdb paths on Windows should be fixed (related to copying .dll files)
  - absolute hardcoded path to .pdb is the same even for a copied .dll
  - if a debugger is attached - rebuilding will fail since .pdb files are locked
  - resources to look into:
    https://github.com/fungos/cr
    https://github.com/crosire/blink
    https://ourmachinery.com/post/little-machines-working-together-part-2/
    http://www.debuginfo.com/articles/debuginfomatch.html#pdbfiles
- investigate:
  - rethink the closure iterators
    - ability to keep old versions of dynamic libraries alive
      - because of async server code
      - perhaps with refcounting of .dlls for unfinished clojures
  - possible reload problem:
    - when static TNimNode arrays in DatInit get resized - already allocated with other size...
  - linking with static libs
    - all shared objects for each module will (probably) have to link to them
      - state in static libs gets duplicated
      - linking is slow and therefore iteration time
        - have just a single .dll for all .nim files and bulk reload?
  - killing the app with Ctrl+C hangs for a few sec on Windows
    - probably a crash on exit (after SIGINT/SIGTERM) - should investigate
    - -d:noSignalHandler ...?
    - initStackBottomWith() ...?
  - think about constructs such as {.compile: "myfile.cpp".}
  - GC - deinitGCFrame in Init and everything GC related
  - lfDynamicLib/lfExportLib - shouldn't add an extra '*' - play with plugins/dlls/lfIndirect
  - everything thread-local related
- tests
  - add a new travis build matrix entry which builds everything with HCR enabled
    - currently building with useNimRtl is problematic - lots of problems...
    - how to supply the nimrtl/nimhcr shared objects to all test binaries...?
    - think about building to C++ instead of only to C - added type safety
  - run tests through valgrind and the sanitizers! of HUGE importance!
- cleanup at shutdown - freeing all globals

== TODO - nice to have cool stuff:

- separate handling of global state for much faster reloading and manipulation
  - imagine sliders in an IDE for tweaking variables
  - perhaps using shared memory
- multi-dll projects - how everything can be reloaded..?
  - a single HCR instance shared across multiple .dlls
  - instead of having to call performCodeReload from a function in each dll
    - which currently renders the main module of each dll not reloadable
- ability to check with the current callstack if a reload is "legal"
  - if it is in any function which is in a module about to be reloaded ==> error
- pragma annotations for files - to be excluded from dll shenanigans
  - for such file-global pragmas look at codeReordering or injectStmt
  - how would the initialization order be kept? messy...
  - per function exclude pragmas would be TOO messy and hard...
- C code calling stable exportc interface of nim code (for binding)
  - generate proxy functions with the stable names
    - in a non-reloadable part (the main binary) that call into the function pointers
    - parameter passing/forwarding - how? use the same trampoline jumping?
    - extracting the dependencies for these stubs/proxies will be hard...
- changing memory layout of types - detecting this..?
  - implement with registerType() call to HCR runtime...?
    - and checking if a previously registered type matches
  - issue an error
    - or let the user handle this by transferring the state properly
      - perhaps in the before/afterCodeReload handlers
- optimization: calls to functions within a module to use the _actual versions

== TODO - unimportant:

- have a "bad call" trampoline that all no-longer-present functions are routed to call there
    - so the user gets some error msg if he calls a dangling pointer instead of a crash
- before/afterCodeReload and hasModuleChanged should be accessible only where appropriate
- nim_program_result is inaccessible in HCR mode from external C code (see nimbase.h)
- proper .json build file - but the format is different... multiple link commands...

== TODO - REPL:
- let's not get ahead of ourselves... :|

"""



when defined(hotcodereloading) or defined(createNimHcr) or defined(testNimHcr):
  const
    nimhcrExports = "nimhcr_$1"
    dllExt = when defined(windows): "dll"
            elif defined(macosx): "dylib"
            else: "so"
  type
    ProcGetter* = proc (libHandle: pointer, procName: cstring): pointer {.nimcall.}

when defined(createNimHcr):
  when system.appType != "lib":
    {.error: "This file has to be compiled as a library!".}

  import os, tables, sets, times, strutils, reservedmem, dynlib

  template trace(args: varargs[untyped]) =
    when defined(testNimHcr): echo args
  proc sanitize(arg: Time): string =
    when defined(testNimHcr): return "<time>"
    else: return $arg
  proc sanitize(arg: string|cstring): string =
    when defined(testNimHcr): return "<path>"
    else: return $arg

  {.pragma: nimhcr, compilerProc, exportc: nimhcrExports, dynlib.}

  when hostCPU in ["i386", "amd64"]:
    type
      ShortJumpInstruction {.packed.} = object
        opcode: byte
        offset: int32

      LongJumpInstruction {.packed.} = object
        opcode1: byte
        opcode2: byte
        offset: int32
        absoluteAddr: pointer

    proc writeJump(jumpTableEntry: ptr LongJumpInstruction, targetFn: pointer) =
      let
        jumpFrom = jumpTableEntry.shift(sizeof(ShortJumpInstruction))
        jumpDistance = distance(jumpFrom, targetFn)

      if abs(jumpDistance) < 0x7fff0000:
        let shortJump = cast[ptr ShortJumpInstruction](jumpTableEntry)
        shortJump.opcode = 0xE9 # relative jump
        shortJump.offset = int32(jumpDistance)
      else:
        jumpTableEntry.opcode1 = 0xff # indirect absolute jump
        jumpTableEntry.opcode2 = 0x25
        when hostCPU == "i386":
          # on x86 we write the absolute address of the following pointer
          jumpTableEntry.offset = cast[int32](addr jumpTableEntry.absoluteAddr)
        else:
          # on x64, we use a relative address for the same location
          jumpTableEntry.offset = 0
        jumpTableEntry.absoluteAddr = targetFn

  elif hostCPU == "arm":
    const jumpSize = 8
  elif hostCPU == "arm64":
    const jumpSize = 16

  const defaultJumpTableSize = case hostCPU
                               of "i386": 50
                               of "amd64": 500
                               else: 50

  let jumpTableSizeStr = getEnv("HOT_CODE_RELOADING_JUMP_TABLE_SIZE")
  let jumpTableSize = if jumpTableSizeStr.len > 0: parseInt(jumpTableSizeStr)
                      else: defaultJumpTableSize

  # TODO: perhaps keep track of free slots due to removed procs using a free list
  var jumpTable = ReservedMemSeq[LongJumpInstruction].init(
    memStart = cast[pointer](0x10000000),
    maxLen = jumpTableSize * 1024 * 1024 div sizeof(LongJumpInstruction),
    accessFlags = memExecReadWrite)

  type
    ProcSym = object
      jump: ptr LongJumpInstruction
      gen: int

    GlobalVarSym = object
      p: pointer
      gen: int

    ModuleDesc = object
      procs: Table[string, ProcSym]
      globals: Table[string, GlobalVarSym]
      imports: seq[string]
      handle: LibHandle
      gen: int
      lastModification: Time
      handlers: seq[tuple[isBefore: bool, globalVar: string, cb: proc ()]]

  proc newModuleDesc(): ModuleDesc =
    result.procs = initTable[string, ProcSym]()
    result.globals = initTable[string, GlobalVarSym]()

  # the global state necessary for traversing and reloading the module import tree
  var modules = initTable[string, ModuleDesc]()
  var root: string
  var generation = 0

  # necessary for registering handlers and keeping them up-to-date
  var currentModule: string
  var lastRegisteredGlobal: string

  # supplied from the main module - used by others to initialize pointers to this runtime
  var hcrDynlibHandle: pointer
  var getProcAddr: ProcGetter

  proc registerProc*(module: cstring, name: cstring, fn: pointer): pointer {.nimhcr.} =
    trace "  register proc: ", module.sanitize, " ", name
    # Please note: We must allocate a local copy of the strings, because the supplied
    # `cstring` will reside in the data segment of a DLL that will be later unloaded.
    let name = $name
    let module = $module

    var jumpTableEntryAddr: ptr LongJumpInstruction

    modules[module].procs.withValue(name, p):
      trace "    update proc: ", name
      jumpTableEntryAddr = p.jump
      p.gen = generation
    do:
      let len = jumpTable.len
      jumpTable.setLen(len + 1)
      jumpTableEntryAddr = addr jumpTable[len]
      modules[module].procs[name] = ProcSym(jump: jumpTableEntryAddr, gen: generation)

    writeJump jumpTableEntryAddr, fn
    return jumpTableEntryAddr

  proc getProc*(module: cstring, name: cstring): pointer {.nimhcr.} =
    trace "  get proc: ", module.sanitize, " ", name
    return modules[$module].procs[$name].jump

  proc registerGlobal*(module: cstring,
                       name: cstring,
                       size: Natural,
                       outPtr: ptr pointer): bool {.nimhcr.} =
    trace "  register global: ", module.sanitize, " ", name
    # Please note: We must allocate local copies of the strings, because the supplied
    # `cstring` will reside in the data segment of a DLL that will be later unloaded.
    # Also using a ptr pointer instead of a var pointer (an output parameter)
    # because for the C++ backend var parameters use references and in this use case
    # it is not possible to cast an int* (for example) to a void* and then pass it
    # to void*& since the casting yields an rvalue and references bind only to lvalues.
    let name = $name
    let module = $module
    lastRegisteredGlobal = name

    modules[module].globals.withValue(name, global):
      trace "    update global: ", name
      outPtr[] = global.p
      global.gen = generation
      return false
    do:
      outPtr[] = alloc0(size)
      modules[module].globals[name] = GlobalVarSym(p: outPtr[], gen: generation)
      return true

  proc getGlobal*(module: cstring, name: cstring): pointer {.nimhcr.} =
    trace "  get global: ", module.sanitize, " ", name
    return modules[$module].globals[$name].p

  proc getListOfModules(cstringArray: ptr pointer): seq[string] =
    var curr = cast[ptr cstring](cstringArray)
    while len(curr[]) > 0:
      result.add($curr[])
      curr = cast[ptr cstring](cast[int64](curr) + sizeof(ptr cstring))

  template cleanup(collection, body) =
    var toDelete: seq[string]
    for name, data in collection.pairs:
      if data.gen < generation:
        toDelete.add(name)
        trace "HCR Cleaning ", astToStr(collection), " :: ", name, " ", data.gen
    for name {.inject.} in toDelete:
      body

  proc cleanupGlobal(module: string, name: string) =
    var g: GlobalVarSym
    if modules[module].globals.take(name, g):
      dealloc g.p

  proc cleanupSymbols(module: string) =
    cleanup modules[module].globals:
      cleanupGlobal(module, name)

    cleanup modules[module].procs:
      modules[module].procs.del(name)

  proc loadDll(name: cstring) {.nimhcr.} =
    let name = $name
    trace "HCR LOADING: ", name.sanitize
    if modules.contains(name):
      unloadLib(modules[name].handle)
    else:
      modules.add(name, newModuleDesc())

    let copiedName = name & ".copy." & dllExt
    copyFile(name, copiedName)

    let lib = loadLib(copiedName)
    assert lib != nil
    modules[name].handle = lib
    modules[name].gen = generation
    modules[name].lastModification = getLastModificationTime(name)

    # update the list of imports by the module
    let getImportsProc = cast[proc (): ptr pointer {.noconv.}](
      checkedSymAddr(lib, "HcrGetImportedModules"))
    modules[name].imports = getListOfModules(getImportsProc())

    # Remove handlers for this module if reloading - they will be re-registered.
    # In order for them to be re-registered we need to de-register all globals
    # that trigger the registering of handlers through calls to registerHandler
    for curr in modules[name].handlers:
      cleanupGlobal(name, curr.globalVar)
    modules[name].handlers.setLen(0)

  proc initPointerData(name: cstring) {.nimhcr.} =
    trace "HCR Hcr/Dat init: ", name.sanitize
    cast[proc (h: pointer, gpa: ProcGetter) {.noconv.}](
      checkedSymAddr(modules[$name].handle, "HcrInit000"))(hcrDynlibHandle, getProcAddr)
    cast[proc () {.noconv.}](checkedSymAddr(modules[$name].handle, "DatInit000"))()

  proc initGlobalScope(name: cstring) {.nimhcr.} =
    trace "HCR Init000: ", name.sanitize
    # set the currently inited module - necessary for registering the before/after HCR handlers
    currentModule = $name
    cast[proc () {.noconv.}](checkedSymAddr(modules[$name].handle, "Init000"))()

  proc recursiveInit(dlls: seq[string]) =
    for curr in dlls:
      if modules.contains(curr):
        # skip updating modules that have already been updated to the latest generation
        if modules[curr].gen >= generation:
          trace "HCR SKIP: ", curr.sanitize, " gen is already: ", modules[curr].gen
          continue
        # skip updating an unmodified module but continue traversing its dependencies
        if modules[curr].lastModification >= getLastModificationTime(curr):
          trace "HCR SKIP (not modified): ", curr.sanitize, " ", modules[curr].lastModification.sanitize
          # update generation so module doesn't get collected
          modules[curr].gen = generation
          # recurse to imported modules - they might be changed
          recursiveInit(modules[curr].imports)
          continue
      loadDll(curr)
      # first load all dependencies of the current module and init it after that
      recursiveInit(modules[curr].imports)
      # init the current module after all its dependencies
      initPointerData(curr)
      initGlobalScope(curr)
      # cleanup old symbols which are gone now
      cleanupSymbols(curr)

  var traversedModules: HashSet[string]

  proc recursiveExecuteHandlers(isBefore: bool, module: string) =
    # do not process an already traversed module
    if traversedModules.containsOrIncl(module): return
    traversedModules.incl module
    # first recurse to do a DFS traversal
    for curr in modules[module].imports:
      recursiveExecuteHandlers(isBefore, curr)
    # and then execute the handlers - from leaf modules all the way up to the root module
    for curr in modules[module].handlers:
      if curr.isBefore == isBefore:
       curr.cb()

  proc initRuntime*(moduleList: ptr pointer,
                    main: cstring, handle: pointer,
                    gpa: ProcGetter) {.nimhcr.} =
    trace "HCR INITING: ", main.sanitize
    # initialize globals
    root = $main
    hcrDynlibHandle = handle
    getProcAddr = gpa
    traversedModules.init()
    # we need the root to be added as well because symbols from it will also be registered in the HCR system
    modules.add(root, newModuleDesc())
    modules[root].imports = getListOfModules(moduleList)
    modules[root].gen = high(int) # something huge so it doesn't get collected
    # recursively initialize all modules
    recursiveInit(modules[root].imports)
    # the next module to be inited will be the root
    currentModule = root

  proc hasAnyModuleChanged*(): bool {.nimhcr.} =
    proc recursiveChangeScan(dlls: seq[string]): bool =
      for curr in dlls:
        if modules[curr].lastModification < getLastModificationTime(curr) or
           recursiveChangeScan(modules[curr].imports): return true
      return false
    return recursiveChangeScan(modules[root].imports)

  proc cleanupModule(module: string) =
    cleanupSymbols(module)
    unloadLib(modules[module].handle)
    modules.del(module)

  proc performCodeReload*() {.nimhcr.} =
    if not hasAnyModuleChanged():
      return

    inc(generation)
    trace "HCR RELOADING: ", generation

    # first execute the before reload handlers
    traversedModules.clear()
    recursiveExecuteHandlers(true, root)

    # do the reloading
    recursiveInit(modules[root].imports)

    # execute the after reload handlers
    traversedModules.clear()
    recursiveExecuteHandlers(false, root)

    # collecting no longer referenced modules - based on their generation
    cleanup modules:
      cleanupModule name

  proc registerHandler*(isBefore: bool, cb: proc ()): bool {.nimhcr.} =
    modules[currentModule].handlers.add(
      (isBefore: isBefore, globalVar: lastRegisteredGlobal, cb: cb))
    return true

  proc addDummyModule*(module: cstring) {.nimhcr.} =
    modules.add($module, newModuleDesc())

else:
  when defined(hotcodereloading) or defined(testNimHcr):
    const
      nimhcrLibname = when defined(windows): "nimhcr." & dllExt
                      elif defined(macosx): "libnimhcr." & dllExt
                      else: "libnimhcr." & dllExt

    {.pragma: nimhcr, compilerProc, importc: nimhcrExports, dynlib: nimhcrLibname.}

    proc registerProc*(module: cstring, name: cstring, fn: pointer): pointer {.nimhcr.}
    proc getProc*(module: cstring, name: cstring): pointer {.nimhcr.}
    proc registerGlobal*(module: cstring, name: cstring, size: Natural, outPtr: ptr pointer): bool {.nimhcr.}
    proc getGlobal*(module: cstring, name: cstring): pointer {.nimhcr.}

    proc initRuntime*(moduleList: ptr pointer, main: cstring, handle: pointer, gpa: ProcGetter) {.nimhcr.}
    proc registerHandler*(isBefore: bool, cb: proc ()): bool {.nimhcr.}

    # used only for testing purposes so the register/get proc/global functions don't crash
    proc addDummyModule*(module: cstring) {.nimhcr.}

    # the following functions/templates are intended to be used by the user
    proc performCodeReload*() {.nimhcr.}
    proc hasAnyModuleChanged*(): bool {.nimhcr.}

    # We use a "global" to force execution while top-level statements are
    # evaluated - this way new handlers can be added when reloading (new globals
    # can be introduced but newly written top-level code is not executed)
    template beforeCodeReload*(body: untyped) =
      let dummy = registerHandler(true, proc = body)

    template afterCodeReload*(body: untyped) =
      let dummy = registerHandler(false, proc = body)

  else:
    # we need these stubs so code continues to compile even when HCR is off
    proc performCodeReload*() = discard
    proc hasAnyModuleChanged*(): bool = false
    template beforeCodeReload*(body: untyped) = discard
    template afterCodeReload*(body: untyped) = discard