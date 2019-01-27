import nake

let parallelBuild = "--parallelBuild:0"
let nimVerbose = "--verbosity:0"

const prefer32bit = true

proc runNim(file: string, arguments: varargs[string]) =
    var args = @[nimExe, "c", parallelBuild,
                nimVerbose, "-d:release", "--opt:speed", "-d:ssl", "--stacktrace:on", "--linetrace:on", "--checks:on", "--threads:on",
                    "--path:../", "-d:falconServer"]

    args.add arguments
    args.add file
    direShell args

proc buildServer(arguments: varargs[string]) =
    var args = @arguments
    # There's a memory leak in 64bit mode, so for production we compile 32-bit
    # version with statically linked libssl.
    when defined(linux):
        args.add(["--cpu:i386", "--passC:-m32", "--passL:-m32"])
    elif defined(macosx) and prefer32bit:
        args.add(["--cpu:i386", "--passC:-arch", "--passC:i386", "--passL:-arch", "--passL:i386"])

    runNim("main.nim", args)

task defaultTask, "Build and run":
    buildServer("--run")

task "build", "Build":
    buildServer()

task "maintenance", "Maintenance":
    runNim("maintenance.nim", "--run")

task "tests", "Tests":
    withDir "..":
        putEnv("NIM_COVERAGE_DIR", "coverage_results")
        createDir("coverage_results")
        runNim("unittests.nim", "--run", "-d:tests")
        direShell("nimcoverage", "genreport")
