import unittest
import tests
import falconserver.slot.machine_base
import falconserver.slot.machine_groovy

doTests:
    const lines = 25

    template spinGroovy(prevBet, betPerLine: int, rd: var GroovyRestoreData, field:seq[int8]): SpinResult =
        checkCond(checkField(field), "Spin field check failed!")
        newSlotMachineGroovy(slotMachineDesc("falconserver/resources/slot_008_groovy.zsm")).getSpinResult(nil, prevBet, betPerLine, lines, rd, field)

    var spinRes: SpinResult
    var rd: GroovyRestoreData
    rd.sevenWildInReel = newSeq[bool](newSlotMachineGroovy(slotMachineDesc("falconserver/resources/slot_008_groovy.zsm")).reelCount)

    let bet = 5000
    let betPerLine = bet div lines

    proc hasWon(spinRes: SpinResult, st: Stage): bool =
        if spinRes.stage != st:
            return false
        for ln in spinRes.lines:
            if ln.payout > 0:
                return true
        return false

    test: # nowin
        let noWinSpin = @[9.int8,1,1,1,1,6,1,1,1,1,7,1,1,1,1]
        spinRes = spinGroovy(betPerLine, betPerLine, rd, noWinSpin)
        checkCond(not spinRes.hasWon(Stage.Spin), "win error")

    test: # bars freespin
        let winSpinBars = @[9.int8,9,9,1,1,6,1,1,1,1,7,1,1,1,1]
        spinRes = spinGroovy(betPerLine, betPerLine, rd, winSpinBars)
        checkCond(spinRes.hasWon(Stage.Spin), "no win error 1")
        checkCond(rd.barsFreespinProgress == 1, "bar progress 1 error")

        spinRes = spinGroovy(betPerLine, betPerLine, rd, winSpinBars)
        checkCond(spinRes.hasWon(Stage.Spin), "no win error 2")
        checkCond(rd.barsFreespinProgress == 2, "bar progress 2 error")

        spinRes = spinGroovy(betPerLine, betPerLine, rd, winSpinBars)
        checkCond(spinRes.hasWon(Stage.Freespin), "no win error 3")
        checkCond(rd.barsFreespinCount == 10, "bar freespins error")
        checkCond(rd.barsFreespinProgress == 0, "bar progress 0 error")


    test: # sevens freespin
        rd.barsFreespinCount = 0

        var winSpinSevens = @[5.int8,5,5,1,1,6,1,1,1,1,7,1,1,1,1]
        spinRes = spinGroovy(betPerLine, betPerLine, rd, winSpinSevens)
        checkCond(spinRes.hasWon(Stage.Spin), "no win error 1")
        checkCond(rd.sevensFreespinProgress == 1, "sevens progress 1 error")

        winSpinSevens = @[5.int8,5,10,2,8,6,6,2,3,1,7,7,4,10,2]
        spinRes = spinGroovy(betPerLine, betPerLine, rd, winSpinSevens)
        checkCond(spinRes.hasWon(Stage.Respin), "no win error 2")
        checkCond(rd.sevensFreespinProgress == 2, "sevens progress 2 error")

        winSpinSevens = @[5.int8,5,9,2,1,6,6,3,3,2,7,7,10,10,10]
        spinRes = spinGroovy(betPerLine, betPerLine, rd, winSpinSevens)
        checkCond(spinRes.hasWon(Stage.Respin), "no win error 3")
        checkCond(rd.sevensFreespinProgress == 3, "sevens progress 3 error")

        spinRes = spinGroovy(betPerLine, betPerLine, rd, winSpinSevens)
        checkCond(spinRes.hasWon(Stage.Freespin), "no win error 4")
        checkCond(rd.sevensFreespinProgress == 0, "sevens progress 4 error")
        checkCond(rd.sevensFreespinCount == 10, "sevens freespins error")
