import json
import tables
import sequtils
import math
import falconserver.auth.profile_random
# import coverage
import machine_base
import slot_data_types

const ReelCountGroovy* = 5

const reelTestEnabled = false

type GroovyRestoreData* = tuple
    sevensFreespinCount: int
    sevensFreespinTotalWin: int64
    barsFreespinCount: int
    barsFreespinTotalWin: int64
    barsFreespinProgress: int
    sevensFreespinProgress: int
    sevenWildInReel: seq[bool]

type SlotMachineGroovy* = ref object of SlotMachine
    reelsFreespinBars: Layout

    sevensInReelTrigger: int
    sevensFreespinTrigger: int
    totalSevensFreespinCount: int
    sevensIds: seq[int8]

    barsFreespinTrigger: int
    totalBarsFreespinCount: int
    barsPayout: seq[int]
    barsIds: seq[int8]

type SpinResult* = ref object of RootObj
    stage*: Stage
    field*: seq[int8]
    lines*: seq[WinningLine]

method getSlotID*(sm: SlotMachineGroovy): string =
    result = "h"

method getBigwinMultipliers*(sm: SlotMachineGroovy): seq[int] =
    result = @[7, 10, 14]

method itemSetDefault*(sm: SlotMachineGroovy): ItemSet =
    @[
        ItemObj(id:  1, kind: IWild,   name: "wild"),
        ItemObj(id:  2, kind: ISimple, name: "lemon"),
        ItemObj(id:  3, kind: ISimple, name: "grape"),
        ItemObj(id:  4, kind: ISimple, name: "melon"),
        ItemObj(id:  5, kind: ISimple, name: "cherry"),
        ItemObj(id:  6, kind: ISimple, name: "7red"),
        ItemObj(id:  7, kind: ISimple, name: "7green"),
        ItemObj(id:  8, kind: ISimple, name: "7blue"),
        ItemObj(id:  9, kind: ISimple, name: "3bar"),
        ItemObj(id: 10, kind: ISimple, name: "2bar"),
        ItemObj(id: 11, kind: ISimple, name: "1bar"),
        ItemObj(id: 12, kind: ISimple, name: "7wild"),
        ItemObj(id: 13, kind: ISimple, name: "7any"),
    ]

method reelCount*(sm: SlotMachineGroovy): int = ReelCountGroovy

proc newSlotMachineGroovy*(): SlotMachineGroovy =
    result.new
    result.initSlotMachine()

proc getFromItemset(sm: SlotMachineGroovy, name: string): ItemObj =
    var i = 0
    for item in sm.items:
        if item.name == name: return item
        inc i
    assert i == sm.items.len-1

proc parseBonusAndFreespinConfig(sm: SlotMachineGroovy, jMachine: JsonNode) =
    if jMachine.hasKey("bars_config"):
        var jRecord = jMachine["bars_config"]
        if jRecord.hasKey("barsFreespinTrigger"):
            sm.barsFreespinTrigger = jRecord["barsFreespinTrigger"].getInt()
        else:
            sm.barsFreespinTrigger = 2
        if jRecord.hasKey("totalBarsFreespinCount"):
            sm.totalBarsFreespinCount = jRecord["totalBarsFreespinCount"].getInt()
        else:
            sm.totalBarsFreespinCount = 10
        if jRecord.hasKey("barsIds"):
            var jArr = jRecord["barsIds"]
            sm.barsIds = @[]
            for el in jArr:
                sm.barsIds.add(sm.getFromItemset(el.getStr()).id)
        else:
            sm.barsIds = @[sm.getFromItemset("1bar").id, sm.getFromItemset("2bar").id, sm.getFromItemset("3bar").id]
        if jRecord.hasKey("barsPayout"):
            var jArr = jRecord["barsPayout"]
            sm.barsPayout = @[]
            for el in jArr:
                sm.barsPayout.add(el.getInt())
        else:
            sm.barsPayout = @[0,0,0,0,1,2,5,10,15,20,30,50,100,200,500,1000]
    else:
        sm.barsFreespinTrigger = 2
        sm.totalBarsFreespinCount = 10
        sm.barsIds = @[sm.getFromItemset("1bar").id, sm.getFromItemset("2bar").id, sm.getFromItemset("3bar").id]
        sm.barsPayout = @[0,0,0,0,1,2,5,10,15,20,30,50,100,200,500,1000]

    if jMachine.hasKey("sevens_config"):
        var jRecord = jMachine["sevens_config"]
        if jRecord.hasKey("sevensInReelTrigger"):
            sm.sevensInReelTrigger = jRecord["sevensInReelTrigger"].getInt()
        else:
            sm.sevensInReelTrigger = 3
        if jRecord.hasKey("sevensFreespinTrigger"):
            sm.sevensFreespinTrigger = jRecord["sevensFreespinTrigger"].getInt()
        else:
            sm.sevensFreespinTrigger = 3
        if jRecord.hasKey("totalSevensFreespinCount"):
            sm.totalSevensFreespinCount = jRecord["totalSevensFreespinCount"].getInt()
        else:
            sm.totalSevensFreespinCount = 10
        if jRecord.hasKey("sevensIds"):
            var jArr = jRecord["sevensIds"]
            sm.sevensIds = @[]
            for el in jArr:
                sm.sevensIds.add(sm.getFromItemset(el.getStr()).id)
        else:
            sm.sevensIds = @[sm.getFromItemset("7red").id, sm.getFromItemset("7green").id, sm.getFromItemset("7blue").id]
    else:
        sm.sevensInReelTrigger = 3
        sm.sevensFreespinTrigger = 3
        sm.totalSevensFreespinCount = 10
        sm.sevensIds = @[sm.getFromItemset("7red").id, sm.getFromItemset("7green").id, sm.getFromItemset("7blue").id]

proc newSlotMachineGroovy*(jMachine: JsonNode): SlotMachineGroovy =
    result.new
    result.initSlotMachine(jMachine)
    result.parseBonusAndFreespinConfig(jMachine)

    if jMachine.hasKey("reels_freespin_bars"):
        var jRecord = jMachine{"reels_freespin_bars"}
        if not jRecord.isNil:
            result.reelsFreespinBars.new
            result.reelsFreespinBars.reels = @[]
            for jReel in jRecord:
                var reel: Reel = @[]
                for item in jReel:
                    var id: int8 = 0
                    for i in result.items:
                        if i.name == item["id"].getStr():
                            id = i.id
                            break
                    reel.add(ItemObj(id: id, kind: ItemKind(item["type"].getInt()), name: item["id"].getStr()))
                result.reelsFreespinBars.reels.add(reel)

    when reelTestEnabled:
        proc compare(reels: seq[Reel], input: seq[seq[int]]) =
            for i, reel in reels:
                for j, elem in reel:
                    if (input[i][j]-1).int8 != elem.id:

                        echo "reel id: ", i, " el id: ", j, " el actual: ", elem.id, " el expected: ", (input[i][j]-1)

                        raise

        let reels = @[
            @[3,11,2,  5,9,3,  10,2,5,  4,11,2,  10,5,4,  9,3,10,  4,11,2,  3,11,6,  7,8,2,  3,4,5,  9,4,1,  11,2,5,  10,3,6,  7,8,5,  2,10,5,  2,3,10,  4,2,9],
            @[11,4,9,  3,10,2,  5,3,9,  11,2,10,  4,5,3,  11,5,2,  4,6,7,  8,11,2,  4,10,11,  4,9,5,  1,6,7,  8,5,2,  4,5,3,  9,2,5,  4,2,3,  11,4,3,  9,10,3],
            @[10,9,4,  6,7,8,  4,3,10,  5,9,3,  4,10,6,  7,8,2,  1,4,3,  10,2,5,  9,11,5,  2,9,5,  10,4,11,  2,10,4,  11,3,2,  5,11,3,  5,2,9,  3,11],
            @[10,8,3,  11,9,5,  11,2,7,  3,10,9,  2,11,10,  9,3,4,  11,5,7,  9,4,1,  9,2,4,  3,9,2,  8,10,11,  6,5,4,  10,3,2,  10,11,5,  6,4,5],
            @[2,5,10,  11,4,8,  9,2,3,  11,2,9,  6,11,5,  10,4,3,  8,11,9,  7,3,11,  4,10,3,  9,5,6,  9,2,10,  4,5,11,  4,3,10,  2,5,10,  9,7]
        ]

        let reelsRespin = @[
            @[3,11,2,  5,9,10,  2,5,9,  4,11,3,  6,7,8,  2,10,5,  4,9,3,  10,4,11,  2,9,3,  11,6,7,  8,2,3,  4,5,9,  4,1,11,  4,5,10,  3,5,6,  7,8,5,  2,10,3,  5,9,2,  3,10,4,  2,9],
            @[11,4,9,  3,10,6,  7,8,2,  5,3,9,  11,2,10,  4,5,3,  11,5,2,  4,6,7,  8,11,2,  4,10,11,  4,9,5,  1,6,7,  8,5,2,  4,5,3,  9,2,5,  4,2,3,  11,4,3,  9,10,3],
            @[10,9,4,  6,7,8,  4,3,10,  5,9,3,  4,10,6,  7,8,2,  1,4,3,  6,7,8,  10,2,5,  9,11,5,  2,6,7,  8,9,5,  10,4,11,  2,10,4,  11,3,6,  7,8,2,  5,11,3,  5,2,9,  3,11],
            @[10,8,3,  11,9,5,  11,2,7,  3,10,9,  2,11,10,  9,3,4,  11,5,7,  9,4,1,  9,2,4,  3,9,2,  8,10,11,  6,5,4,  10,3,2,  10,11,5,  6,4,5],
            @[2,5,10,  11,4,8,  9,2,3,  11,2,9,  6,11,5,  10,4,3,  8,11,9,  7,3,11,  4,10,3,  9,5,6,  9,2,10,  4,5,11,  4,3,10,  2,5,10,  9,7]
        ]

        let reelsFreespin = @[
            @[3,11,6,  5,9,7,  10,2,5,  8,4,11,  6,2,10,  1,5,4,  9,7,3,  10,6,4,  11,2,8,  3,11,6,  2,3,6,  4,5,7,  9,4,11,  5,8,10,  3,8,5,  2,7,10,  5,2,8,  3,10,7,  4,2,9],
            @[11,4,7,  9,3,7,  10,2,5,  8,3,9,  8,11,2,  1,10,4,  5,7,3,  11,6,5,  2,4,6,  11,2,6,  4,10,6,  11,4,7,  9,5,2,  4,6,5,  3,7,9,  2,5,8,  4,2,8,  3,11,8,  4,3,9,  5,10,3],
            @[10,6,9,  4,6,3,  10,8,5,  9,7,3,  4,6,10,  2,4,3,  10,8,2,  5,9,6,  11,5,6,  2,9,5,  7,10,4,  1,11,2,  8,10,4,  7,11,3,  2,8,5,  11,3,7,  5,2,4,  7,9,3,  8,11],
            @[10,8,3,  11,6,9,  5,6,11,  2,7,3,  10,7,9,  2,6,11,  10,8,9,  3,7,4,  11,5,7,  9,4,1,  9,2,8,  4,3,7,  9,2,8,  10,11,6,  5,4,10,  3,2,10,  8,11,1,  5,6,4,  5],
            @[2,5,10,  6,11,4,  8,9,2,  6,3,11,  7,2,9,  6,11,5,  6,10,4,  3,8,11,  9,7,3,  11,7,4,  10,7,3,  9,5,6,  9,2,8,  10,4,8,  5,11,4,  8,3,10,  2,5,10,  9,7]
        ]

        let reelsBarsFreespin = @[
            @[3,11,5,  9,7,3,  10,5,4,  11,2,8,  10,5,4,  9,3,10,  4,11,2,  3,11,6,  2,3,4,  5,9,4,  1,11,2,  5,10,3,  5,2,10,  5,2,1,  3,10,4,  2,9],
            @[11,4,9,  3,10,2,  5,9,11,  2,10,4,  5,3,11,  5,2,4,  6,11,2,  4,10,7,  11,4,9,  5,1,6,  5,2,4,  5,3,9,  2,8,5,  4,2,8,  3,11,4,  7,3,9,  10,3],
            @[10,9,4,  6,4,3,  10,7,5,  9,8,3,  4,10,6,  2,1,3,  10,2,5,  9,7,11,  5,2,9,  5,8,10,  4,11,2,  10,4,11,  3,2,5,  11,3,5,  2,9,3,  11],
            @[10,8,3,  11,9,5,  11,2,7,  3,10,9,  2,11,10,  9,3,4,  11,5,7,  9,4,1,  9,2,4,  3,9,2,  8,10,11,  6,4,10,  3,2,10,  11,5,6,  4,5],
            @[2,5,10,  11,4,8,  9,2,3,  11,2,9,  6,11,5,  10,4,3,  8,11,9,  7,3,11,  4,10,3,  9,5,6,  9,2,10,  4,5,11,  4,3,10,  2,5,10,  9,7]
        ]


        result.reels.reels.compare(reels)
        result.reelsRespin.reels.compare(reelsRespin)
        result.reelsFreespin.reels.compare(reelsFreespin)
        result.reelsFreespinBars.reels.compare(reelsBarsFreespin)

when declared(parseFile):
    proc newSlotMachineGroovy*(filename: string): SlotMachineGroovy =
        result.new
        result.initSlotMachine(filename)

method combinations*(sm: SlotMachineGroovy, field: openarray[int8], lineCount: int): seq[Combination] =
    return sm.combinations(sm.reels, field, lineCount)

proc countSymbolsOfIdInReel(sm: SlotMachine, field: openarray[int8], reel: int, ids: openarray[int8]): int =
    for j in 0 ..< sm.fieldHeight:
        let itemIndex = field[j * sm.reelCount + reel]
        if itemIndex >= 0 and sm.items[itemIndex].id in ids:
            inc result

proc detectNewWildSevens(sm: SlotMachineGroovy, field: openarray[int8], rd: var GroovyRestoreData): bool =
    for i in 0 ..< sm.reelCount:
        if not rd.sevenWildInReel[i] and sm.countSymbolsOfIdInReel(field, i, sm.sevensIds) >= sm.sevensInReelTrigger:
            rd.sevenWildInReel[i] = true
            result = true

proc replaceWildSevensWithId(sm: SlotMachineGroovy, field: var openarray[int8], rd: GroovyRestoreData, id: int8) =
    for i in 0..<rd.sevenWildInReel.len:
        if rd.sevenWildInReel[i]:
            for j in 0 ..< sm.fieldHeight:
                field[j * sm.reelCount + i] = id

proc restoreWildSevens(sm: SlotMachineGroovy, field: var openarray[int8], rd: GroovyRestoreData) =
    for i in 0..<rd.sevenWildInReel.len:
        if rd.sevenWildInReel[i]:
            for j in 0 ..< sm.fieldHeight:
                field[j * sm.reelCount + i] = sm.sevensIds[j]

proc resetWildSevens(sm: SlotMachineGroovy, rd: var GroovyRestoreData) =
    rd.sevenWildInReel = newSeq[bool](sm.reelCount)

proc replaceElemsWithId(sm: SlotMachineGroovy, field: var openarray[int8], elems: openarray[int8], id: int8) =
    for i in 0 ..< sm.reelCount:
        for j in 0 ..< sm.fieldHeight:
            if field[j * sm.reelCount + i] in elems:
                field[j * sm.reelCount + i] = id

proc replaceSevensWithId(sm: SlotMachineGroovy, field: var openarray[int8], id: int8) =
    for i in 0 ..< sm.reelCount:
        for j in 0 ..< sm.fieldHeight:
            if field[j * sm.reelCount + i] in sm.sevensIds:
                field[j * sm.reelCount + i] = id

proc mergeLines(sm: SlotMachineGroovy, lines: openarray[seq[WinningLine]]): seq[WinningLine] =
    result = lines[0]
    for i in 1..<lines.len:
        for j, ln in lines[i]:
            if ln.payout > result[j].payout:
                result[j] = ln

proc hasWild(rd: GroovyRestoreData): bool =
    for i in 0..<rd.sevenWildInReel.len:
        if rd.sevenWildInReel[i]:
            return true

proc mainLogic(sm: SlotMachineGroovy, field: openarray[int8], lineCount: int, stage: Stage, oldRd: var GroovyRestoreData): SpinResult =
    result.new()
    result.stage = stage
    result.field = @field

    if oldRd.hasWild():
        var fld = @field
        let hasNewSevenWilds = sm.detectNewWildSevens(fld, oldRd)

        sm.restoreWildSevens(fld, oldRd)
        result.field = fld
        let oldField = fld

        # var wildFiled = oldField
        # sm.replaceWildSevensWithId(wildFiled, oldRd, sm.getFromItemset("7wild").id)
        # let wildLines = sm.payouts(sm.combinations(wildFiled, lineCount))
        # wildFiled = oldField

        # sm.replaceWildSevensWithId(wildFiled, oldRd, sm.getFromItemset("7red").id)
        # let redLines = sm.payouts(sm.combinations(wildFiled, lineCount))
        # wildFiled = oldField

        # sm.replaceWildSevensWithId(wildFiled, oldRd, sm.getFromItemset("7green").id)
        # let greenLines = sm.payouts(sm.combinations(wildFiled, lineCount))
        # wildFiled = oldField

        # sm.replaceWildSevensWithId(wildFiled, oldRd, sm.getFromItemset("7blue").id)
        # let blueLines = sm.payouts(sm.combinations(wildFiled, lineCount))

        # result.lines = sm.mergeLines([wildLines, redLines, greenLines, blueLines])

        var anyFiled = oldField
        sm.replaceSevensWithId(anyFiled, sm.getFromItemset("7any").id)
        result.lines = sm.payouts(sm.combinations(anyFiled, lineCount))

        # # super wild fix
        # for i in 0..<result.lines.len:
        #     if oldRd.sevenWildInReel[0] and oldRd.sevenWildInReel[1] and result.lines[i].numberOfWinningSymbols == 2:
        #         result.lines[i].payout = 0

        if sm.hasLost(result.lines) and not hasNewSevenWilds:
            sm.resetWildSevens(oldRd)
            oldRd.sevensFreespinProgress = 0
        else:
            inc oldRd.sevensFreespinProgress
            if oldRd.sevensFreespinProgress >= sm.sevensFreespinTrigger:
                oldRd.sevensFreespinCount = sm.totalSevensFreespinCount
                sm.resetWildSevens(oldRd)
                # oldRd.sevensFreespinProgress = 0
    else:
        result.lines = sm.payouts(sm.combinations(result.field, lineCount))

        if oldRd.sevensFreespinCount > 0:

            oldRd.sevensFreespinProgress = 0

            var fld = @field
            sm.replaceSevensWithId(fld, sm.getFromItemset("7any").id)
            let anySevens = sm.payouts(sm.combinations(fld, lineCount))

            result.lines = sm.mergeLines([result.lines, anySevens])
        elif oldRd.barsFreespinCount > 0:

            oldRd.barsFreespinProgress = 0

            var fld = @field
            sm.replaceElemsWithId(fld, sm.barsIds, sm.getFromItemset("1bar").id)

            var oldPaytable: seq[seq[int]] = @[]
            for row in sm.paytable:
                oldPaytable.add(row)
            var lastRow = sm.paytable[sm.paytable.len-1]
            for i in 0..<lastRow.len:
                sm.paytable[sm.paytable.len-1][i] = 5

            var barsLines = sm.payouts(sm.combinations(fld, lineCount))

            for i in 0..<barsLines.len:
                var ln = barsLines[i]
                if ln.payout > 0:
                    var sum = 0
                    for k in 0..<ln.numberOfWinningSymbols:
                        let symb = result.field[k + sm.lines[i][k]*sm.reelCount]
                        if symb == sm.barsIds[0]: sum += 1
                        elif symb == sm.barsIds[1]: sum += 2
                        elif symb == sm.barsIds[2]: sum += 3
                        elif symb == sm.getFromItemset("wild").id: sum += 1 # wild as 1bar

                    barsLines[i].payout = sm.barsPayout[sum]

            result.lines = sm.mergeLines([result.lines, barsLines])

            sm.paytable = oldPaytable
        else:
            if sm.detectNewWildSevens(result.field, oldRd):
                inc oldRd.sevensFreespinProgress
            else:
                oldRd.sevensFreespinProgress = 0

            proc wasBarWin(field: openarray[int8], lines: seq[WinningLine], barsIds: seq[int8]): bool =
                for i, ln in lines:
                    if ln.payout > 0:
                        for k in 0..<ln.numberOfWinningSymbols:
                            if field[k + sm.lines[i][k]*sm.reelCount] in barsIds:
                                return true

            if wasBarWin(result.field, result.lines, sm.barsIds):
                inc oldRd.barsFreespinProgress
                if oldRd.barsFreespinProgress >= sm.barsFreespinTrigger:
                    oldRd.barsFreespinCount = sm.totalBarsFreespinCount
                    # oldRd.barsFreespinProgress = 0
            else:
                oldRd.barsFreespinProgress = 0

proc getPayout*(bet: int64, r: SpinResult): int64 =
    if r.stage == Stage.Spin:
        result -= r.lines.len.int64 * bet.int64
    for ln in r.lines:
        result += ln.payout.int64 * bet.int64

proc getFinalPayout*(bet: int64, res: openarray[SpinResult]): int64 =
    for r in res:
        result += getPayout(bet, r)

proc createResponse*(machine: SlotMachineGroovy, spin: openarray[SpinResult], initialBalance: int64, bet: int64, rd: GroovyRestoreData, stage: Stage): JsonNode =
    result = newJObject()
    var res = newJArray()
    var sevensFreespin: int
    var barsFreespins: int
    for s in spin:
        var stageResult = newJObject()
        stageResult[$srtStage] = %($(stage))
        var field = newJArray()
        for n in s.field:
            field.add(%n)

        stageResult[$srtField] = field

        stageResult[$srtLines] = winToJson(s.lines, bet)

        if rd.sevensFreespinCount > 0:
            sevensFreespin = rd.sevensFreespinCount
        if rd.barsFreespinCount > 0:
            barsFreespins = rd.barsFreespinCount

        stageResult[$strSevensFreespinTotalWin] = %rd.sevensFreespinTotalWin
        stageResult[$strBarsFreespinTotalWin] = %rd.barsFreespinTotalWin

        if rd.sevensFreespinTotalWin > 0:
            stageResult[$srtFreespinTotalWin] = %rd.sevensFreespinTotalWin
        elif rd.barsFreespinTotalWin > 0:
            stageResult[$srtFreespinTotalWin] = %rd.barsFreespinTotalWin
        else:
            stageResult[$srtFreespinTotalWin] = %0

        res.add(stageResult)

    let payout = getFinalPayout(bet, spin)
    let balance = initialBalance + payout
    result[$srtChips] = %balance
    result[$strSevensFreespinCount] = %sevensFreespin
    result[$strBarsFreespinCount] = %barsFreespins
    if sevensFreespin > 0:
        result[$srtFreespinCount] = %sevensFreespin
    elif barsFreespins > 0:
        result[$srtFreespinCount] = %barsFreespins
    else:
        result[$srtFreespinCount] = %0
    result[$strSevensFreespinProgress] = %rd.sevensFreespinProgress
    result[$strBarsFreespinProgress] = %rd.barsFreespinProgress
    result[$strBarsFreespinProgress] = %rd.barsFreespinProgress
    result[$srtRespinCount] = %rd.sevensFreespinProgress
    result[$srtStages] = res

proc getSpinResult*(sm: SlotMachineGroovy, p: Profile, prevBet, bet:int64, lineCount: int, rd: var GroovyRestoreData, cheatSpin: seq[int8]): SpinResult =
    let oldRd = rd

    var stage: Stage
    if oldRd.hasWild():
        stage = Stage.Respin
    else:
        stage = if (rd.sevensFreespinCount > 0 or rd.barsFreespinCount > 0): Stage.FreeSpin else: Stage.Spin

    if prevBet != bet:
        rd.barsFreespinProgress = 0
        rd.sevensFreespinProgress = 0

    var filed: seq[int8]
    if cheatSpin.len != 0:
        filed = cheatSpin
    elif stage == Stage.Respin:
        filed = sm.reelsRespin.spin(p, sm.fieldHeight)
    elif stage == Stage.Freespin:
        if rd.sevensFreespinCount > 0:
            filed = sm.reelsFreespin.spin(p, sm.fieldHeight)
        elif rd.barsFreespinCount > 0:
            filed = sm.reelsFreespinBars.spin(p, sm.fieldHeight)
        else:
            echo "GROOVY LOGICAL ERROR"
            filed = sm.reels.spin(p, sm.fieldHeight) # try not carsh
    else:
        filed = sm.reels.spin(p, sm.fieldHeight)

    result = sm.mainLogic(filed, lineCount, stage, rd)

proc getFullSpinResult*(sm: SlotMachineGroovy, p: Profile, prevBet, bet:int64, lineCount: int, rd: var GroovyRestoreData, cheatSpin: seq[int8]): JsonNode =
    let oldRd = rd
    let stage = if oldRd.hasWild(): Stage.Respin else: (if (rd.sevensFreespinCount > 0 or rd.barsFreespinCount > 0): Stage.FreeSpin else: Stage.Spin)
    let actualBet = if stage == Stage.Freespin: prevBet else: bet
    let mainSpin = getSpinResult(sm, p, prevBet, bet, lineCount, rd, cheatSpin)

    var newStage = stage
    if oldRd.sevensFreespinCount > 0:
        rd.sevensFreespinTotalWin += getFinalPayout(actualBet, [mainSpin])
        newStage = Stage.FreeSpin
    if oldRd.barsFreespinCount > 0:
        rd.barsFreespinTotalWin += getFinalPayout(actualBet, [mainSpin])
        newStage = Stage.FreeSpin

    result = sm.createResponse(@[mainSpin], p[$prfChips], actualBet, rd, newStage)

    proc checkFreespinCount(oldFreespins: int, freespinCount: var int, freespinTotalWin: var int64) =
        if freespinCount > 0:
            if oldFreespins > 0:
                dec freespinCount
                if freespinCount == 0:
                    freespinTotalWin = 0

    checkFreespinCount(oldRd.sevensFreespinCount, rd.sevensFreespinCount, rd.sevensFreespinTotalWin)
    checkFreespinCount(oldRd.barsFreespinCount, rd.barsFreespinCount, rd.barsFreespinTotalWin)

method paytableToJson*(sm: SlotMachineGroovy): JsonNode =
    result = procCall sm.SlotMachine.paytableToJson()
    result.add("barsFreespinTrigger", %sm.barsFreespinTrigger)
    result.add("totalBarsFreespinCount", %sm.totalBarsFreespinCount)
    let barsPayout = newJArray()
    for el in sm.barsPayout:
        barsPayout.add(%el)
    result.add("barsPayout", barsPayout)
    result.add("sevensInReelTrigger", %sm.sevensInReelTrigger)
    result.add("sevensFreespinTrigger", %sm.sevensFreespinTrigger)
    result.add("totalSevensFreespinCount", %sm.totalSevensFreespinCount)
