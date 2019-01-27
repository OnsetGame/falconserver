template doTests*(body:untyped) =
    var
        testPassedCounter     = 0
        testFailedCounter     = 0
        testCounter           = 0
        testChecks            = 0
        checksFailed          = 0
        checksPassed          = 0
        checks:seq[string]    = @[]

    let pos = instantiationInfo()
    bind testPassedCounter, testFailedCounter, checksFailed, testCounter, testChecks, pos

    proc printFails()=
        if checks.len > 0:
            inc testFailedCounter
            for tf in checks:
                echo "    [>] ", tf
        else:
            inc testPassedCounter

    try:

        template test(testName = "", testBody:untyped)=
            testChecks   = 0
            checksFailed = 0
            checksPassed = 0
            checks       = @[]

            inc testCounter
            testBody
            if checksFailed == 0:
                echo "  Test ", testName, " # ", testCounter, "\t\t OK"
            else:
                echo "  Test ", testName, " # ", testCounter, "\t\t FAILED"
            echo "    [+] ", checksPassed, " checks passed."
            echo "    [-] ", checksFailed, " checks failed."
            printFails()

        template test(testBody:untyped)=
            test("", testBody)

        template checkCond(con:bool, msg: string)=
            inc testChecks
            if con:
                inc checksPassed
            else:
                inc checksFailed

                template buildMsg():string =
                    "Check #" & $testChecks & ": "  & msg & " \n\t" & astToStr(con)
                if false:
                    echo buildMsg()
                else:
                    checks.add(buildMsg())

        template checkField(field:seq[int8]):bool = not field.isNil and field.len == 15

        echo "\nStart testing module: ", pos.filename

        body

        echo "  [+] ", testPassedCounter, " tests passed"
        echo "  [-] ", testFailedCounter, " tests failed"
        if testFailedCounter > 0:
            quit(1)
    except:

        let e = getCurrentException()
        writeStackTrace()
        echo "  [!] Suite failed. Error happened: ", e.msg, "  ", e.getStackTrace()
        printFails()
        quit(1)
