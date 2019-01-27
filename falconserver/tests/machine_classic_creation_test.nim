import unittest

import falconserver.slot.machine_base
import falconserver.slot.machine_classic

try:
    var
        testSuccessCounter = 0       # Indicates how much tests were passed
        testFailCounter = 0          # Indicates how much tests were failed
        testFails: seq[string] = @[] # Fail messages
        testCounter = 0              # Total test counter

    template MegaAssert(e: expr, o: string, v: expr = "") =
        bind testSuccessCounter, testFailCounter, testCounter
        inc(testCounter)
        if not e:
            inc(testFailCounter)
            write(stdout, "F")
            testFails.add("Test #" & $testCounter & ": " & o & " with condition: " & astToStr(e) & " having value of: " & $v)
        else:
            inc(testSuccessCounter)
            write(stdout, ".")

    stdout.write("[*] Running 'machine_classic_test.nim' tests: ")
    # Test machine creation
    let machine = newSlotMachineClassic(slotMachineDesc("falconserver/resources/slot_001_dreamtower.zsm"))
    MegaAssert(true, "Could not create machine from file", true)
    MegaAssert(machine.fieldHeight == 3, "Wrong value for 'fieldHeight' read from file", machine.fieldHeight)
    MegaAssert(machine.items.len == 12, "Wrong sequence of items read from file", machine.items.len)
    MegaAssert(machine.lines.len == 20, "Wrong number of lines read from file", machine.lines.len)
    for i in machine.lines[0]:
        MegaAssert(i == 1, "Wrong line read from file", i)

    # Test just spinning
    let field = machine.reels.spin(nil, machine.fieldHeight)

    MegaAssert(
        field.len() == (machine.fieldHeight * machine.reelCount()),
        "Bad 'field' generated from 'justSpin'",
        field.len()
    )

    # Test combinations
    let combo = machine.combinations(field, 1)

    MegaAssert(len(combo) == 1, "Bad 'combinations' size after 'combinations' call", len(combo))

    # Test public uber spin
    let spinResult = machine.spin(nil, 0.Stage, 10, 1)

    if spinResult.lines[0].numberOfWinningSymbols == 1:
        MegaAssert(spinResult.lines[0].payout == 0, "Bad payout value for non-winning combination", spinResult.lines[0].payout)
    else:
        MegaAssert(spinResult.lines[0].payout >= 0, "Bad payout value for winning combination", spinResult.lines[0].payout)

    let lines = machine.payouts(machine.combinations(@[9.int8, 5, 9, 7, 11, 11, 11, 6, 4, 7, 6, 3, 7, 6, 6], 20))
    const nw : WinningLine = (1, 0.int64)
    MegaAssert(lines == @[(2, 0.int64), nw, nw, nw, nw, nw, nw, nw, nw, nw, nw, nw, nw, nw, nw, (2, 0.int64), (2, 0.int64), nw, nw, nw],
        "Wrong value for 'lines' for spin result", lines)

    # Test Results
    echo "\n[+] ", testSuccessCounter, " tests passed.\n"
    echo "[-] ", testFailCounter, " tests failed.\n"

    if len(testFails) > 0:
        echo "[>]"
        # Post-test output
        for msg in testFails:
            echo "[>] " & msg
        echo "[>]"
        quit(1)
except:
    let e = getCurrentException()
    echo "[-] Suite failed. Error happened: ", e.msg
    quit(1)
