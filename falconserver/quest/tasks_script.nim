import times
import nimongo.bson

import falconserver.quest.quest_task
import falconserver.auth.gameplay_config
import falconserver.auth.profile_types
import falconserver.slot.machine_base

import shafa.slot.slot_data_types

#[
    MAP TASKS
]#

proc buildTask(gconf: GameplayConfig, qt: QuestTask, data: Bson)=
    if data[$qdfCompleteTime].isNil: return

    let ct = epochTime()

    let compTime = data[$qdfCompleteTime].toFloat64() - ct
    if compTime <= 0.0:
        qt.completeProgress()

registerTask(qttBuild, buildTask)
registerTask(qttUpgrade, buildTask)

#[
    LEVEL UP
]#

registerTask(qttLevelUp) do (gconf: GameplayConfig, qt: QuestTask, data: Bson):
    if data[$qdfOldLvl].isNil or data[$prfLevel].isNil or data[$prfExperience].isNil:
        return
    else:
        let curExp = data[$prfExperience].toInt64().uint64
        if data[$qdfOldLvl].toInt() != data[$prfLevel].toInt():
            qt.completeProgress()
        else:
            qt.setCurrentProgress(curExp)

#[
    SLOT TASKS
]#
registerTask(qttSpinNTimes) do(gconf: GameplayConfig, qt: QuestTask, data: JsonNode):
    if "stages" in data["res"]:
        let stage = data["res"]["stages"][0]
        if stage["stage"].getStr() == "Spin":
            qt.incProgress(1)

registerTask(qttSpinNTimesMaxBet) do(gconf: GameplayConfig, qt: QuestTask, data: JsonNode):
    if "stages" in data["res"]:
        let stage = data["res"]["stages"][0]
        if stage["stage"].getStr() == "Spin":
            let betLevel = data{"betLevel"}.getInt()
            let playerLevel = data{"plvl"}.getInt()
            let gb = gconf.getGameBalance()
            var maxBetIndx = 0
            while maxBetIndx < gb.betsFromLevel.len - 1 and playerLevel >= gb.betsFromLevel[maxBetIndx + 1]:
                inc maxBetIndx

            if betLevel == maxBetIndx:
                qt.incProgress(1)

proc totalLinesWin(jStage: JsonNode):int64=
    let jLines = jStage["lines"]
    if not jLines.isNil:
        for li in jLines:
            result += li["payout"].getBiggestInt()


registerTask(qttWinChipOnSpins) do(gconf: GameplayConfig, qt: QuestTask, data: JsonNode):
    if "stages" in data["res"]:
        let stage = data["res"]["stages"][0]
        if stage["stage"].getStr() == "Spin" or stage["stage"].getStr() == "Respin":
            let totalWin = stage.totalLinesWin()
            qt.incProgress(totalWin)


registerTask(qttWinBonusTimes) do(gconf: GameplayConfig, qt: QuestTask, data:JsonNode):
    if "stages" in data["res"]:
        let stages = data["res"]["stages"]
        if (stages.len > 1 and stages[1]["stage"].getStr() == "Bonus") or stages[0]["stage"].getStr() == "Bonus":
            qt.incProgress(1)


registerTask(qttWinFreespinsCount) do(gconf: GameplayConfig, qt: QuestTask, data: JsonNode):
    if "stages" in data["res"]:
        let stage = data["res"]["stages"][0]
        if stage["stage"].getStr() == "FreeSpin":
            qt.incProgress(1)


registerTask(qttWinChipOnFreespins) do(gconf: GameplayConfig, qt: QuestTask, data: JsonNode):
    if "stages" in data["res"]:
        let stage = data["res"]["stages"][0]
        if stage["stage"].getStr() == "FreeSpin":
            let totalWin = stage.totalLinesWin()
            qt.incProgress(totalWin)


registerTask(qttWinChipsOnBonus) do(gconf: GameplayConfig, qt: QuestTask, data: JsonNode):
    if "stages" in data["res"]:
        var bonusWin = -1.int64
        let stages = data["res"]["stages"]

        if (stages.len > 1 and stages[1]["stage"].getStr() == "Bonus"):
            bonusWin = stages[1]["payout"].getBiggestInt()
        elif stages[0]["stage"].getStr() == "Bonus":
            bonusWin = stages[0]["payout"].getBiggestInt()

        if bonusWin > 0:
            qt.incProgress(bonusWin)


registerTask(qttMakeWinSpins) do(gconf: GameplayConfig, qt: QuestTask, data: JsonNode):
    if "stages" in data["res"]:
        let stage = data["res"]["stages"][0]
        if stage["stage"].getStr() == "Spin" and stage["lines"].len > 0:
            qt.incProgress(1)


proc bigWinMult(bi: BuildingId): float=
    case bi:
    of dreamTowerSlot: result = 10.0
    of candySlot:      result = 10.0
    of balloonSlot:    result = 8.0
    else:
        result = 25.0


registerTask(qttWinBigWins) do(gconf: GameplayConfig, qt: QuestTask, data: JsonNode):
    if "stages" in data["res"]:
        let stage = data["res"]["stages"][0]
        let betLevel = data["betLevel"].getInt()
        let totalWin = stage.totalLinesWin()
        let bet = gconf.getGameBalance().bets[betLevel]
        if (totalWin div bet).float >= bigWinMult(qt.target):
            qt.incProgress(1)


registerTask(qttWinNChips) do(gconf: GameplayConfig, qt: QuestTask, data: JsonNode):
    # echo "jdata ", data
    if "stages" in data["res"]:
        var allStagesWin = 0.int64
        for stage in data["res"]["stages"]:
            if stage["stage"].getStr() == "Bonus":
                allStagesWin += stage["payout"].getBiggestInt()
            else:
                allStagesWin += stage.totalLinesWin()

        if allStagesWin > 0:
            qt.incProgress(allStagesWin)


proc linesCountTask(numberOfSymbols: int) : proc(gconf: GameplayConfig, qt: QuestTask, data: JsonNode)=
    result = proc(gconf: GameplayConfig, qt: QuestTask, data: JsonNode) =
        if "stages" in data["res"]:
            var stage = data["res"]["stages"][0]
            if stage["stage"].getStr() != "Bonus":
                var lines = 0
                let jLines = stage["lines"]

                if not jLines.isNil:
                    for li in jLines:
                        if li["symbols"].getInt() >= numberOfSymbols:
                            inc lines

                if lines > 0:
                    qt.incProgress(lines)


registerTask(qttWinN5InRow, linesCountTask(5))
registerTask(qttWinN4InRow, linesCountTask(4))
registerTask(qttWinN3InRow, linesCountTask(3))


registerTask(qttMakeNRespins) do(gconf: GameplayConfig, qt: QuestTask, data: JsonNode):
    if "stages" in data["res"]:
        var stage = data["res"]["stages"][0]
        if stage["stage"].getStr() == "Respin":
            qt.incProgress(1)


proc numberOfSymbolsInField(jField: JsonNode, symb: int):int=
    for ji in jField:
        if ji.getInt() == symb:
            inc result


proc symbolIdFromSlotMachine(kind: ItemKind, bi: BuildingId): int=
    result = -1
    let slotMachine = getSlotMachineByGameID($bi)
    if not slotMachine.isNil:
        for item in slotMachine.items:
            if item.kind == kind:
                return item.id


proc scatterSymbOnSlot(bi: BuildingId): int=
    result = symbolIdFromSlotMachine(IScatter, bi)


proc bonusSymbOnSlot(bi: BuildingId): int =
    result = symbolIdFromSlotMachine(IBonus, bi)

proc adjustHiSymbol(bi: BuildingId): int =
    if bi == cardSlot:
        result = -2

proc hi0SymbOnSlot(bi: BuildingId): int =
    result = 3
    result += adjustHiSymbol(bi)

proc hi1SymbOnSlot(bi: BuildingId): int =
    result = 4
    result += adjustHiSymbol(bi)


proc hi2SymbOnSlot(bi: BuildingId): int =
    result = 5
    result += adjustHiSymbol(bi)

proc hi3SymbOnSlot(bi: BuildingId): int =
    result = 6
    result += adjustHiSymbol(bi)


proc wildSymbOnSlot(bi: BuildingId): int =
    if bi == BuildingId.ufoSlot: # Ufo wild symbols calculations in collectSymbols
        return 0

    result = symbolIdFromSlotMachine(IWild, bi)
    if result == -1:
        result = 0
    let wild2Count = symbolIdFromSlotMachine(IWild2, bi)
    if wild2Count > 0:
        result += wild2Count


proc collectSymbols(selector: proc(bi: BuildingId):int): proc(gconf: GameplayConfig, qt: QuestTask, data: JsonNode)=
    result = proc(gconf: GameplayConfig, qt: QuestTask, data: JsonNode)=
        if "stages" in data["res"]:
            let symb = selector(qt.target)
            if symb >= 0:
                for stage in data["res"]["stages"]:
                    if stage["stage"].getStr() != "Bonus" and "field" in stage:
                        var symbsCount = 0
                        if "destructions" in stage:
                            symbsCount = numberOfSymbolsInField(stage["destructions"], symb)
                        elif "wildApears" in stage and qt.kind == qttCollectWild:
                            symbsCount = stage["wildApears"].len # for ufo wilds
                        else:
                            symbsCount = numberOfSymbolsInField(stage["field"], symb)
                        if symbsCount > 0:
                            qt.incProgress(symbsCount)

registerTask(qttCollectScatters, collectSymbols(scatterSymbOnSlot))

registerTask(qttCollectBonus, collectSymbols(bonusSymbOnSlot))

registerTask(qttCollectWild, collectSymbols(wildSymbOnSlot))

registerTask(qttCollectHi0, collectSymbols(hi0SymbOnSlot))

registerTask(qttCollectHi1, collectSymbols(hi1SymbOnSlot))

registerTask(qttCollectHi2, collectSymbols(hi2SymbOnSlot))

registerTask(qttCollectHi3, collectSymbols(hi3SymbOnSlot))

registerTask(qttPolymorphNSymbolsIntoWild) do(gconf: GameplayConfig, qt: QuestTask, data: JsonNode):
    if "stages" in data["res"]:
        let stage = data["res"]["stages"][0]
        if stage["stage"].getStr() != "Bonus" and "wi" in stage:
            let wilen = stage["wi"].len
            if wilen > 0:
                qt.incProgress(wilen)


proc calcUniqWinSymbolsInLines(bi: BuildingId, jStage: JsonNode): int=
    let machine = getSlotMachineByGameID($bi)
    if not machine.isNil and "lines" in jStage:
        var uniqSyms = newSeq[string]()
        let confLines = machine.lines
        let jLines = jStage["lines"]

        for li in jLines:
            let lindex = li["index"].getInt()
            let winSymbs = li["symbols"].getInt()
            let lineIndex = lindex mod confLines.len ## Hello UFO vs COWS ;)
            let winLine = confLines[lineIndex]

            for i in 0 ..< winSymbs:
                var symbpos = ""
                if lineIndex > confLines.len: # must be reversed line
                    symbpos = $(5 - i) & "_" & $winLine[5 - i]
                else:
                    symbpos = $i & "_" & $winLine[i]

                if symbpos notin uniqSyms:
                    uniqSyms.add(symbpos)

        result = uniqSyms.len

registerTask(qttBlowNBalloon) do(gconf: GameplayConfig, qt: QuestTask, data: JsonNode):
    if "stages" in data["res"]:
        let stage = data["res"]["stages"][0]
        if stage["stage"].getStr() != "Bonus":
            let destrSyms = calcUniqWinSymbolsInLines(qt.target, stage)
            if destrSyms > 0:
                qt.incProgress(destrSyms)

registerTask(qttGroovyBars) do(gconf: GameplayConfig, qt: QuestTask, data: JsonNode):
    if "stages" in data["res"]:
        let stage = data["res"]["stages"][0]
        var barsScore = 0
        if "field" in stage:
            for v in stage["field"]:
                case v.getInt():
                of 8:
                    barsScore += 3
                of 10:
                    barsScore += 1
                of 9:
                    barsScore += 2
                else:
                    discard
        if barsScore > 0:
            qt.incProgress(barsScore)

registerTask(qttGroovySevens) do(gconf: GameplayConfig, qt: QuestTask, data: JsonNode):
    if "stages" in data["res"]:
        let stage = data["res"]["stages"][0]
        var sevens = 0
        if "field" in stage:
            for v in stage["field"]:
                case v.getInt():
                of 5,6,7:
                    sevens += 1
                else: discard
        if sevens > 0:
            qt.incProgress(sevens)

proc groovyLemons(bi: BuildingId): int =
    result = 1

registerTask(qttGroovyLemons, collectSymbols(groovyLemons))


proc groovyCheries(bi: BuildingId): int =
    result = 2

registerTask(qttGroovyCherries, collectSymbols(groovyCheries))

proc collectFreespinMode(mode: string): proc(gconf: GameplayConfig, qt: QuestTask, data: JsonNode) =
    result = proc(gconf: GameplayConfig, qt: QuestTask, data: JsonNode) =
        if "stages" in data["res"]:
            let stage = data["res"]["stages"][0]

            if $srtCardFreespinsType in stage:
                if stage[$srtCardFreespinsType].getStr() == mode:
                    qt.incProgress(1)

proc collectLenSequence(sName: string): proc(gconf: GameplayConfig, qt: QuestTask, data: JsonNode) =
    result = proc(gconf: GameplayConfig, qt: QuestTask, data: JsonNode) =
        if "stages" in data["res"]:
            let stage = data["res"]["stages"][0]

            if $sName in stage:
                qt.incProgress(stage[sName].len)


registerTask(qttShuffle, collectFreespinMode("Shuffle"))
registerTask(qttCollectMultipliers, collectFreespinMode("Multiplier"))
registerTask(qttCollectHidden, collectLenSequence($srtHiddenElems))
registerTask(qttWinNLines, collectLenSequence($srtLines))

