import json, sequtils, strutils

import falconserver.auth.profile_random
import machine_card_types
export machine_card_types
import machine_base
import slot_data_types

proc reelToIndexes(reel: int): seq[int] =
    result = @[]
    for i in countup(reel, ELEMENTS_COUNT - 1, NUMBER_OF_REELS):
        result.add(i)

proc parseZsmConfig(sm: SlotMachineCard, jMachine: JsonNode) =
    var jRecord: JsonNode

    sm.wildsFeatureChances = @[]
    sm.hiddenChances = @[]

    var summ: float
    jRecord = jMachine["wilds_feature_chances"]
    for el in jRecord:
        summ += el["chance"].getFloat()
        sm.wildsFeatureChances.add((el["multiplier"].getInt(), summ))

    sm.freespins = jMachine["freespins_count"].getInt()

    summ = 0.0
    jRecord = jMachine["hidden_chances"]
    for k, v in jRecord:
        let id = k.parseInt()
        let c = v.getFloat(0.0)
        summ += c
        sm.hiddenChances.add((id:id, chance:summ))

method itemSetDefault*(sm: SlotMachineCard): ItemSet =
    @[
        ItemObj(id:  0, kind: IWild, name: "Wild"),
        ItemObj(id:  1, kind: ISimple, name: "Big1"),
        ItemObj(id:  2, kind: ISimple,  name: "Big2"),
        ItemObj(id:  3, kind: ISimple, name: "Big3"),
        ItemObj(id:  4, kind: ISimple, name: "Big4"),
        ItemObj(id:  5, kind: ISimple, name: "Low1"),
        ItemObj(id:  6, kind: ISimple, name: "Low2"),
        ItemObj(id:  7, kind: ISimple, name: "Low3"),
        ItemObj(id:  8, kind: ISimple, name: "Low4"),
        ItemObj(id:  9, kind: ISimple, name: "Hidden"),
        ItemObj(id:  10, kind: ISimple, name: "WildFeature"),
    ]

proc newSlotMachineCard*(): SlotMachineCard =
    result.new()
    result.initSlotMachine()

proc newSlotMachineCard*(jMachine: JsonNode): SlotMachineCard =
    result.new()
    result.initSlotMachine(jMachine)
    result.parseZsmConfig(jMachine)
    result.reelsHidden = result.getReels(jMachine, "reels_hidden")
    result.reelsMultiplier = result.getReels(jMachine, "reels_multiplier")
    result.reelsShuffle = result.getReels(jMachine, "reels_shuffle")

method getSlotID*(sm: SlotMachineCard): string =
    return "i"

method getBigwinMultipliers*(sm: SlotMachineCard): seq[int] =
    result = @[10, 13, 17]

method paytableToJson*(sm: SlotMachineCard): JsonNode =
    result = procCall sm.SlotMachine.paytableToJson()

proc getPayout*(sm: SlotMachineCard, bet: int64, r: SpinResult): int64 =
    if r.stage == Stage.Spin:
        result -= bet * LINE_COUNT
    for ln in r.lines:
        result += ln.payout * bet * sm.linesMultiplier

proc getFinalPayout*(sm: SlotMachineCard, bet: int64, res: openarray[SpinResult]): int64 =
    for r in res:
        result += sm.getPayout(bet, r)

method combinations*(sm: SlotMachineCard, field: openarray[int8], lineCount: int): seq[Combination] =
    result = sm.combinations(sm.reels, field, lineCount)

proc replaceHiddenInFreespins(sm: SlotMachineCard, field: var seq[int8], lines: var seq[WinningLine]) =
    const HIDDEN = 9'i8
    sm.hiddenIndexes = @[]

    if field.contains(HIDDEN):
        const LOWEST = 8'i8
        const HIGHEST = 1'i8
        var maxPayout: int64

        for i in 0..field.high:
            if field[i] == HIDDEN:
                sm.hiddenIndexes.add(i)

        var tempField = field
        var tempLines = lines
        for el in countdown(LOWEST, HIGHEST):
            var sum: int64

            for i in sm.hiddenIndexes:
                tempField[i] = el
            tempLines = sm.payouts(sm.combinations(tempField, LINE_COUNT))

            for line in tempLines:
                sum += line.payout

            if sum >= maxPayout:
                maxPayout = sum
                field = tempField
                lines = tempLines

proc replaceHiddenInSpins(sm: SlotMachineCard, dice: float, field: var seq[int8], lines: var seq[WinningLine]) =
    const HIDDEN = 9'i8
    sm.hiddenIndexes = @[]

    if field.contains(HIDDEN):
        for i in 0..field.high:
            if field[i] == HIDDEN:
                sm.hiddenIndexes.add(i)

        for conf in sm.hiddenChances:
            if dice < conf.chance:
                for i in sm.hiddenIndexes:
                    field[i] = conf.id.int8
                lines = sm.payouts(sm.combinations(field, LINE_COUNT))
                return

proc checkFreespins(sm: SlotMachineCard, field: seq[int8])=
    const SCATTER_FEATURE = 11'i8
    let amount = field.count(SCATTER_FEATURE)
    if amount >= 3:
        sm.winFreespins = true

proc resolveWildFreespinFeature(sm: SlotMachineCard, p: Profile, field: seq[int8], lines: var seq[WinningLine]) =
    const SUN_FEATURE = 10'i8
    const WILD_FEATURE = 0'i8

    if field.contains(SUN_FEATURE):
        let randFeature = p.random(100.0)

        var tmpField = field
        for i, v in field:
            if v == SUN_FEATURE:
                tmpField[i] = WILD_FEATURE

        lines = sm.payouts(sm.combinations(tmpField, LINE_COUNT))

        for conf in sm.wildsFeatureChances:
            if randFeature < conf[1]:
                sm.linesMultiplier = conf[0]
                break

proc swapReels(field: seq[int8], tmpl: seq[int]): seq[int8] =
    result = field

    for r in 0 ..< NUMBER_OF_REELS:
        let t = tmpl[r]
        let indexes = reelToIndexes(r)
        let tIndexes = reelToIndexes(t)

        for i in 0..indexes.high:
            result[indexes[i]] = field[tIndexes[i]]

proc swap(reels: var seq[int], x, y: int) =
    let temp = reels[x]
    reels[x] = reels[y]
    reels[y] = temp

proc permuteReels(sm: SlotMachineCard, field: seq[int8], reels: var seq[int], l, r: int) =
    var i: int

    if l == r:
        let newField = swapReels(field, reels)
        let newLines = sm.payouts(sm.combinations(newField, LINE_COUNT))
        var sum: int64

        for ln in newLines:
            sum += ln.payout

        if sum > sm.maxPayout:
            sm.maxPayout = sum
            sm.permutedField = newField
            sm.permutedLines = newLines
    else:
        for i in l..r:
            swap(reels, l, i)
            sm.permuteReels(field, reels, l + 1, r)
            swap(reels, l, i)

proc spin*(sm: SlotMachineCard, p: Profile, stage: Stage, bet:int64, lineCount: int, cheatSpin: seq[int8], cheatName: string): tuple[field: seq[int8], lines: seq[WinningLine]] =
    sm.winFreespins = false
    sm.linesMultiplier = 1
    sm.maxPayout = 0
    sm.permutedField = @[]
    sm.permutedLines = @[]
    sm.hiddenIndexes = @[]

    if cheatSpin.len != 0:
        result.field = cheatSpin
        result.lines = sm.payouts(sm.combinations(cheatSpin, lineCount))
        sm.checkFreespins(result.field)
    else:
        if stage == Stage.FreeSpin:
            if sm.fsType == FreespinsType.Hidden:
                result = sm.spin(p, sm.reelsHidden, bet, lineCount)
                sm.replaceHiddenInFreespins(result.field, result.lines)

            elif sm.fsType == FreespinsType.Multiplier:
                result = sm.spin(p, sm.reelsMultiplier, bet, lineCount)
                sm.resolveWildFreespinFeature(p, result.field, result.lines)

            # elif sm.fsType == FreespinsType.Shuffle:
            else:
                var reels = toSeq(0..4)
                result = sm.spin(p, sm.reelsShuffle, bet, lineCount)
                sm.permuteReels(result.field, reels, 0, reels.high)
                result.field = sm.permutedField
                result.lines = sm.permutedLines
        else:
            result = sm.spin(p, sm.reels, bet, lineCount)
            sm.checkFreespins(result.field)
            sm.replaceHiddenInSpins(p.random(100.0), result.field, result.lines)

proc createStageResult(sm: SlotMachineCard, p: Profile, stage: Stage, bet: int64, cheatSpin: seq[int8], cheatName: string): SpinResult =
    result.new()

    let spin = sm.spin(p, stage, bet, LINE_COUNT, cheatSpin, cheatName)

    result.field = spin.field
    result.lines = spin.lines
    result.stage = stage

proc createResponse*(sm: SlotMachineCard, spin: openarray[SpinResult], initialBalance, bet: int64, freespinsTotalWin: int64): JsonNode =
    result = newJObject()
    var res = newJArray()

    for s in spin:
        var stageResult = newJObject()
        var field = newJArray()
        var hi = newJArray()

        stageResult[$srtStage] = %($(s.stage))

        for n in s.field:
            field.add(%n)

        for h in sm.hiddenIndexes:
            hi.add(%h)

        stageResult[$srtField] = field
        stageResult[$srtHiddenElems] = hi
        stageResult[$srtCardFreespinsType] = %sm.fsType
        if s.lines.len != 0:
            stageResult[$srtLines] = winToJson(s.lines, bet * sm.linesMultiplier)

        res.add(stageResult)

    let balance = initialBalance + sm.getFinalPayout(bet, spin)
    result[$srtChips] = %balance
    result[$srtFreespinCount] = %sm.freeSpinsCount
    result[$srtFreespinTotalWin] = %freespinsTotalWin
    result[$srtBet] = %(bet * LINE_COUNT)
    result[$srtLinesMultiplier] = %sm.linesMultiplier
    result[$srtWinFreespins] = %sm.winFreespins
    result[$srtStages] = res

proc getFullSpinResult*(sm: SlotMachineCard, p: Profile, bet:int64, lineCount: int, stage: Stage, cheatSpin: seq[int8], cheatName: string): seq[SpinResult] =
    return @[sm.createStageResult(p, stage, bet, cheatSpin, cheatName)]

