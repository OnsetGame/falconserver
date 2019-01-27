import json
import falconserver.auth.profile_random
import machine_base
import slot_data_types
import machine_candy2_types
export machine_candy2_types
import sequtils

type SlotMachineCandy2* = ref object of SlotMachine
    bonusStartBets: int64
    freespinCountRelation: seq[tuple[triggerCount: int, freespinCount: int]]
    bonusStartBetRelation: seq[tuple[triggerCount: int, bonusCount: int]]
    bonusFailChances: seq[int]
    bonusPossibleMultipliers: JsonNode
    bonusInitialMultipliers: seq[float]
    explosiveWildChance: float
    explosiveWildChanceFreespin: float
    wildsCountChances: seq[tuple[reels: int, chance: float]]
    freespinsWildsCountChances: seq[tuple[reels: int, chance: float]]
    wildReelsCount: int
    wildIndexes: seq[int]
    wildActivator: int

method itemSetDefault*(sm: SlotMachineCandy2): ItemSet =
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

proc parseZsmConfig(sm: SlotMachineCandy2, jMachine: JsonNode) =
    var jRecord: JsonNode

    sm.freespinCountRelation = @[]
    sm.bonusStartBetRelation = @[]
    sm.bonusFailChances = @[]
    sm.bonusInitialMultipliers = @[]
    sm.wildsCountChances = @[]
    sm.freespinsWildsCountChances = @[]

    jRecord = jMachine["freespin_count"]
    for el in jRecord:
        sm.freespinCountRelation.add((el["trigger_count"].getInt(), el["freespin_count"].getInt()))

    jRecord = jMachine["bonus_start_bet_count"]
    for el in jRecord:
        sm.bonusStartBetRelation.add((el["trigger_count"].getInt(), el["bonus_count"].getInt()))

    jRecord = jMachine["bonus_fail_chances"]
    for el in jRecord:
        sm.bonusFailChances.add(el.getInt())

    jRecord = jMachine["bonus_initial_multipliers"]
    for el in jRecord:
        sm.bonusInitialMultipliers.add(el.getFloat())

    jRecord = jMachine["wilds_count_chances"]
    for el in jRecord:
        sm.wildsCountChances.add((el["reels"].getInt(), el["chance"].getFloat()))

    jRecord = jMachine["freespins_wilds_count_chances"]
    for el in jRecord:
        sm.freespinsWildsCountChances.add((el["reels"].getInt(), el["chance"].getFloat()))

    sm.explosiveWildChance = jMachine["explosive_wild_chance"].getFloat()
    sm.explosiveWildChanceFreespin = jMachine["explosive_wild_chance_freespin"].getFloat()
    sm.bonusPossibleMultipliers = jMachine["bonus_possible_multipliers"]

proc newSlotMachineCandy2*(): SlotMachineCandy2 =
    result.new
    result.initSlotMachine()

proc newSlotMachineCandy2*(jMachine: JsonNode): SlotMachineCandy2 =
    ## Constructor for the Candy slot machine from ZSM format
    result.new
    result.initSlotMachine(jMachine)
    result.parseZsmConfig(jMachine)

proc countSymbol(sm: SlotMachineCandy2, field: openarray[int8], symbol: int8): int =
    for i in 0..<field.len:
        if field[i] == symbol:
            result.inc()

proc defineBonusStartBets(sm: SlotMachineCandy2, field: openarray[int8]) =
    let bonuses = sm.countSymbol(field, BONUS)

    sm.bonusStartBets = 0
    for el in sm.bonusStartBetRelation:
        if bonuses == el.triggerCount:
            sm.bonusStartBets = el.bonusCount
            return

method canStartBonusGame*(sm: SlotMachineCandy2, field: openarray[int8]): bool =
    sm.defineBonusStartBets(field)
    result = sm.bonusStartBets > 0

method numberOfNewFreeSpins*(sm: SlotMachineCandy2, field: openarray[int8]): int =
    let scatters = sm.countSymbol(field, SCATTER)

    for el in sm.freespinCountRelation:
        if scatters == el.triggerCount:
            return el.freespinCount

proc runBonusGame(sm: SlotMachineCandy2, p: Profile): seq[float] =
    result = @[]

    var fail = false
    var index: int
    var initBoxes: seq[float] = @[]

    for el in sm.bonusInitialMultipliers:
        initBoxes.add(el)

    while (not fail and initBoxes.len > 0):
        let failRand = p.random(100)
        if failRand < sm.bonusFailChances[index]:
            fail = true

        if not fail:
            let rand = p.random(initBoxes.len)
            let randBox = initBoxes[rand]

            result.add(randBox)
            initBoxes.del(rand)
            index.inc()


method getSlotID*(sm: SlotMachineCandy2): string =
    return "g"

method getBigwinMultipliers*(sm: SlotMachineCandy2): seq[int] =
    result = @[8, 10, 12]

method combinations*(sm: SlotMachineCandy2, field: openarray[int8], lineCount: int): seq[Combination] =
    return sm.combinations(sm.reels, field, lineCount)

proc reelToIndexes(reel: int): seq[int] =
    result = @[]
    for i in countup(reel, ELEMENTS_COUNT - 1, NUMBER_OF_REELS):
        result.add(i)

proc getWildsReelsCount(sm: SlotMachineCandy2, p: Profile, forFreeSpin: bool): int =
    let randReel = p.random(100.0)
    var chances = sm.wildsCountChances
    var ch: float

    if forFreeSpin:
        chances = sm.freespinsWildsCountChances
    for i in 0..chances.high:
        ch += chances[i].chance
        if randReel < ch:
            result = chances[i].reels
            break

proc addWildsToField(sm: SlotMachineCandy2, p: Profile, field: var seq[int8], lines: var seq[WinningLine], forFreeSpin: bool) =
    var rand = p.random(100.0)
    var chance = sm.explosiveWildChance

    if forFreeSpin:
        chance = sm.explosiveWildChanceFreespin

    if rand < chance:
        var reels: seq[int] = @[0, 1, 2, 3, 4]

        sm.wildReelsCount = sm.getWildsReelsCount(p, forFreeSpin)
        for i in 0..< NUMBER_OF_REELS - sm.wildReelsCount:
            reels.delete(p.random(reels.len))

        for reel in reels:
            let indexes = reelToIndexes(reel)
            let wi = p.random(indexes)

            field[wi] = WILD
            sm.wildIndexes.add(wi)

        sm.wildActivator = sm.wildIndexes[^1]
        sm.wildIndexes.delete(sm.wildIndexes.high)
        lines = sm.payouts(sm.combinations(field, LINE_COUNT))

proc spin*(sm: SlotMachineCandy2, p: Profile, stage: Stage, bet:int64, lineCount: int, cheatSpin: seq[int8], cheatName: string): tuple[field: seq[int8], lines: seq[WinningLine]] =
    sm.wildIndexes = @[]

    if cheatSpin.len != 0:
        result.field = cheatSpin
        result.lines = sm.payouts(sm.combinations(cheatSpin, lineCount))
    else:
        if stage == Stage.Spin:
            result = sm.spin(p, sm.reels, bet, lineCount)
            if sm.countSymbol(result.field, BONUS) < BONUS_MIN_SYMBOLS and sm.countSymbol(result.field, WILD) == 0:
                sm.addWildsToField(p, result.field, result.lines, false)
        else:
            result = sm.spin(p, sm.reelsFreespin, bet, lineCount)
            sm.addWildsToField(p, result.field, result.lines, true)

proc getBonusGamePayout*(sm: SlotMachineCandy2, bet: int64, field: openarray[int8]): int64 =
    result = sm.bonusStartBets * bet

    for i in 0..field.high:
        result = (result.float64 * field[i].float64 / 10.0'f64).int64

proc createStageResult(sm: SlotMachineCandy2, p: Profile, stage: Stage, bet: int64, cheatSpin: seq[int8], cheatName: string): SpinResult =
    result.new()

    if stage == Stage.Bonus:
        let totalBonusBet = bet * LINE_COUNT
        let boxes = sm.runBonusGame(p)

        result.field = @[]
        for box in boxes:
            result.field.add((box * 10.0).int8) #HACK - there is field in int8, but we need float here. Should divide by 10 on client
    else:
        let spin = sm.spin(p, stage, bet, LINE_COUNT, cheatSpin, cheatName)

        result.field = spin.field
        result.lines = spin.lines
        result.freeSpinsCount = sm.numberOfNewFreeSpins(result.field)
    result.stage = stage

proc getFullSpinResult*(sm: SlotMachineCandy2, p: Profile, bet: int64, lineCount: int, stage: Stage, cheatSpin: seq[int8], cheatName: string): seq[SpinResult] =
    let mainSpin = sm.createStageResult(p, stage, bet, cheatSpin, cheatName)
    result = @[]
    result.add(mainSpin)

    if sm.canStartBonusGame(mainSpin.field):
        result.add(sm.createStageResult(p, Stage.Bonus, bet, @[], cheatName))

proc getPayout*(sm: SlotMachineCandy2, bet: int64, r: SpinResult): int64 =
    if r.stage == Stage.Spin:
        result -= bet * LINE_COUNT
    if r.stage != Stage.Bonus:
        for ln in r.lines:
            result += ln.payout * bet
    else:
        result += sm.getBonusGamePayout(bet * LINE_COUNT, r.field)

proc getFinalPayout*(sm: SlotMachineCandy2, bet: int64, res: openarray[SpinResult]): int64 =
    for r in res:
        result += sm.getPayout(bet, r)

proc createResponse*(sm: SlotMachineCandy2, spin: openarray[SpinResult], initialBalance, bet: int64, freeSpinsCount: int, freespinsTotalWin: int64): JsonNode =
    result = newJObject()
    var res = newJArray()
    var freeSpins = freeSpinsCount

    for s in spin:
        var stageResult = newJObject()
        var field = newJArray()

        stageResult[$srtStage] = %($(s.stage))
        for n in s.field:
            field.add(%n)
        freeSpins += s.freeSpinsCount
        stageResult[$srtField] = field
        if s.lines.len != 0:
            stageResult[$srtLines] = winToJson(s.lines, bet)
        if s.stage == Stage.Bonus:
            stageResult[$srtPayout] = %sm.getBonusGamePayout(bet * LINE_COUNT, s.field)
        else:
            if sm.wildIndexes.len > 0:
                var wildIndexes = newJArray()

                for wi in sm.wildIndexes:
                    wildIndexes.add(%wi)
                stageResult[$srtWildIndexes] = wildIndexes
                stageResult[$srtWildActivator] = %sm.wildActivator

        res.add(stageResult)

    let balance = initialBalance + sm.getFinalPayout(bet, spin)
    result[$srtChips] = %balance
    result[$srtFreespinCount] = %freeSpins
    result[$srtFreespinTotalWin] = %freespinsTotalWin
    result[$srtBet] = %(bet * LINE_COUNT)
    result[$srtStages] = res

method paytableToJson*(sm: SlotMachineCandy2): JsonNode =
    result = procCall sm.SlotMachine.paytableToJson()

    var fsRelation = newJObject()
    var bRelation = newJObject()

    for f in sm.freespinCountRelation:
        fsRelation[$f.triggerCount] = %f.freespinCount
    for b in sm.bonusStartBetRelation:
        bRelation[$b.triggerCount] = %b.bonusCount

    result.add("freespins_relation", fsRelation)
    result.add("bonus_relation", bRelation)
    result.add("bonus_possible_multipliers", sm.bonusPossibleMultipliers)

