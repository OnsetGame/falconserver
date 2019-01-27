import unittest

import tests
import falconserver.slot.machine_base
import falconserver.slot.machine_classic

doTests:
    var
        ftw:int64 = 0
        freeSpins:int = 0

    const lines = 20

    template spinEiffel(bet: int64, field:seq[int8]):seq[SpinResult] =
        checkCond(checkField(field), "Spin field check failed!")
        freeSpins = 0
        ftw = 0'i64
        newSlotMachineClassic(slotMachineDesc("falconserver/resources/slot_001_dreamtower.zsm")).getFullSpinResult(nil, bet div lines, lines, freeSpins, ftw, field)

    template hasBonusGame(spinRes: seq[SpinResult]):bool = spinRes.len == 2

    template payoutForLine(spinRes: seq[SpinResult], line:int): tuple[payout: int64, symbols: int] =
        checkCond(line < lines, "Incorect lines")
        (payout: spinRes[0].lines[line].payout, symbols: spinRes[0].lines[line].numberOfWinningSymbols)

    template getTotalPayout(spinRes:seq[SpinResult],bet:int64):int64 =
        getFinalPayout(bet, spinRes) #machine_classic

    var spinRes: seq[SpinResult]

    test:
        let bet = 1000'i64
        let betPerLine = bet div lines
        let wildSpin = @[0.int8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        spinRes = spinEiffel(bet, wildSpin)

        checkCond(spinRes.len > 0, "Machine broken")
        checkCond(not hasBonusGame(spinRes), "No bonus in this field!")
        let line9Payout = payoutForLine(spinRes, 9)

        checkCond(line9Payout.payout == 5000, "Incorrect payout for wild")
        checkCond(getTotalPayout(spinRes, betPerLine) == 5000 * lines * betPerLine - bet, "Incorrect math")

    test:
        let bonusSpin = @[1.int8, 2, 3, 4, 5, 6, 7, 8, 9, 1, 2, 2, 5, 5, 6]
        spinRes = spinEiffel(1000'i64, bonusSpin)

        checkCond(spinRes.len > 0, "Machine broken")
        checkCond(hasBonusGame(spinRes), "Bonus game is broken!")

    test:
        let freeSpin = @[1.int8, 2, 3, 4, 5, 6, 7, 8, 9, 1, 1, 2, 5, 5, 6]
        spinRes = spinEiffel(1000'i64, freeSpin)

        checkCond(spinRes.len > 0, "Machine broken")
        checkCond(freeSpins > 0, "Freespins broken")

