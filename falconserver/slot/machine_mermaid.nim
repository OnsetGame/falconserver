## Classic Slot Machine model implementation.
import json
import tables
import math
import falconserver.auth.profile_random
# import coverage

import machine_base
import slot_data_types

type
    MermaidHorizontalPosition* = enum
        posLeft = 0
        posCenterLeft
        posCenterRight
        posRight
        posMiss
        posStand

    MermaidVerticalPosition* = enum
        posCenter = 0
        posUp
        posDown

    MermaidPosition* = tuple
        horizontal: MermaidHorizontalPosition
        vertical: MermaidVerticalPosition

    MermaidMultiposition* = enum
        posLeft_posCenterRight = 0
        posLeft_posRight
        posCenterLeft_posRight
        posLeft_posCenterLeft
        posCenterLeft_posCenterRight
        posCenterRight_posRight

    SpinResult* = ref object of RootObj
        stage*: Stage
        field*: seq[int8]
        bonusField*: seq[int64]
        lines*: seq[WinningLine]
        freeSpinsCount*: int
        freeSpinsTotalWin*: int64
        jackpot*: bool
    SlotMachineMermaid* = ref object of SlotMachine
        wildId: int8
        wildMultiplier*: int

        freespinTrigger: ItemObj
        freespinCountReleation: seq[tuple[triggerCount: int, freespinCount: int]]
        bonusTrigger: ItemObj
        bonusCountRelation: int
        bonusConfigRelation: seq[int]
        bonusWinningCount: int

        spinHorizontalPos: array[6, int]
        spinVerticalPos: array[3, int]
        freespinHorizontalPos: array[6, int]
        freespinVerticalPos: array[3, int]
        freespinDoubleMermaidPos: array[6, int]

const horisontalMatrix = [
    [1, 1, 0, 0, 0, 1, 1, 0, 0, 0, 1, 1, 0, 0, 0], # posLeft
    [0, 1, 1, 0, 0, 0, 1, 1, 0, 0, 0, 1, 1, 0, 0], # posCenterLeft
    [0, 0, 1, 1, 0, 0, 0, 1, 1, 0, 0, 0, 1, 1, 0], # posCenterRight
    [0, 0, 0, 1, 1, 0, 0, 0, 1, 1, 0, 0, 0, 1, 1]  # posRight
]

const verticalMatrix = [
    [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], # posCenter
    [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0], # posUp
    [0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]  # posDown
]

const multiWilds = [
    [posLeft, posCenterRight],
    [posLeft, posRight],
    [posCenterLeft, posRight],
    [posLeft, posCenterLeft],
    [posCenterLeft, posCenterRight],
    [posCenterRight, posRight]
]

const multiWildsMatrix = [
    [1, 1, 1, 1, 0, 1, 1, 1, 1, 0, 1, 1, 1, 1, 0],
    [1, 1, 0, 1, 1, 1, 1, 0, 1, 1, 1, 1, 0, 1, 1],
    [0, 1, 1, 1, 1, 0, 1, 1, 1, 1, 0, 1, 1, 1, 1],
    [1, 1, 1, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1, 0, 0], # x2
    [0, 1, 1, 1, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1, 0], # x2
    [0, 0, 1, 1, 1, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1]  # x2
]

method getSlotID*(sm: SlotMachineMermaid): string =
    result = "f"

method getBigwinMultipliers*(sm: SlotMachineMermaid): seq[int] =
    result = @[10, 13, 15]

method itemSetDefault*(sm: SlotMachineMermaid): ItemSet =
    @[
        ItemObj(id:  0, kind: IWild   , name: "wild" ), # Wild (Wild)
        ItemObj(id:  1, kind: IScatter, name: "king" ), # Scatter (King)
        ItemObj(id:  2, kind: IBonus  , name: "prince" ), # Bonus (Prince)
        ItemObj(id:  3, kind: ISimple , name: "star" ), # Star
        ItemObj(id:  4, kind: ISimple , name: "fish" ), # Fish
        ItemObj(id:  5, kind: ISimple , name: "turtle" ), # Turtle
        ItemObj(id:  6, kind: ISimple , name: "dolphin" ), # Dolphin
        ItemObj(id:  7, kind: ISimple , name: "seahorse" ), # seahorse
        ItemObj(id:  8, kind: ISimple , name: "chest1"), # Chest1
        ItemObj(id:  9, kind: ISimple , name: "chest2"), # Chest2
        ItemObj(id: 10, kind: ISimple , name: "ship" ), # Ship
        ItemObj(id: 11, kind: ISimple , name: "necklace"), # Necklace
        ItemObj(id: 12, kind: ISimple , name: "pearl"), # Pearl
        ItemObj(id: 13, kind: IWild2  , name: "wildx2")  # Wildx2 (x2)
    ]

method reelCount*(sm: SlotMachineMermaid): int = 5 ## Number of Mermaid slot machine reels (columns on field)

proc newSlotMachineMermaid*(): SlotMachineMermaid =
    ## Constructor of Empty Slot machine
    result.new()
    result.initSlotMachine()
    result.wildId = 0

proc parseCustomZsmConfig(sm: SlotMachineMermaid, jMachine: JsonNode) =
    proc getFromItemset(name: string): ItemObj =
        for item in sm.items:
            if item.name == name: return item

    # Freespins config
    sm.freespinTrigger = getFromItemset(jMachine{"freespin_config", "freespin_trigger", "id"}.getStr("king"))
    let freespRelation = jMachine{"freespin_config", "freespin_count"}
    if not freespRelation.isNil:
        sm.freespinCountReleation = @[]
        for el in freespRelation:
            sm.freespinCountReleation.add((el["trigger_count"].getInt(3), el["freespin_count"].getInt(5)))
    else:
        sm.freespinCountReleation = @[(3, 5), (4, 7), (5, 10)]

    # Bonus config
    sm.bonusTrigger = getFromItemset(jMachine{"bonus_config", "bonus_trigger", "id"}.getStr("prince"))
    sm.bonusCountRelation = jMachine{"bonus_config", "bonus_count", "trigger_count"}.getInt(2)
    let bonusRelation = jMachine{"bonus_config", "bonus_payouts"}
    if not bonusRelation.isNil:
        sm.bonusConfigRelation = @[]
        for el in bonusRelation:
            sm.bonusConfigRelation.add(el.getInt(5))
    else:
        sm.bonusConfigRelation = @[12.int, 8, 8, 5, 5, 5, 5, 3, 3]
    sm.bonusWinningCount = jMachine{"bonus_config", "bonus_winning_count"}.getInt(3)

    # wilds config
    proc setup(arr: var openarray[int], j: JsonNode, T: typedesc[enum], default: openarray[int]) =
        var prev = 100
        for el in T:
            let curr = prev - j{$el}.getInt(default[el.int])
            arr[el.int] = curr
            prev = curr

    # setup wild id
    let wildName = jMachine{"wild_config", "wild_trigger", "id"}.getStr("wild")
    for i, item in sm.items:
        if item.name == wildName:
            sm.wildId = i.int8
            break
    # setup wild pos on spin
    sm.spinHorizontalPos.setup(jMachine{"wild_config", "spin", "horisontal"}, MermaidHorizontalPosition, [2, 4, 6, 8, 40, 40])
    sm.spinVerticalPos.setup(jMachine{"wild_config", "spin", "vertical"}, MermaidVerticalPosition, [10, 45, 45])
    # setup wild pos on freespin
    sm.freespinDoubleMermaidPos.setup(jMachine{"wild_config", "freespin", "double_mermaid"}, MermaidMultiposition, [17, 17, 17, 16, 16, 17])
    sm.freespinHorizontalPos.setup(jMachine{"wild_config", "freespin", "horisontal"}, MermaidHorizontalPosition, [2, 4, 6, 8, 80, 0])
    sm.freespinVerticalPos.setup(jMachine{"wild_config", "freespin", "vertical"}, MermaidVerticalPosition, [10, 45, 45])

proc newSlotMachineMermaid*(jMachine: JsonNode): SlotMachineMermaid =
    ## Constructor of slot from Json Object
    result.new()
    result.initSlotMachine(jMachine)
    result.parseCustomZsmConfig(jMachine)

when declared(parseFile):
    proc newSlotMachineMermaid*(filename: string): SlotMachineMermaid =
        ## Constructor of slot machine from ZSM file
        result.new()
        result.initSlotMachine(filename)
        result.wildId = 0

method combinations*(sm: SlotMachineMermaid, field: openarray[int8], lineCount: int): seq[Combination] =
    return sm.combinations(sm.reels, field, lineCount)

method numberOfNewFreeSpins*(sm: SlotMachineMermaid, field: openarray[int8]): int =
    var dummyx, dummyy: int
    let symbCount = sm.countSymbolsOfType(field, sm.freespinTrigger.kind, dummyx, dummyy)
    for el in sm.freespinCountReleation:
        if symbCount == el.triggerCount:
            return el.freespinCount

method canStartBonusGame*(sm: SlotMachineMermaid, field: openarray[int8]): bool =
    ## Checks if slot-machine field initiates bonus game.
    var dummyx, dummyy: int
    result = sm.countSymbolsOfType(field, sm.bonusTrigger.kind, dummyx, dummyy) >= sm.bonusCountRelation

proc isBonusOrFreespins(sm: SlotMachineMermaid, field: openarray[int8]): bool =
    result = sm.numberOfNewFreeSpins(field) > 0 or sm.canStartBonusGame(field)

proc getPayoutForBonusGame*(sm: SlotMachineMermaid, chests: openarray[int64]): int64 =
    for i in 0..<sm.bonusWinningCount: result += chests[i].int64

proc runBonusGame*(sm: SlotMachineMermaid, p: Profile, totalBet: int64): seq[int64] =
    var bonusObjects = sm.bonusConfigRelation
    var res = newSeq[int64](bonusObjects.len)
    for i in 0..<res.len:
        let rnd = p.random(bonusObjects.len)
        res[i] = totalBet * bonusObjects[rnd]
        bonusObjects.del(rnd)
    return res

proc getPosId(p: Profile, positions: openarray[int]): int =
    let rand = p.random(100)
    for i, v in positions:
        if rand >= v:
            result = i
            break

proc getAndSetWild(p: Profile, field: var seq[int8], horPositions: openarray[int], vertPositions: openarray[int], wildId: int8): MermaidPosition =
    let horPos = p.getPosId(horPositions).MermaidHorizontalPosition
    var vertPos: MermaidVerticalPosition
    if horPos != posMiss and horPos != posStand:
        vertPos = p.getPosId(vertPositions).MermaidVerticalPosition
        for i in 0..<field.len:
            let isWild = horisontalMatrix[horPos.int][i] * verticalMatrix[vertPos.int][i]
            if isWild == 1: field[i] = wildId
    else:
        vertPos = posCenter

    return (horPos, vertPos)

proc setSpinWild(sm: SlotMachineMermaid, p: Profile, field: var seq[int8]): MermaidPosition =
    result = p.getAndSetWild(field, sm.spinHorizontalPos, sm.spinVerticalPos, sm.wildId)

proc setFreeSpinWild(sm: SlotMachineMermaid, p: Profile, field: var seq[int8]): MermaidPosition =
    result = p.getAndSetWild(field, sm.freespinHorizontalPos, sm.freespinVerticalPos, sm.wildId)

proc spin*(sm: SlotMachineMermaid, p: Profile, stage: Stage, bet: int64, lineCount: int): tuple[field: seq[int8], lines: seq[WinningLine], jackpot: bool, mermaidPos: seq[MermaidPosition]] =
    var jackpot = false

    result.mermaidPos = @[]
    var field: seq[int8]
    var lines: seq[WinningLine]

    case stage
    of Stage.Spin:
        field = sm.reels.spin(p, sm.fieldHeight)
        if sm.isBonusOrFreespins(field):
            result.mermaidPos.add(((if p.random(2) == 1: posMiss else: posStand), posCenter))
        else:
            result.mermaidPos.add(sm.setSpinWild(p, field)) # here swap field elems with mermaid wilds, do not replace
        lines = sm.payouts(sm.combinations(field, lineCount), jackpot)
    of Stage.Freespin:
        field = sm.reelsFreespin.spin(p, sm.fieldHeight)

        if sm.wildMultiplier == 0:
            sm.wildMultiplier = p.random(1..sm.freespinCount+1)

        if sm.wildMultiplier == sm.freespinCount:

            let sid = p.getPosId(sm.freespinDoubleMermaidPos)

            result.mermaidPos.add((multiWilds[sid][0], posCenter))
            result.mermaidPos.add((multiWilds[sid][1], posCenter))

            for i in 0..<field.len:
                if multiWildsMatrix[sid][i] == 1: field[i] = sm.wildId

            lines = sm.payouts(sm.combinations(field, lineCount), jackpot)

            if sid >= 3:
                for i in 0..<lines.len:
                    lines[i] = (lines[i].numberOfWinningSymbols, lines[i].payout * 2)
        else:
            if sm.isBonusOrFreespins(field):
                result.mermaidPos.add((posMiss, posCenter))
                result.mermaidPos.add((posMiss, posCenter))
            else:
                let winMermaid = p.random(2)
                if winMermaid == 0:
                    result.mermaidPos.add((posMiss, posCenter))
                    result.mermaidPos.add(sm.setFreeSpinWild(p, field))
                else:
                    result.mermaidPos.add(sm.setFreeSpinWild(p, field))
                    result.mermaidPos.add((posMiss, posCenter))

            lines = sm.payouts(sm.combinations(field, lineCount), jackpot)

        if sm.freespinCount == 1:
            sm.wildMultiplier = 0
    else:
        echo "not implemented"

    result.field = field
    result.lines = lines
    result.jackpot = jackpot

proc createStageResult(sm: SlotMachineMermaid, p: Profile, stage: Stage, bet: int64, lineCount: int, cheatSpin: seq[int8]): tuple[spin: SpinResult, mermaidPos: seq[MermaidPosition]] =
    var sp: SpinResult
    sp.new()

    if cheatSpin.len != 0:
        var jackpot = false
        sp.field = cheatSpin
        sp.lines = sm.payouts(sm.combinations(cheatSpin, lineCount), jackpot)
        sp.jackpot = jackpot
    elif stage == Stage.Bonus:
        sp.bonusField = sm.runBonusGame(p, bet * lineCount)
    else:
        let spin = sm.spin(p, stage, bet, lineCount)
        sp.field = spin.field
        sp.lines = spin.lines
        sp.jackpot = spin.jackpot
        result.mermaidPos = spin.mermaidPos
    sp.stage = stage
    sp.freeSpinsCount = -1
    result.spin = sp

proc getPayout*(bet: int64, r: SpinResult): int64 =
    if r.stage == Stage.Spin:
        result -= r.lines.len * bet
    if r.stage != Stage.Bonus:
        for ln in r.lines:
            if ln.payout > 0:
                result += ln.payout * bet

proc getFinalPayout*(bet: int64, res: openarray[SpinResult]): int64 =
    for r in res:
        result += getPayout(bet, r)

proc getFullSpinResult*(sm: SlotMachineMermaid, p: Profile, bet: int64, lineCount: int, freeSpins: var int, freeSpinsTotalWin: var int64, cheatSpin: seq[int8]): tuple[spin: seq[SpinResult], mermaidPos: seq[MermaidPosition]] =
    sm.freespinCount = freeSpins

    result.spin = @[]
    var stage = if freeSpins > 0: Stage.FreeSpin else: Stage.Spin
    let mainSpin = sm.createStageResult(p, stage, bet, lineCount, cheatSpin)

    var freeSpinsCount = sm.numberOfNewFreeSpins(mainSpin.spin.field)
    freeSpins += freeSpinsCount
    mainSpin.spin.freeSpinsCount = freeSpins
    if stage == Stage.FreeSpin:
        freeSpinsTotalWin += getFinalPayout(bet, [mainSpin.spin])
        mainSpin.spin.freeSpinsTotalWin = freeSpinsTotalWin

    result.spin.add(mainSpin.spin)
    result.mermaidPos = mainSpin.mermaidPos

    if sm.canStartBonusGame(mainSpin.spin.field):
        result.spin.add(sm.createStageResult(p, Stage.Bonus, bet, lineCount, @[]).spin)

proc createResponse*(machine: SlotMachineMermaid, spin: openarray[SpinResult], mermaidPos: seq[MermaidPosition], initialBalance: int64, bet: int64, lineCount: int): JsonNode =
    result = newJObject()
    var res = newJArray()

    var mermaidPositions = newJArray()
    for pos in mermaidPos:
        var p = newJArray()
        p.add(%pos.horizontal.int)
        p.add(%pos.vertical.int)
        mermaidPositions.add(p)
    result[$srtMermaidPos] = mermaidPositions

    var freeSpins = 0
    var bonusPayout: int64 = 0
    for s in spin:
        var stageResult = newJObject()
        stageResult[$srtStage] = %($(s.stage))
        var field = newJArray()

        if s.stage != Stage.Bonus:
            for n in s.field:
                field.add(%n)
        else:
            for n in s.bonusField:
                field.add(%n)

        stageResult[$srtField] = field

        if s.stage != Stage.Bonus:
            stageResult[$srtLines] = winToJson(s.lines, bet)
            stageResult[$srtJackpot] = %s.jackpot
        if s.stage == Stage.FreeSpin:
            stageResult[$srtFreespinTotalWin] = %s.freeSpinsTotalWin
        if s.stage == Stage.Bonus:
            bonusPayout = machine.getPayoutForBonusGame(s.bonusField)
            stageResult[$srtPayout] = %bonusPayout
        res.add(stageResult)
        if s.freeSpinsCount >= 0:
            freeSpins = s.freeSpinsCount

    let payout = getFinalPayout(bet, spin) + bonusPayout
    let balance = initialBalance + payout
    result[$srtChips] = %balance
    result[$srtFreespinCount] = %freeSpins
    result[$srtStages] = res

method paytableToJson*(sm: SlotMachineMermaid): JsonNode =
    result = procCall sm.SlotMachine.paytableToJson()
    result.add("freespin_trigger", %sm.freespinTrigger.name)
    let jRelation = newJArray()
    for el in sm.freespinCountReleation:
        let j = newJObject()
        j["trigger_count"] = %el.triggerCount
        j["freespin_count"] = %el.freespinCount
        jRelation.add(j)
    result.add("freespin_count", jRelation)
    result.add("bonus_trigger", %sm.bonusTrigger.name)
    result.add("bonus_count", %sm.bonusCountRelation)
    result.add("bonus_config", %sm.bonusConfigRelation)
