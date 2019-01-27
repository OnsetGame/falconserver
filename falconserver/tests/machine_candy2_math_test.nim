import unittest

import tests
import falconserver.slot.machine_base
import falconserver.slot.machine_candy2

doTests:
    const lines = LINE_COUNT

    template spinCandy(bet: int64, stage: Stage, field:seq[int8]):seq[SpinResult] =
        checkCond(checkField(field), "Spin field check failed!")
        newSlotMachineCandy2(slotMachineDesc("falconserver/resources/slot_007_candy2.zsm")).getFullSpinResult(nil, bet div lines, lines, stage, field, "")

    template hasBonusGame(spinRes: seq[SpinResult]):bool = spinRes.len == 2

    template payoutForLine(spinRes: seq[SpinResult], line:int): tuple[payout: int64, symbols: int] =
        checkCond(line < lines, "Incorrect line")
        (payout: spinRes[0].lines[line].payout, symbols: spinRes[0].lines[line].numberOfWinningSymbols)

    template getTotalPayout(spinRes:seq[SpinResult], bet:int64):int64 =
        newSlotMachineCandy2(slotMachineDesc("falconserver/resources/slot_007_candy2.zsm")).getFinalPayout(bet, spinRes)

    var spinRes: seq[SpinResult]

    test:
        let bet = 1000'i64
        let betPerLine = bet div lines
        let wildSpin = @[0.int8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        spinRes = spinCandy(bet, Stage.Spin, wildSpin)

        checkCond(spinRes.len > 0, "Machine broken")
        checkCond(not hasBonusGame(spinRes), "No bonus in this field!")

        let line1Payout = payoutForLine(spinRes, 1)
        checkCond(line1Payout.payout == 100, "Incorrect payout for wild")
        checkCond(getTotalPayout(spinRes, betPerLine) == 100 * lines * betPerLine - bet, "Incorrect math")

    test:
        let bonusSpin = @[1.int8, 2, 3, 4, 5, 6, 7, 8, 9, 1, 2, 2, 5, 5, 6]
        spinRes = spinCandy(1000'i64, Stage.Spin, bonusSpin)

        checkCond(spinRes.len > 0, "Machine broken")
        checkCond(hasBonusGame(spinRes), "Bonus game is broken!")
