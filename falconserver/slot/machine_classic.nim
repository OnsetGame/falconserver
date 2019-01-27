## Classic Slot Machine model implementation.
import json
import tables
import math
import falconserver.auth.profile_random
# import coverage

import machine_base
import slot_data_types

const ReelCountClassic* = 5
    ## Number of Eiffel Tower slot machine reels (columns on field)

type BonusDishes*  = enum
    X2,
    X3,
    X4,
    Croissant,
    Soup,
    Ratatouille,
    Cheese,
    CremeBrulee

type SlotMachineClassic* = ref object of SlotMachine
    ## Classic Slot Machine model: `Eiffel tower slot`
    freespinTrigger: ItemObj
    freespinCountReleation: seq[tuple[triggerCount: int, freespinCount: int]]
    bonusTrigger: ItemObj
    bonusCountRelation: int
    bonusConfigRelation: seq[int]

type SpinResult* = ref object of RootObj
    stage*: Stage
    field*: seq[int8]
    lines*: seq[WinningLine]
    freeSpinsCount*: int
    freeSpinsTotalWin*: int64
    jackpot*: bool

method getSlotID*(sm: SlotMachineClassic): string =
    result = "a"

method getBigwinMultipliers*(sm: SlotMachineClassic): seq[int] =
    result = @[10, 15, 25]

method itemSetDefault*(sm: SlotMachineClassic): ItemSet =
    ## Generate default Item Set for Cows and UFO slot as of design document
    @[
        ItemObj(id:  0, kind: IWild,   name: "WILD"),
        ItemObj(id:  1, kind: IScatter,name: "SCATTER"),
        ItemObj(id:  2, kind: IBonus,  name: "BONUS"),
        ItemObj(id:  3, kind: ISimple, name: "man"),
        ItemObj(id:  4, kind: ISimple, name: "woman"),
        ItemObj(id:  5, kind: ISimple, name: "myme"),
        ItemObj(id:  6, kind: ISimple, name: "A"),
        ItemObj(id:  7, kind: ISimple, name: "Q"),
        ItemObj(id:  8, kind: ISimple, name: "J"),
        ItemObj(id:  9, kind: IBonus,  name: "10"),
        ItemObj(id: 10, kind: IWild,   name: "9"),

    ]

method reelCount*(sm: SlotMachineClassic): int = ReelCountClassic
    ## Number of slot machine reels

proc newSlotMachineClassic*(): SlotMachineClassic =
    ## Constructor of Empty Eiffel Tower Slot machine
    result.new
    result.initSlotMachine()

proc parseBonusAndFreespinConfig(sm: SlotMachineClassic, jMachine: JsonNode) =
    proc getFromItemset(name: string): ItemObj =
        var i = 0
        for item in sm.items:
            if item.name == name: return item
            inc i
        assert i == sm.items.len-1

    var jRecord: JsonNode
    jRecord = jMachine["freespin_trigger"]
    sm.freespinTrigger = getFromItemset(jRecord["id"].getStr())

    jRecord = jMachine["freespin_count"]
    sm.freespinCountReleation = @[]
    for el in jRecord:
        sm.freespinCountReleation.add((el["trigger_count"].getInt(), el["freespin_count"].getInt()))

    jRecord = jMachine["bonus_trigger"]
    sm.bonusTrigger = getFromItemset(jRecord["id"].getStr())

    jRecord = jMachine["bonus_count"]
    sm.bonusCountRelation = jRecord["trigger_count"].getInt()

    jRecord = jMachine["bonus_config"]
    sm.bonusConfigRelation = @[]
    sm.bonusConfigRelation.add(jRecord["X2"].getInt())
    sm.bonusConfigRelation.add(jRecord["X3"].getInt())
    sm.bonusConfigRelation.add(jRecord["X4"].getInt())
    sm.bonusConfigRelation.add(jRecord["Croissant"].getInt())
    sm.bonusConfigRelation.add(jRecord["Soup"].getInt())
    sm.bonusConfigRelation.add(jRecord["Ratatouille"].getInt())
    sm.bonusConfigRelation.add(jRecord["Cheese"].getInt())
    sm.bonusConfigRelation.add(jRecord["CremeBrulee"].getInt())

proc newSlotMachineClassic*(jMachine: JsonNode): SlotMachineClassic =
    ## Constructor of Eiffel Tower slot from Json Object
    result.new
    result.initSlotMachine(jMachine)
    result.parseBonusAndFreespinConfig(jMachine)

when declared(parseFile):
    proc newSlotMachineClassic*(filename: string): SlotMachineClassic =
        ## Constructor of Eiffel Tower Slot machine from ZSM file
        result.new
        result.initSlotMachine(filename)

method combinations*(sm: SlotMachineClassic, field: openarray[int8], lineCount: int): seq[Combination] =
    return sm.combinations(sm.reels, field, lineCount)

method numberOfNewFreeSpins*(sm: SlotMachineClassic, field: openarray[int8]): int =
    var dummyx, dummyy: int
    proc freespCount(symbCount: int): int =
        for el in sm.freespinCountReleation:
            if symbCount == el.triggerCount:
                return el.freespinCount
    result = freespCount(sm.countSymbolsOfType(field, sm.freespinTrigger.kind, dummyx, dummyy))

method canStartBonusGame*(sm: SlotMachineClassic, field: openarray[int8]): bool =
    ## Checks if slot-machine field initiates bonus game.
    var dummyx, dummyy: int
    result = sm.countSymbolsOfType(field, sm.bonusTrigger.kind, dummyx, dummyy) >= sm.bonusCountRelation

proc getDishPrice*(sm: SlotMachineClassic, dish: BonusDishes): int64 =
    result = sm.bonusConfigRelation[dish.int]

proc getPayoutForBonusGame*(sm: SlotMachineClassic, dishes: openarray[int8], bet: int64): int64 =
    for i in 0..<dishes.len:
        let cost = sm.getDishPrice(dishes[i].BonusDishes)
        if dishes[i].BonusDishes > X4.BonusDishes:
            result += cost
        else:
            result *= cost
    result *= bet

proc runBonusGame*(sm: SlotMachineClassic, p: Profile): seq[int8] =
    const DISHES_COUNT = 8
    const EMPTY_COUNT = 3
    const MULTIPLIERS_THRESHOLD = 2

    var
        dishes = @[Croissant, Ratatouille, Soup, Cheese, CremeBrulee, X2, X3, X4]
        rand = p.random(DISHES_COUNT - EMPTY_COUNT)
        dishesResult = @[dishes[rand].int8]
        length = DISHES_COUNT - 1
        multCount = 0

    dishes.del(rand)
    while length > 0 and multCount != MULTIPLIERS_THRESHOLD:
        rand = p.random(length)
        case dishes[rand]:
        of X2, X3, X4: inc multCount
        else: discard
        dishesResult.add(dishes[rand].int8)
        dishes.del(rand)
        length.dec()

    return dishesResult

proc spin*(sm: SlotMachineClassic, p: Profile, stage: Stage, bet:int64, lineCount: int): tuple[field: seq[int8], lines: seq[WinningLine], jackpot: bool] =
    var jackpot = false
    case stage
    of Stage.Spin:
        var res  = sm.spin(p, sm.reels, bet, lineCount, jackpot)
        result.field = res.field
        result.lines = res.lines
        result.jackpot = jackpot
    of Stage.Freespin:
        var res = sm.spin(p, sm.reelsFreespin, bet, lineCount, jackpot)
        result.field = res.field
        result.lines = res.lines
        result.jackpot = jackpot
    else:
        echo "not implemented"
    # echo "spin_res: ", result.field

proc createStageResult(sm: SlotMachineClassic, p: Profile, stage: Stage, bet:int64, lineCount: int, cheatSpin: seq[int8]): SpinResult =
    result.new()

    if cheatSpin.len != 0:
        var jackpot = false
        result.field = cheatSpin
        result.lines = sm.payouts(sm.combinations(cheatSpin, lineCount), jackpot)
        result.jackpot = jackpot

    elif stage == Stage.Bonus:
        result.field = sm.runBonusGame(p)
    else:
        let spin = sm.spin(p, stage, bet, lineCount)

        result.field = spin.field
        result.lines = spin.lines
        result.jackpot = spin.jackpot
    result.stage = stage
    result.freeSpinsCount = -1

proc getPayout*(bet: int64, r: SpinResult): int64 =
    if r.stage == Stage.Spin:
        result -= r.lines.len.int64 * bet
    if r.stage != Stage.Bonus:
        for ln in r.lines:
            result += ln.payout.int64 * bet

proc getFinalPayout*(bet: int64, res: openarray[SpinResult]): int64 =
    for r in res:
        result += getPayout(bet, r)

proc getFullSpinResult*(sm: SlotMachineClassic, p: Profile, bet: int64, lineCount: int, freeSpins: var int, freeSpinsTotalWin: var int64, cheatSpin: seq[int8]): seq[SpinResult] =
    result = @[]
    var stage = if freeSpins > 0: Stage.FreeSpin
                            else: Stage.Spin
    let mainSpin = sm.createStageResult(p, stage, bet, lineCount, cheatSpin)

    var freeSpinsCount = sm.numberOfNewFreeSpins(mainSpin.field)
    freeSpins += freeSpinsCount
    mainSpin.freeSpinsCount = freeSpins
    if stage == Stage.FreeSpin:
        freeSpinsTotalWin += getFinalPayout(bet, [mainSpin])
        mainSpin.freeSpinsTotalWin = freeSpinsTotalWin

    result.add(mainSpin)

    if sm.canStartBonusGame(mainSpin.field):
        result.add(sm.createStageResult(p, Stage.Bonus, bet, lineCount, @[]))

proc createResponse*(machine: SlotMachineClassic, spin: openarray[SpinResult], initialBalance: int64, bet: int64): JsonNode =
    result = newJObject()
    var res = newJArray()

    var freeSpins = 0
    var bonusPayout: int64 = 0
    for s in spin:
        var stageResult = newJObject()
        stageResult[$srtStage] = %($(s.stage))
        var field = newJArray()
        for n in s.field:
            field.add(%n)

        stageResult[$srtField] = field

        if s.stage != Stage.Bonus:
            stageResult[$srtLines] = winToJson(s.lines, bet)
            stageResult[$srtJackpot] = %s.jackpot
        if s.stage == Stage.FreeSpin:
            stageResult[$srtFreespinTotalWin] = %s.freeSpinsTotalWin
        if s.stage == Stage.Bonus:
            bonusPayout = machine.getPayoutForBonusGame(s.field, bet)
            stageResult[$srtPayout] = %bonusPayout
        res.add(stageResult)
        if s.freeSpinsCount >= 0:
            freeSpins = s.freeSpinsCount

    let payout = getFinalPayout(bet, spin) + bonusPayout
    let balance = initialBalance + payout
    result[$srtChips] = %balance
    result[$srtFreespinCount] = %freeSpins
    result[$srtStages] = res

method paytableToJson*(sm: SlotMachineClassic): JsonNode =
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
