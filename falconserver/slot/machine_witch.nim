import json
import falconserver.auth.profile_random
import sequtils
import strutils
# import coverage

import machine_base
import slot_data_types
import machine_witch_types
export machine_witch_types

proc reelToIndexes(reel: int): seq[int] =
    result = @[]
    for i in countup(reel, ELEMENTS_COUNT - 1, NUMBER_OF_REELS):
        result.add(i)

proc newPot(p: Profile, index: int): Pot =
    result.new()
    result.states = @[]
    result.index = index

    var start = @[PotState.Red, PotState.Yellow, PotState.Green, PotState.Blue]
    for i in 0..2:
        let rand = p.random(start.len)
        result.states.add(start[rand])
        start.del(rand)
    result.states.add(start[0])


proc deserializePot(index: int, potsStates: seq[int], pots: string): Pot =
    result.new()
    result.index = index
    result.states = @[]
    result.stateIndex = parseInt($pots[index])

    let str = $(potsStates[index])
    for i in 0..<POT_RUNE_STATES:
        result.states.add(parseInt($(str[i])).PotState)

proc setRuneStats*(sm: SlotMachineWitch, spin: SpinResult) =
    const RED = 2
    const BLUE = 5

    var newRunes: int
    for elem in spin.field:
        if elem >= RED and elem <= BLUE:
            newRunes.inc()

    sm.runeCounter += newRunes
    sm.runeBetTotal += (newRunes * sm.bet * LINE_COUNT).int64

proc initNewPots*(sm: SlotMachineWitch, p: Profile): seq[int] =
    proc potToInt(pot: Pot): int =
        var mult: int = 1000
        for state in pot.states:
            result += state.int * mult
            mult = mult div 10

    result = @[]
    for i in 0..<NUMBER_OF_REELS:
        let pot = newPot(p, i)
        result.add(potToInt(pot))

proc updatePot(sm: SlotMachineWitch, pot: var Pot,  field: openarray[int8]) =
    const OFFSET = 1

    if pot.stateIndex < POT_RUNE_STATES:
        let needRune = (pot.states[pot.stateIndex]).int + OFFSET #define rune item's index
        let indexes = reelToIndexes(pot.index)

        for index in indexes:
            if field[index] == needRune:
                pot.stateIndex.inc()

proc updatePots(sm: SlotMachineWitch, profile: Profile, pots: string, field: openarray[int8], potsStates: seq[int]): tuple[pots: string, potsStates: seq[int]] =
    var p = pots

    if pots == "44444":
        p = "00000"
    result.pots = ""
    result.potsStates = potsStates
    for i in 0..<NUMBER_OF_REELS:
        var pot = deserializePot(i, potsStates, p)
        sm.updatePot(pot, field)

        result.pots &= $(pot.stateIndex)
    if result.pots == "44444":
        result.potsStates = sm.initNewPots(profile)
        sm.canStartBonus = true

method getSlotID*(sm: SlotMachineWitch): string =
    result = "e"

method getBigwinMultipliers*(sm: SlotMachineWitch): seq[int] =
    result = @[9, 11, 14]

method itemSetDefault(sm: SlotMachineWitch): ItemSet =
    @[
        ItemObj(id:  0, kind: IWild,    name: "Wild"),
        ItemObj(id:  1, kind: IScatter, name: "Scatter"),
        ItemObj(id:  2, kind: ISimple,  name: "Red"),
        ItemObj(id:  3, kind: ISimple,  name: "Yellow"),
        ItemObj(id:  4, kind: ISimple,  name: "Green"),
        ItemObj(id:  5, kind: ISimple,  name: "Blue"),
        ItemObj(id:  6, kind: ISimple,  name: "Plant"),
        ItemObj(id:  7, kind: ISimple,  name: "Mandragora"),
        ItemObj(id:  8, kind: ISimple,  name: "Mushroom"),
        ItemObj(id:  9, kind: ISimple,  name: "Feather"),
        ItemObj(id: 10, kind: ISimple,  name: "Web"),

    ]

method reelCount*(sm: SlotMachineWitch): int = NUMBER_OF_REELS
    ## Number of slot machine reels

proc newSlotMachineWitch*(): SlotMachineWitch = #TODO
    ## Constructor of Empty Witch Slot machine
    result.new
    result.initSlotMachine()

proc parseZsmConfig(sm: SlotMachineWitch, jMachine: JsonNode) =
    var chances = jMachine["bonus_elements_chances"]
    var bonusPaytable = jMachine["bonus_elements_paytable"]

    sm.bonusElementsPaytable = @[]
    sm.bonusElementsChances = @[]
    sm.freespinsMax = jMachine["freespin_count"].getInt()
    sm.magicSpinChance = jMachine["magic_spin_chance"].getInt()
    sm.bonusRounds = jMachine["bonus_start_elements"].getInt()
    sm.bonusProbabilityBasis = jMachine["bonus_probability_basis"].getInt()

    for c in chances:
        sm.bonusElementsChances.add(c.getInt())
    for s in bonusPaytable:
        var row: seq[int] = @[]

        for elem in s:
            row.add(elem.getInt())
        sm.bonusElementsPaytable.add(row)

proc newSlotMachineWitch*(jMachine: JsonNode): SlotMachineWitch =
    ## Constructor for the Witch slot machine from ZSM format
    result.new
    result.initSlotMachine(jMachine)
    result.parseZsmConfig(jMachine)

when declared(parseFile):
    proc newSlotMachineWitch*(filename: string): SlotMachineWitch =
        ## Constructor for the Witch slot machine from file
        result.new
        result.initSlotMachine(filename)

proc countScatters(sm: SlotMachineWitch, field: openarray[int8]): int =
    for i in 0..<field.len:
        if field[i] == SCATTER:
            result.inc()

method combinations*(sm: SlotMachineWitch, field: openarray[int8], lineCount: int): seq[Combination] =
    return sm.combinations(sm.reels, field, lineCount)

method numberOfNewFreeSpins*(sm: SlotMachineWitch, stage: Stage, field: openarray[int8]): int =
    const SCATTERS_FOR_FREESPINS = 3
    let scatters = sm.countScatters(field)

    if stage == Stage.FreeSpin:
        return scatters

    if scatters >= SCATTERS_FOR_FREESPINS:
        result = sm.freespinsMax

proc spin*(sm: SlotMachineWitch, p: Profile, stage: Stage, lineCount: int, cheatSpin: seq[int8]): SpinResult =
    const PLANT = 6'i8
    const WEB = 10'i8
    var spinAux: tuple[field: seq[int8], lines: seq[WinningLine]]

    result.new()

    if cheatSpin.len != 0:
        result.field = cheatSpin
        result.lines = sm.payouts(sm.combinations(cheatSpin, lineCount))
    else:
        if stage == Stage.Spin:
            spinAux = sm.spin(p, sm.reels, sm.bet, lineCount)
        elif stage == Stage.FreeSpin:
            spinAux = sm.spin(p, sm.reelsFreespin, sm.bet, lineCount)
        result.field = spinAux.field
        result.lines = spinAux.lines
        result.stage = stage
    # result.field[14] = 1'i8 #FOR DEBUG
    # result.field[13] = 1'i8 #FOR DEBUG
    # result.field[12] = 0'i8 #FOR DEBUG
    let wildIndex = result.field.find(WILD)
    if sm.hasLost(result.lines) and wildIndex > -1:
        var newField = result.field

        for i in 0..<ELEMENTS_COUNT:
            case result.field[i]
            of PLANT..WEB:
                #result.field[i] = WEB #FOR DEBUG
                newField[i] = WEB
            else: discard
        result.lines = sm.payouts(sm.combinations(newField, lineCount))
        result.isSpider = true
    result.freeSpinsCount = sm.numberOfNewFreeSpins(stage, result.field)

proc generateSymbol(sm: SlotMachineWitch, p: Profile): int8 =
    let rand = p.random(sm.bonusProbabilityBasis)
    var curr = sm.bonusProbabilityBasis

    if rand == 0:
        return Ingredient5.int8
    for i in 0..<sm.bonusElementsChances.len:
        var next: int
        curr -= sm.bonusElementsChances[i]

        if i + 1 < sm.bonusElementsChances.len:
            next = curr - sm.bonusElementsChances[i + 1]
        if rand <= curr and rand > next:
            return (i + 1).int8

proc checkForNext(field: seq[int8]): tuple[isNext: bool, stubField: seq[int8]] =
    var check: seq[int] = @[0, 0, 0, 0, 0]

    result.isNext = false
    result.stubField = @[]
    for sym in field:
        check[sym].inc()
    for c in check:
        if c >= 3:
            result.isNext = true
            break
    for element in field:
        if check[element] < 3:
            result.stubField.add(element)

proc fillFirstSeq(sm: SlotMachineWitch, p: Profile, s: var seq[int8], count: int) =
    for i in 0..<sm.bonusRounds:
        s.add(sm.generateSymbol(p))
    sm.bonusPayout += getRoundPayout(sm.bonusElementsPaytable, s)

    let winning = checkForNext(s)
    if not winning.isNext:
        s = @[]
        sm.fillFirstSeq(p, s, sm.bonusRounds)

proc generateNextSeq(sm: SlotMachineWitch, p: Profile, stubField: var seq[int8], length: int) =
    for i in stubField.len..<length:
        stubField.add(sm.generateSymbol(p))

proc getBonusGameResult(sm: SlotMachineWitch, p: Profile): seq[int8] =
    let bonusTotalBet = sm.runeBetTotal div sm.runeCounter.int64
    var startFillCount = sm.bonusRounds
    var fillNext = true

    result = @[]
    sm.fillFirstSeq(p, result, startFillCount)

    var next = checkForNext(result)
    while startFillCount >= 3 and next.isNext:
        startFillCount.dec()
        sm.generateNextSeq(p, next.stubField, startFillCount)
        result = result.concat(next.stubField)
        sm.bonusPayout += getRoundPayout(sm.bonusElementsPaytable, next.stubField)
        next = checkForNext(next.stubField)

    sm.bonusPayout *= bonusTotalBet

proc createStageResult(sm: SlotMachineWitch, p: Profile, stage: Stage, lineCount: int, cheatSpin: seq[int8]): SpinResult =
    result.new()
    sm.bonusPayout = 0
    if stage == Stage.Bonus:
        let bonusResult = sm.getBonusGameResult(p)

        result.field = bonusResult
        result.bonusTotalBet = sm.runeBetTotal div sm.runeCounter.int64
    else:
        let spin = sm.spin(p, stage, lineCount, cheatSpin)
        sm.setRuneStats(spin)

        result.field = spin.field
        result.lines = spin.lines
        result.isSpider = spin.isSpider
        result.freeSpinsCount = spin.freeSpinsCount
    result.stage = stage

proc canStartBonusGame*(sm: SlotMachineWitch): bool =
    result = sm.canStartBonus
    sm.canStartBonus = false

proc getFullSpinResult*(sm: SlotMachineWitch, p: Profile, bet:int64, lineCount, runeCounter: int, runeBetTotal: int64, pots: string, potsStates: seq[int], stage: Stage, cheatSpin: seq[int8], cheatName: string): seq[SpinResult] =
    sm.runeCounter = runeCounter
    sm.runeBetTotal = runeBetTotal
    sm.bet = bet

    let mainSpin = sm.createStageResult(p, stage, lineCount, cheatSpin)
    result = @[]
    result.add(mainSpin)

    mainSpin.pots = pots
    mainSpin.potsStates = potsStates
    if stage == Stage.Spin:
        let p = sm.updatePots(p, pots, mainSpin.field, potsStates)
        mainSpin.pots = p.pots
        mainSpin.potsStates = p.potsStates

    if sm.canStartBonusGame() or cheatName == "bonus":
        let bonusRes = sm.createStageResult(p, Stage.Bonus, lineCount, @[])
        result.add(bonusRes)

proc getPayout*(sm: SlotMachineWitch, bet: int64, r: SpinResult): int64 =
    if r.stage == Stage.Spin:
        result -= bet * LINE_COUNT
    if r.stage != Stage.Bonus:
        for ln in r.lines:
            if ln.payout > 0:
                result += ln.payout * bet
    else:
        result += sm.bonusPayout

proc getFinalPayout(sm: SlotMachineWitch, bet: int64, res: openarray[SpinResult]): int64 =
    for r in res:
        result += sm.getPayout(bet, r)

proc createResponse*(sm: SlotMachineWitch, spin: openarray[SpinResult], initialBalance: int64, bet: int64, freeSpinsCount: int, pots: string, potsStates: seq[int], freespinsTotalWin: int64): JsonNode =
    result = newJObject()
    var res = newJArray()
    var freeSpins = freeSpinsCount

    for s in spin:
        var stageResult = newJObject()
        stageResult[$srtStage] = %($(s.stage))

        var field = newJArray()
        for n in s.field:
            field.add(%n)
        stageResult[$srtField] = field
        freeSpins += s.freeSpinsCount
        if s.lines.len != 0:
            stageResult[$srtLines] = winToJson(s.lines, bet)
        if s.stage == Stage.Bonus:
            stageResult[$srtPayout] = %sm.bonusPayout
            stageResult[$srtWitchBonusTotalbet] = %s.bonusTotalBet
        else:
            result[$srtPots] = %(s.pots)
            result[$srtPotsStates] = %(s.potsStates)
            result[$srtIsSpider] = %(s.isSpider)
        res.add(stageResult)
    let balance = initialBalance + sm.getFinalPayout(bet, spin)
    result[$srtChips] = %balance
    result[$srtFreespinCount] = %freeSpins
    result[$srtFreespinTotalWin] = %freespinsTotalWin
    result[$srtBet] = %bet
    result[$srtStages] = res

method paytableToJson*(sm: SlotMachineWitch): JsonNode =
    result = procCall sm.SlotMachine.paytableToJson()
    result.add("magic_spin_chance", %sm.magicSpinChance)
    result.add("bonus_start_elements", %sm.bonusRounds)
    result.add("freespin_count", %sm.freespinsMax)
    result.add("bonus_elements_paytable", %sm.bonusElementsPaytable)
