##[
Main import file to write wrappers.
Each `compileTime` proc must be used in a compile time context, eg using:

```
static:
  cAddStdDir()
```
]##

import hashes, macros, os, strformat, strutils

const CIMPORT {.used.} = 1

include "."/globals

import "."/[git, paths, types]
export types

proc interpPath(dir: string): string=
  # TODO: more robust: needs a DirSep after "$projpath"
  # disabling this interpolation as this is error prone, but other less
  # interpolations can be added, eg see https://github.com/nim-lang/Nim/pull/10530
  # result = dir.replace("$projpath", getProjectPath())
  result = dir

proc joinPathIfRel(path1: string, path2: string): string =
  if path2.isAbsolute:
    result = path2
  else:
    result = joinPath(path1, path2)

proc findPath(path: string, fail = true): string =
  # Relative to project path
  result = joinPathIfRel(getProjectPath(), path).replace("\\", "/")
  if not fileExists(result) and not dirExists(result):
    doAssert (not fail), "File or directory not found: " & path
    result = ""

proc walkDirImpl(indir, inext: string, file=true): seq[string] =
  let
    dir = joinPathIfRel(getProjectPath(), indir)
    ext =
      if inext.len != 0:
        when not defined(Windows):
          "-name " & inext
        else:
          "\\" & inext
      else:
        ""

  let
    cmd =
      when defined(Windows):
        if file:
          "cmd /c dir /s/b/a-d " & dir.replace("/", "\\") & ext
        else:
          "cmd /c dir /s/b/ad " & dir.replace("/", "\\")
      else:
        if file:
          "find $1 -type f $2" % [dir, ext]
        else:
          "find $1 -type d" % dir

    (output, ret) = gorgeEx(cmd)

  if ret == 0:
    result = output.splitLines()

proc getFileDate(fullpath: string): string =
  var
    ret = 0
    cmd =
      when defined(Windows):
        &"cmd /c for %a in ({fullpath.quoteShell}) do echo %~ta"
      elif defined(Linux):
        &"stat -c %y {fullpath.quoteShell}"
      elif defined(OSX):
        &"stat -f %m {fullpath.quoteShell}"

  (result, ret) = gorgeEx(cmd)

  doAssert ret == 0, "File date error: " & fullpath & "\n" & result

proc getCacheValue(fullpath: string): string =
  if not gStateCT.nocache:
    result = fullpath.getFileDate()

proc getToastError(output: string): string =
  # Filter out preprocessor errors
  for line in output.splitLines():
    if "fatal error:" in line.toLowerAscii:
      result &= "\n\nERROR:$1\n" % line.split("fatal error:")[1]

  # Toast error
  if result.len == 0:
    result = "\n\n" & output

proc getNimCheckError(output: string): tuple[tmpFile, errors: string] =
  let
    hash = output.hash().abs()

  result.tmpFile = getTempDir() / "nimterop_" & $hash & ".nim"

  if not fileExists(result.tmpFile) or gStateCT.nocache or compileOption("forceBuild"):
    writeFile(result.tmpFile, output)

  doAssert fileExists(result.tmpFile), "Bad codegen - unable to write to TEMP: " & result.tmpFile

  let
    (check, _) = gorgeEx("nim check " & result.tmpFile)

  result.errors = "\n\n" & check

proc getToast(fullpath: string, recurse: bool = false): string =
  var
    ret = 0
    cmd = when defined(Windows): "cmd /c " else: ""

  let toastExe = toastExePath()
  doAssert fileExists(toastExe), "toast not compiled: " & toastExe.quoteShell &
    " make sure 'nimble build' or 'nimble install' built it"
  cmd &= &"{toastExe} --pnim --preprocess"

  if recurse:
    cmd.add " --recurse"

  for i in gStateCT.defines:
    cmd.add &" --defines+={i.quoteShell}"

  for i in gStateCT.includeDirs:
    cmd.add &" --includeDirs+={i.quoteShell}"

  if gStateCT.symOverride.len != 0:
    cmd.add &" --symOverride={gStateCT.symOverride.join(\",\")}"

  if gStateCT.pluginSourcePath.nBl:
    cmd.add &" --pluginSourcePath={gStateCT.pluginSourcePath.quoteShell}"

  cmd.add &" {fullpath.quoteShell}"
  echo cmd
  # see https://github.com/genotrance/nimterop/issues/69
  (result, ret) = gorgeEx(cmd, cache=getCacheValue(fullpath))
  doAssert ret == 0, getToastError(result)

proc getGccPaths(mode = "c"): string =
  var
    ret = 0
    nul = when defined(Windows): "nul" else: "/dev/null"
    mmode = if mode == "cpp": "c++" else: mode

  (result, ret) = gorgeEx("gcc -Wp,-v -x" & mmode & " " & nul)

macro cOverride*(body): untyped =
  ## When the wrapper code generated by nimterop is missing certain symbols or not
  ## accurate, it may be required to hand wrap them. Define them in a
  ## `cOverride() <cimport.html#cOverride.m,>`_ macro block so that Nimterop no
  ## longer defines these symbols.
  ##
  ## For example:
  ##
  ## .. code-block:: c
  ##
  ##    int svGetCallerInfo(const char** fileName, int *lineNumber);
  ##
  ## This might map to:
  ##
  ## .. code-block:: nim
  ##
  ##    proc svGetCallerInfo(fileName: ptr cstring; lineNumber: var cint)
  ##
  ## Whereas it might mean:
  ##
  ## .. code-block:: nim
  ##
  ##    cOverride:
  ##      proc svGetCallerInfo(fileName: var cstring; lineNumber: var cint)
  ##
  ## Using the `cOverride() <cimport.html#cOverride.m,>`_ block, nimterop
  ## can be instructed to skip over ``svGetCallerInfo()``. This works for procs,
  ## consts and types.

  proc recFindIdent(node: NimNode): seq[string] =
    if node.kind != nnkIdent:
      for child in node:
        result.add recFindIdent(child)
        if result.len != 0 and node.kind notin [nnkTypeSection, nnkConstSection]:
          break
    elif $node != "*":
      result.add $node

  for sym in body:
    gStateCT.symOverride.add recFindIdent(sym)

  result = body

  if gStateCT.debug:
    echo "Overriding " & gStateCT.symOverride.join(" ")

proc cSkipSymbol*(skips: seq[string]) {.compileTime.} =
  ## Similar to `cOverride() <cimport.html#cOverride.m,>`_, this macro allows
  ## filtering out symbols not of interest from the generated output.
  runnableExamples:
    static: cSkipSymbol @["proc1", "Type2"]
  gStateCT.symOverride.add skips

macro cPlugin*(body): untyped =
  ## When `cOverride() <cimport.html#cOverride.m,>`_ and `cSkipSymbol() <cimport.html#cSkipSymbol.m%2Cseq[string]>`_
  ## are not adequate, the `cPlugin() <cimport.html#cPlugin.m,>`_ macro can be used
  ## to customize the generated Nim output. The following callbacks are available at
  ## this time.
  ##
  ## .. code-block:: nim
  ##
  ##     proc onSymbol(sym: var Symbol) {.exportc, dynlib.}
  ##
  ## `onSymbol()` can be used to handle symbol name modifications required due to invalid
  ## characters like leading/trailing `_` or rename symbols that would clash due to Nim's style
  ## insensitivity. It can also be used to remove prefixes and suffixes like `SDL_`. The symbol
  ## name and type is provided to the callback and the name can be modified.
  ##
  ## Returning a blank name will result in the symbol being skipped. This will fail for `nskParam`
  ## and `nskField` since the generated Nim code will be wrong.
  ##
  ## Symbol types can be any of the following:
  ## - `nskConst` for constants
  ## - `nskType` for type identifiers, including primitive
  ## - `nskParam` for param names
  ## - `nskField` for struct field names
  ## - `nskEnumField` for enum (field) names, though they are in the global namespace as `nskConst`
  ## - `nskProc` - for proc names
  ##
  ## `nimterop/plugins` is implicitly imported to provide access to standard plugin facilities.
  runnableExamples:
    cPlugin:
      import strutils

      proc onSymbol*(sym: var Symbol) {.exportc, dynlib.} =
        sym.name = sym.name.strip(chars={'_'})

  let
    data = "import nimterop/plugin\n\n" & body.repr
    hash = data.hash().abs()
    path = getTempDir() / "nimterop_" & $hash & ".nim"

  if not fileExists(path) or gStateCT.nocache or compileOption("forceBuild"):
    writeFile(path, data)

  doAssert fileExists(path), "Unable to write plugin file: " & path

  gStateCT.pluginSourcePath = path

proc cSearchPath*(path: string): string {.compileTime.}=
  ## Get full path to file or directory ``path`` in search path configured
  ## using `cAddSearchDir() <cimport.html#cAddSearchDir,>`_ and
  ## `cAddStdDir() <cimport.html#cAddStdDir,string>`_.
  ##
  ## This can be used to locate files or directories that can be passed onto
  ## `cCompile() <cimport.html#cCompile.m,,string>`_,
  ## `cIncludeDir() <cimport.html#cIncludeDir.m,>`_ and
  ## `cImport() <cimport.html#cImport.m,>`_.

  result = findPath(path, fail = false)
  if result.len == 0:
    var found = false
    for inc in gStateCT.searchDirs:
      result = findPath(inc / path, fail = false)
      if result.len != 0:
        found = true
        break
    doAssert found, "File or directory not found: " & path &
      " gStateCT.searchDirs: " & $gStateCT.searchDirs

proc cDebug*() {.compileTime.} =
  ## Enable debug messages and display the generated Nim code
  gStateCT.debug = true

proc cDisableCaching*() {.compileTime.} =
  ## Disable caching of generated Nim code - useful during wrapper development
  ##
  ## If files included by header being processed by `cImport() <cimport.html#cImport.m,>`_
  ## change and affect the generated content, they will be ignored and the cached
  ## value will continue to be used . Use `cDisableCaching() <cimport.html#cDisableCaching,>`_
  ## to avoid this scenario during development.
  ##
  ## ``nim -f`` was broken prior to 0.19.4 but can also be used to flush the cached content.

  gStateCT.nocache = true

# TODO: `passC` should be delayed and inserted inside `cImport`, `cCompile`
# and this should be made a proc:
# proc cDefine*(name: string, val = "") {.compileTime.} =
macro cDefine*(name: static string, val: static string = ""): untyped =
  ## ``#define`` an identifer that is forwarded to the C/C++ compiler
  ## using ``{.passC: "-DXXX".}``

  result = newNimNode(nnkStmtList)

  var str = name
  # todo: see https://github.com/genotrance/nimterop/issues/100 for
  # edge case of empty strings
  if val.nBl:
    str &= &"={val.quoteShell}"

  if str notin gStateCT.defines:
    gStateCT.defines.add(str)
    str = "-D" & str

    result.add quote do:
      {.passC: `str`.}

    if gStateCT.debug:
      echo result.repr

proc cAddSearchDir*(dir: string) {.compileTime.} =
  ## Add directory ``dir`` to the search path used in calls to
  ## `cSearchPath() <cimport.html#cSearchPath,string>`_.
  runnableExamples:
    import paths, os
    static:
      cAddSearchDir testsIncludeDir()
    doAssert cSearchPath("test.h").existsFile
  var dir = interpPath(dir)
  if dir notin gStateCT.searchDirs:
    gStateCT.searchDirs.add(dir)

macro cIncludeDir*(dir: static string): untyped =
  ## Add an include directory that is forwarded to the C/C++ compiler
  ## using ``{.passC: "-IXXX".}``. This is also provided to the
  ## preprocessor during Nim code generation.

  var dir = interpPath(dir)
  result = newNimNode(nnkStmtList)

  let fullpath = findPath(dir)
  if fullpath notin gStateCT.includeDirs:
    gStateCT.includeDirs.add(fullpath)
    let str = &"-I{fullpath.quoteShell}"
    result.add quote do:
      {.passC: `str`.}
    if gStateCT.debug:
      echo result.repr

proc cAddStdDir*(mode = "c") {.compileTime.} =
  ## Add the standard ``c`` [default] or ``cpp`` include paths to search
  ## path used in calls to `cSearchPath() <cimport.html#cSearchPath,string>`_
  runnableExamples:
    static: cAddStdDir()
    import os
    doAssert cSearchPath("math.h").existsFile
  var
    inc = false
  for line in getGccPaths(mode).splitLines():
    if "#include <...> search starts here" in line:
      inc = true
      continue
    elif "End of search list" in line:
      break
    if inc:
      cAddSearchDir line.strip()

macro cCompile*(path: static string, mode = "c", exclude = ""): untyped =
  ## Compile and link C/C++ implementation into resulting binary using ``{.compile.}``
  ##
  ## ``path`` can be a specific file or contain wildcards:
  ##
  ## .. code-block:: nim
  ##
  ##     cCompile("file.c")
  ##     cCompile("path/to/*.c")
  ##
  ## ``mode`` recursively searches for code files in ``path``.
  ##
  ## ``c`` searches for ``*.c`` whereas ``cpp`` searches for ``*.C *.cpp *.c++ *.cc *.cxx``
  ##
  ## .. code-block:: nim
  ##
  ##    cCompile("path/to/dir", "cpp")
  ##
  ## ``exclude`` can be used to exclude files by partial string match. Comma separated to
  ## specify multiple exclude strings
  ##
  ## .. code-block:: nim
  ##
  ##    cCompile("path/to/dir", exclude="test2.c")

  result = newNimNode(nnkStmtList)

  var
    stmt = ""

  proc fcompile(file: string): string =
    let
      (_, fn, ext) = file.splitFile()
    var
      ufn = fn
      uniq = 1
    while ufn in gStateCT.compile:
      ufn = fn & $uniq
      uniq += 1

    # - https://github.com/nim-lang/Nim/issues/10299
    # - https://github.com/nim-lang/Nim/issues/10486
    gStateCT.compile.add(ufn)
    if fn == ufn:
      return "{.compile: \"$#\".}\n" % file.replace("\\", "/")
    else:
      # - https://github.com/nim-lang/Nim/issues/9370
      let
        hash = file.hash().abs()
        tmpFile = file.parentDir() / &"_nimterop_{$hash}_{ufn}{ext}"
      if not tmpFile.fileExists() or file.getFileDate() > tmpFile.getFileDate():
        cpFile(file, tmpFile)
      return "{.compile: \"$#\".}\n" % tmpFile.replace("\\", "/")

  # Due to https://github.com/nim-lang/Nim/issues/9863
  # cannot use seq[string] for excludes
  proc notExcluded(file, exclude: string): bool =
    result = true
    if "_nimterop_" in file:
      result = false
    elif exclude.len != 0:
      for excl in exclude.split(","):
        if excl in file:
          result = false

  proc dcompile(dir, exclude: string, ext=""): string =
    let
      files = walkDirImpl(dir, ext)

    for f in files:
      if f.len != 0 and f.notExcluded(exclude):
        result &= fcompile(f)

  if path.contains("*") or path.contains("?"):
    stmt &= dcompile(path, exclude.strVal())
  else:
    let fpath = findPath(path)
    if fileExists(fpath) and fpath.notExcluded(exclude.strVal()):
      stmt &= fcompile(fpath)
    elif dirExists(fpath):
      if mode.strVal().contains("cpp"):
        for i in @["*.cpp", "*.c++", "*.cc", "*.cxx"]:
          stmt &= dcompile(fpath, exclude.strVal(), i)
        when not defined(Windows):
          stmt &= dcompile(fpath, exclude.strVal(), "*.C")
      else:
        stmt &= dcompile(fpath, exclude.strVal(), "*.c")

  result.add stmt.parseStmt()

  if gStateCT.debug:
    echo result.repr

macro cImport*(filename: static string, recurse: static bool = false): untyped =
  ## Import all supported definitions from specified header file. Generated
  ## content is cached in ``nimcache`` until ``filename`` changes unless
  ## `cDisableCaching() <cimport.html#cDisableCaching,>`_ is set. ``nim -f``
  ## can also be used after Nim v0.19.4 to flush the cache.
  ##
  ## ``recurse`` can be used to generate Nim wrappers from ``#include`` files
  ## referenced in ``filename``. This is only done for files in the same
  ## directory as ``filename`` or in a directory added using
  ## `cIncludeDir() <cimport.html#cIncludeDir.m,>`_

  result = newNimNode(nnkStmtList)

  let
    fullpath = findPath(filename)

  echo "Importing " & fullpath

  let
    output = getToast(fullpath, recurse)

  try:
    let body = parseStmt(output)

    result.add body

    if gStateCT.debug:
      echo result.repr
  except:
    let
      (tmpFile, errors) = getNimCheckError(output)
    doAssert false, errors & "\n\nNimterop codegen limitation or error - review 'nim check' output above generated for " & tmpFile

