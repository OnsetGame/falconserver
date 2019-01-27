## Candy Slot Machine Model implementation
import json
import hashes
import falconserver.auth.profile_random

import machine_base
import slot_data_types

import machine_candy_types
export machine_candy_types

type SlotMachineCandy* = ref object of SlotMachine
    paidDish: int8
    freespinsMax*: int
    bonusMultipliers: seq[int]

method itemSetDefault*(sm: SlotMachineCandy): ItemSet =
    ## Generate default Item Set for Candy slot as of design document
    @[
        ItemObj(id:  0, kind: ISimple, name: "Wild"),
        ItemObj(id:  1, kind: IScatter, name: "Scatter"),
        ItemObj(id:  2, kind: IBonus,  name: "Bonus"),
        ItemObj(id:  3, kind: ISimple, name: "Cake1"),
        ItemObj(id:  4, kind: ISimple, name: "Cake2"),
        ItemObj(id:  5, kind: ISimple, name: "Cake3"),
        ItemObj(id:  6, kind: ISimple, name: "Cake4"),
        ItemObj(id:  7, kind: ISimple, name: "Candy1"),
        ItemObj(id:  8, kind: ISimple, name: "Candy2"),
        ItemObj(id:  9, kind: ISimple, name: "Candy3"),
        ItemObj(id:  10, kind: ISimple, name: "Candy4"),
    ]


proc parseZsmConfig(sm: SlotMachineCandy, jMachine: JsonNode) =
    var jRecord = jMachine["bonus_multipliers"]

    sm.bonusMultipliers = @[]
    sm.freespinsMax = jMachine["freespin_count"].getInt()
    for el in jRecord:
        sm.bonusMultipliers.add(el.getInt())

proc newSlotMachineCandy*(): SlotMachineCandy =
    ## Constructor for the Candy slot machine
    result.new
    result.initSlotMachine()

proc newSlotMachineCandy*(jMachine: JsonNode): SlotMachineCandy =
    ## Constructor for the Candy slot machine from ZSM format
    result.new
    result.initSlotMachine(jMachine)
    result.parseZsmConfig(jMachine)

when declared(parseFile):
    proc newSlotMachineCandy*(filename: string): SlotMachineCandy =
        ## Constructor for the Candy slot machine from file
        result.new
        result.initSlotMachine(filename)

method combinations*(sm: SlotMachineCandy, field: openarray[int8], lineCount: int): seq[Combination] =
    return sm.combinations(sm.reels, field, lineCount)

proc spin*(sm: SlotMachineCandy, p: Profile, stage: Stage, bet: int64, lineCount: int, cheatSpin: seq[int8], cheatName: string): tuple[field: seq[int8], wildIndexes: seq[int], lines: seq[WinningLine]] =
    const WILD = 0'i8
    const CAKE1 = 3'i8
    const CAKE4 = 6'i8
    const SCATTER = 1'i8

    let betPerLine = bet
    if cheatSpin.len != 0:

        result.field = cheatSpin
        result.lines = sm.payouts(sm.combinations(cheatSpin, lineCount))
        if cheatName == "freespins":
            if cheatSpin[4] != SCATTER and cheatSpin[4] != SCATTER and cheatSpin[9] != SCATTER and  cheatSpin[14] != SCATTER:
                result.field[14] = SCATTER
    else:
        var spinAux: tuple[field: seq[int8], lines: seq[WinningLine]]

        if stage == Stage.Spin:
            spinAux = sm.spin(p, sm.reels, betPerLine, lineCount)
        else:
            spinAux = sm.spin(p, sm.reelsFreespin, betPerLine, lineCount)

        result.field = spinAux.field
        result.lines = spinAux.lines

    result.wildIndexes = @[]
    #result.field[14] = 0'i8 #FOR DEBUG
    var newField = result.field

    if result.field.contains(WILD):
        for i in 0..<result.field.len:
            case result.field[i]
            of CAKE1..CAKE4:
                newField[i] = WILD
                result.wildIndexes.add(i)
            else: discard
        result.lines = sm.payouts(sm.combinations(newField, lineCount))

method getSlotID*(sm: SlotMachineCandy): string =
    return "d"

method getBigwinMultipliers*(sm: SlotMachineCandy): seq[int] =
    result = @[9, 11, 13]

method canStartBonusGame*(sm: SlotMachineCandy, field: openarray[int8]): bool =
    ## Checks if slot-machine field initiates bonus game.
    var dummyx, dummyy: int
    result = sm.countSymbolsOfType(field, IBonus, dummyx, dummyy) >= 3

proc getDishesValue(sm: SlotMachineCandy, p: Profile, totalBonusBet: int64): seq[int64] =
    var dishes = sm.bonusMultipliers
    var rand = p.random(3)
    result = @[]

    result.add(dishes[rand] * totalBonusBet)
    dishes.del(rand)
    rand = p.random(2)
    result.add(dishes[rand] * totalBonusBet)
    dishes.del(rand)
    result.add(dishes[0] * totalBonusBet)

proc runBonusGame(sm: SlotMachineCandy, p: Profile): seq[int8] =
    const MAX_COUNT = 7

    result = @[]
    for i in 0..<MAX_COUNT:
        let rand = p.random(BonusDishes.Icecream.int..BonusDishes.Cake.int+1)
        result.add(rand.int8)

        var count: int
        for elem in result:
            if elem == rand:
                count.inc()
            if count > 2:
                sm.paidDish = elem
                return result

proc getBonusGameResult(sm: SlotMachineCandy, p: Profile, totalBonusBet: int64): tuple[field: seq[int8], dishesValue: seq[int64]] =
    result.dishesValue = sm.getDishesValue(p, totalBonusBet)
    result.field = sm.runBonusGame(p)

proc getBonusGamePayout*(sm: SlotMachineCandy, field: openarray[int8], dishesValue: openarray[int64]): int64 =
    result = dishesValue[sm.paidDish]

proc numberOfNewScatters*(sm: SlotMachineCandy, field: openarray[int8]): int =
    var dummyx, dummyy: int
    result = sm.countSymbolsOfType(field, IScatter, dummyx, dummyy)

proc createStageResult(sm: SlotMachineCandy, p: Profile, stage: Stage, bet: int64, lineCount: int, cheatSpin: seq[int8], cheatName: string): SpinResult =
    result.new()

    if stage == Stage.Bonus:
        let totalBonusBet = bet * lineCount
        let bonusResult = sm.getBonusGameResult(p, totalBonusBet)
        result.field = bonusResult.field
        result.dishesValue = bonusResult.dishesValue
    else:
        let spin = sm.spin(p, stage, bet, lineCount, cheatSpin, cheatName)

        result.field = spin.field
        result.wildIndexes = spin.wildIndexes
        result.lines = spin.lines

    result.stage = stage

proc getFullSpinResult*(sm: SlotMachineCandy, p: Profile, bet: int64, lineCount: int, stage: Stage, cheatSpin: seq[int8], cheatName: string): seq[SpinResult] =
    let mainSpin = sm.createStageResult(p, stage, bet, lineCount, cheatSpin, cheatName)
    result = @[]
    result.add(mainSpin)

    if sm.canStartBonusGame(mainSpin.field):
        result.add(sm.createStageResult(p, Stage.Bonus, bet, lineCount, @[], cheatName))


proc getPayout*(sm: SlotMachineCandy, bet: int64, r: SpinResult): int64 =
    if r.stage == Stage.Spin:
        result -= bet * LINE_COUNT
    if r.stage != Stage.Bonus:
        for ln in r.lines:
            result += ln.payout * bet
    else:
        result += sm.getBonusGamePayout(r.field, r.dishesValue)


proc getFinalPayout*(sm: SlotMachineCandy, bet: int64, res: openarray[SpinResult]): int64 =
    for r in res:
        result += sm.getPayout(bet, r)

proc createResponse*(sm: SlotMachineCandy, spin: openarray[SpinResult], initialBalance, bet: int64, scatters, freeSpinsCount: int, freespinsTotalWin: int64): JsonNode =
    result = newJObject()
    var res = newJArray()

    let betPerLine = bet
    for s in spin:
        var stageResult = newJObject()
        stageResult[$srtStage] = %($(s.stage))

        var field = newJArray()
        for n in s.field:
            field.add(%n)

        stageResult[$srtField] = field
        if s.lines.len != 0:
            stageResult[$srtLines] = winToJson(s.lines, betPerLine)
        if s.stage == Stage.Bonus:
            var dishesValue = newJArray()
            for dv in s.dishesValue:
                dishesValue.add(%dv)
            stageResult[$srtDishesValue] = dishesValue
            stageResult[$srtPayout] = %sm.getBonusGamePayout(s.field, s.dishesValue)
        if s.wildIndexes.len != 0:
            var wildIndexes = newJArray()
            for n in s.wildIndexes:
                wildIndexes.add(%n)
            stageResult[$srtWildIndexes] = wildIndexes
        res.add(stageResult)
    let balance = initialBalance + sm.getFinalPayout(bet, spin)
    result[$srtChips] = %balance
    result[$srtScatters] = %scatters
    result[$srtFreespinCount] = %freeSpinsCount
    result[$srtFreespinTotalWin] = %freespinsTotalWin
    result[$srtBet] = %(bet * LINE_COUNT)
    result[$srtStages] = res

method paytableToJson*(sm: SlotMachineCandy): JsonNode =
    result = procCall sm.SlotMachine.paytableToJson()
    result.add("freespin_count", %sm.freespinsMax)
    result.add("bonus_multipliers", %sm.bonusMultipliers)

