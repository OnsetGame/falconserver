## Balloon Slot Machine Model implementation
import json
import hashes
import falconserver.auth.profile
import falconserver.auth.profile_random
import tables, sequtils

import machine_base

const ReelCountBalloon* = 5
    ## Number of slot machine reels (columns on field)

const
    BalloonBonusNothing* = 0
    BalloonBonusRockets* = 1
    BalloonBonusMultiplier*  = 2

type SlotMachineBalloon* = ref object of SlotMachine
    ## Balloon slot machine model
    lastField*:    seq[int8]         ## Field state (for lines destruction)
    prevSpin*:     seq[int8]         ## Reel state (for bonus game)
    lastWin*:      seq[WinningLine]  ## Winning lines state (for lines destruction)
    freegame*:     bool
    bonusgame*:    bool
    destructions*: int

    bonusTrigger: ItemObj
    bonusCountRelation: int
    bonusMultiplierProbability: int
    rockets: seq[int8]
    freespinCountReleation: seq[tuple[destructionCount: int, freespinCount: int]]

method itemSetDefault*(sm: SlotMachineBalloon): ItemSet =
    ## Generate default Item Set for Balloons slot as of design document
    @[
        ItemObj(id:  0, kind: IWild,   name: "Wild"),
        ItemObj(id:  1, kind: IBonus,  name: "Bonus"),
        ItemObj(id:  2, kind: ISimple, name: "Snake"),
        ItemObj(id:  3, kind: ISimple, name: "Glider"),
        ItemObj(id:  4, kind: ISimple, name: "Kite"),
        ItemObj(id:  5, kind: ISimple, name: "Flag"),
        ItemObj(id:  6, kind: ISimple, name: "Red"),
        ItemObj(id:  7, kind: ISimple, name: "Yellow"),
        ItemObj(id:  8, kind: ISimple, name: "Green"),
        ItemObj(id:  9, kind: ISimple, name: "Blue")
    ]

method reelCount*(sm: SlotMachineBalloon): int = ReelCountBalloon
    ## Number of slot machine reels

proc newSlotMachineBalloon*(): SlotMachineBalloon =
    ## Constructor for the Balloon slot machine
    result.new
    result.initSlotMachine()
    result.lastField = @[]
    result.freespinCount = 0

proc parseCustomZsmConfig(sm: SlotMachineBalloon, jMachine: JsonNode) =
    # Freespins config
    let freespRelation = jMachine{"freespin_config", "freespin_count"}
    if not freespRelation.isNil and freespRelation.len >= 5:
        sm.freespinCountReleation = @[]
        for el in freespRelation:
            sm.freespinCountReleation.add((el["destruction"].getInt(5), el["freespin_count"].getInt(5)))
    else:
        sm.freespinCountReleation = @[(5, 5), (6, 10), (7, 15), (8, 25), (9, 50)]

    # Bonus config
    let bonusTriggName = jMachine{"bonus_config", "bonus_trigger", "id"}.getStr("Bonus")
    for item in sm.items:
        if item.name == bonusTriggName: sm.bonusTrigger = item
    sm.bonusCountRelation = jMachine{"bonus_config", "bonus_count", "trigger_count"}.getInt(3)
    sm.bonusMultiplierProbability = jMachine{"bonus_config", "bonus_multiplier_probability"}.getInt(7)
    let bonusRockets = jMachine{"bonus_config", "bonus_rockets_count"}
    if not bonusRockets.isNil and bonusRockets.len >= 3:
        sm.rockets = @[]
        for el in bonusRockets:
            sm.rockets.add(el.getInt(3).int8)
    else:
        sm.rockets = @[3.int8, 4, 5]

proc newSlotMachineBalloon*(jMachine: JsonNode): SlotMachineBalloon =
    ## Constructor for the Balloon slot machine from ZSM format
    result.new
    result.initSlotMachine(jMachine)
    result.parseCustomZsmConfig(jMachine)

when declared(parseFile):
    proc newSlotMachineBalloon*(filename: string): SlotMachineBalloon =
        ## Constructor for the Balloon slot machine from file
        result.new
        result.initSlotMachine(filename)

method canStartBonusGame*(sm: SlotMachineBalloon, field: openarray[int8]): bool =
    ## Checks if current spin result (field) is a winning result that
    ## allows to start bonus game (slot-specific)
    var dummyx, dummyy: int
    result = sm.countSymbolsOfType(field, sm.bonusTrigger.kind, dummyx, dummyy) >= sm.bonusCountRelation

proc numberOfNewFreeSpins*(sm: SlotMachineBalloon, destructions: int): int =
    if destructions >= sm.freespinCountReleation[0].destructionCount:
        for el in sm.freespinCountReleation:
            if destructions == el.destructionCount:
                return el.freespinCount
        if destructions > sm.freespinCountReleation[sm.freespinCountReleation.len-1].destructionCount:
            return sm.freespinCountReleation[sm.freespinCountReleation.len-1].freespinCount

proc bonusFieldHeight(sm: SlotMachineBalloon): int =
    return sm.fieldHeight + 2

proc generateBonusField*(sm: SlotMachineBalloon): seq[int8] =
    ## Heighten up bonus field - one row before, and one after filled with reel items
    result = newSeq[int8](sm.bonusFieldHeight * sm.reelCount)
    # Generate bonus field
    var resIndex = 0
    for i in 0..<sm.reelCount:
        var shiftBack: int
        if sm.prevSpin.len == 0 or sm.prevSpin[0] == -1:
            shiftBack = sm.reels.lastSpin[i] - 1
        else:
            shiftBack = sm.prevSpin[i] - 1

        let reelLen = len(sm.reels.reels[i]) - 1
        var index: int
        if shiftBack.int >= 0:
            if shiftBack > reelLen: index = 0.int
            else: index = shiftBack.int
        else:
            index = reelLen.int

        result[resIndex] = sm.reels.reels[i][index].id
        inc(resIndex)

    for v in sm.lastField:
        result[resIndex] = v
        inc(resIndex)

    for i, v in sm.reels.lastSpin:
        let reelSize = len(sm.reels.reels[i])
        let index = if (reelSize - v - 3) > 0: (v + 3).int else: (v + 3 - reelSize).int
        result[resIndex] = sm.reels.reels[i][index].id
        inc(resIndex)

proc randomBonusElementType*(sm: SlotMachineBalloon, p: Profile, currentBonus: int, bonusNumber: int, gotMultiplier: var bool): int =
    ## Choose type of firework bonus type
    if gotMultiplier or currentBonus == bonusNumber:
        return BalloonBonusRockets
    else:
        result = if p.random(100) <= sm.bonusMultiplierProbability: BalloonBonusRockets else: BalloonBonusMultiplier
        if result == BalloonBonusMultiplier: gotMultiplier = true

proc runBonusRockets*(sm: SlotMachineBalloon, p: Profile, destrIds: var seq[int], field: var seq[int8], multiplier: var bool, aims: var Table[int8, int8]): Table[tuple[k: int8, v: int8], int64] =
    ## Run rocket and get indices of destroyed symbols
    let rockets = p.random(sm.rockets)
    var currentAims = initTable[tuple[k: int8, v: int8], int64]()

    for _ in 0 ..< rockets:
        while true:
            var aim = p.random(sm.bonusFieldHeight * sm.reelCount).int8
            if sm.items[field[aim]].kind == IBonus:
                # field[aim] = BONUS_ID
                destrIds.add(aim)
                continue
            if sm.items[field[aim]].kind == IWild:
                continue
            if not aims.hasKey(aim):
                aims[aim] = if multiplier: sm.rockets[1] else: sm.rockets[0]
                currentAims[(aim, aims[aim])] = (sm.paytable[sm.reelCount() - aims[aim]][sm.items[field[aim]].id]).int64
                # field[aim] = BONUS_ID
                destrIds.add(aim)
                break
            elif aims[aim] == sm.rockets[2]:
                aim = p.random(sm.bonusFieldHeight * sm.reelCount).int8
                continue
            else:
                aims[aim] = aims[aim] + (if multiplier: 2 else: 1)
                if aims[aim] > sm.rockets[2]: aims[aim] = sm.rockets[2]
                currentAims[(aim, aims[aim])] = (sm.paytable[sm.reelCount() - aims[aim]][sm.items[field[aim]].id]).int64
                break

    multiplier = false
    result = currentAims

proc runBonusGame*(sm: SlotMachineBalloon, p: Profile): tuple[ field: seq[int8], destrIds: seq[int], rockets: OrderedTable[string, Table[tuple[k: int8, v: int8],  int64] ] ] =
    ## Simulate bonus game
    var
        dummyx, dummyy: int
        gotMultiplier = false.bool
        multiplier = false.bool
        currentBonus = 0
        aims = initTable[int8, int8]()
        rocketaims = initOrderedTable[string, Table[tuple[k: int8, v: int8], int64] ]()

    var field = sm.generateBonusField()
    let standartFieldHeight = sm.fieldHeight
    sm.fieldHeight = sm.bonusFieldHeight().int8
    let bonusNumber = sm.countSymbolsOfType(field, IBonus, dummyx, dummyy)
    sm.fieldHeight = standartFieldHeight
    var ids: seq[int] = @[]
    const MARKER: int8 = -1

    for row in 0 ..< sm.bonusFieldHeight():
        for col in 0 ..< sm.reelCount:
            if sm.items[field[row * sm.reelCount + col]].kind == IBonus:
                inc(currentBonus)
                let bonusType = sm.randomBonusElementType(p, currentBonus, bonusNumber, gotMultiplier)
                case bonusType
                of BalloonBonusRockets:
                    rocketaims[$(row * sm.reelCount + col)] = sm.runBonusRockets(p, ids, field, multiplier, aims)
                of BalloonBonusMultiplier:
                    rocketaims[$(row * sm.reelCount + col)] = {(k: -1.int8, v: 0.int8): 0.int64}.toTable()
                    multiplier = true
                else: # WTF? Should be unreal
                    discard

    return (field: field, destrIds: ids, rockets: rocketaims)

proc shiftUpLines*(sm: SlotMachineBalloon, layout: Layout) {.gcsafe.} =
    ## Modify field: destroy items on winning lines and perform
    ## filling the gaps some way depending on the FieldRefillKind value
    const MARKER: int8 = -1
    # Fill marked items with next-in-reel items
    for col in 0 ..< sm.reelCount():
        for row in 0 ..< sm.fieldHeight:
            if sm.lastField[row * sm.reelCount() + col] != MARKER:
                continue
            else:
                var shifted: bool = false
                for vertical in (row + 1) ..< sm.fieldHeight:
                    if sm.lastField[vertical * sm.reelCount() + col] != MARKER:
                        sm.lastField[row * sm.reelCount() + col] = sm.lastField[vertical * sm.reelCount() + col]
                        sm.lastField[vertical * sm.reelCount() + col] = MARKER
                        shifted = true
                        break
                if not shifted:
                    let
                        reel = layout.reels[col]
                        reelSize = reel.len()

                    sm.lastField[row * sm.reelCount() + col] = reel[(layout.lastSpin[col] + sm.fieldHeight) mod reelSize].id
                    inc layout.lastSpin[col]

    # sm.debugLastField()


proc destroyLines*(sm: SlotMachineBalloon, layout: Layout, dk: FieldRefillKind = FieldRefillKind.None): seq[int8] =
    ## Modify field: destroy items on winning lines and perform
    ## filling the gaps some way depending on the FieldRefillKind value
    const MARKER: int8 = -1

    if sm.lastWin.len == 0 or sm.hasLost(sm.lastWin):
        return
    else:
        # Mark all winning items with `-1` marker
        for lineIndex in 0 ..< sm.lastWin.len():
            let line = sm.lines[lineIndex]
            if sm.lastWin[lineIndex].numberOfWinningSymbols > 1 and sm.lastWin[lineIndex].payout > 0:
                for col in 0 ..< sm.lastWin[lineIndex].numberOfWinningSymbols:
                    let row = line[col]
                    sm.lastField[row * sm.reelCount() + col] = MARKER

        # sm.debugLastField(true)

        # Fill marked items with next-in-reel items
        result = newSeq[int8](15)
        for col in 0 ..< sm.reelCount():
            for row in 0 ..< sm.fieldHeight:
                var val = -1'i8
                if sm.lastField[row * sm.reelCount() + col] != MARKER:
                    result[row * sm.reelCount() + col] = val
                    continue
                else:
                    var shifted: bool = false
                    for vertical in (row + 1) ..< sm.fieldHeight:
                        if sm.lastField[vertical * sm.reelCount() + col] != MARKER:
                            sm.lastField[row * sm.reelCount() + col] = sm.lastField[vertical * sm.reelCount() + col]
                            sm.lastField[vertical * sm.reelCount() + col] = MARKER
                            shifted = true
                            break
                    if not shifted:
                        let
                            reel = layout.reels[col]
                            reelSize = reel.len()

                        assert(sm.lastField.len != 0)
                        assert(layout.lastSpin.len != 0)
                        assert(reel.len != 0)

                        sm.lastField[row * sm.reelCount() + col] = reel[(layout.lastSpin[col] + sm.fieldHeight) mod reelSize].id
                        inc layout.lastSpin[col]
                        val = sm.lastField[row * sm.reelCount() + col]

                result[row * sm.reelCount() + col] = val
        # sm.debugLastField()

method combinations*(sm: SlotMachineBalloon, field: openarray[int8], lineCount: int): seq[Combination] =
    ## Return combinations depending on what reel layout was played:
    ## either default one or freespin one.
    # if sm.freespinCount > 0:
    #     return sm.combinations(sm.reelsFreespin, field, lineCount)
    # else:
    #     return sm.combinations(sm.reels, field, lineCount)

    return sm.combinations(sm.reels, field, lineCount)

method spin*(sm: SlotMachineBalloon, p: Profile, bet:int64, lineCount: int, cheatSpin: seq[int8]): tuple[field: seq[int8], destruction: seq[int8], lines: seq[WinningLine]] {.base, gcsafe.} =
    ## Spin Balloon Slot
    if sm.bonusgame or sm.hasWon(sm.lastWin):
        if cheatSpin.len != 0:
            sm.lastField = cheatSpin

        if not sm.bonusgame:
            result.destruction = sm.destroyLines(sm.reels, FieldRefillKind.ShiftUp)

        inc(sm.destructions)

        sm.lastWin = sm.payouts(sm.combinations(sm.lastField, lineCount))

        # Define if we are capable of running freespin streak
        if not sm.hasWon(sm.lastWin):
            if sm.freespinCount > 0 and not sm.bonusgame:
                dec(sm.freespinCount)

            inc(sm.freespinCount, sm.numberOfNewFreeSpins(sm.destructions-1))
            sm.destructions = 0

        result.field = sm.lastField
        result.lines = sm.lastWin

    else:
        # Perform Spin
        sm.destructions = 0

        # if sm.freespinCount > 0:
        #     sm.lastField = sm.reelsFreespin.spin(sm.fieldHeight)
        # else:
            # sm.lastField = sm.reels.spin(sm.fieldHeight)
        if cheatSpin.len != 0:
            var bonuses = cheatSpin.filter() do(a: int8) -> bool: a == 1
            if bonuses.len >= 5:
                sm.lastField = @[7.int8,7,9,7,7,7,7,9,7,7,7,3,9,3,7]
            else:
                sm.lastField = cheatSpin
            sm.reels.lastSpin = @[0'i8,0,0,0,0]
        else:
            sm.lastField = sm.reels.spin(p, sm.fieldHeight)

        sm.lastWin = sm.payouts(sm.combinations(sm.lastField, lineCount))

        result.field = sm.lastField
        result.lines = sm.lastWin

        if not sm.hasWon(sm.lastWin):
            if sm.freespinCount > 0 and not sm.bonusgame:
                dec(sm.freespinCount)
            sm.destructions = 0

            if sm.prevSpin.len == 0: sm.prevSpin = newSeq[int8](sm.reelCount)
            for i, v in sm.reels.lastSpin: sm.prevSpin[i] = -1
        else:
            sm.destructions = 1

            if sm.prevSpin.len == 0: sm.prevSpin = newSeq[int8](sm.reelCount)
            for i, v in sm.reels.lastSpin: sm.prevSpin[i] = v


method getSlotID*(sm: SlotMachineBalloon): string =
    result = "c"

method getBigwinMultipliers*(sm: SlotMachineBalloon): seq[int] =
    result = @[8, 11, 13]

method paytableToJson*(sm: SlotMachineBalloon): JsonNode =
    result = procCall sm.SlotMachine.paytableToJson()
    let jRelation = newJArray()
    for el in sm.freespinCountReleation:
        let j = newJObject()
        j["trigger_destruction"] = %el.destructionCount
        j["freespin_count"] = %el.freespinCount
        jRelation.add(j)
    result.add("freespin_count", jRelation)
    result.add("bonus_trigger", %sm.bonusTrigger.name)
    result.add("bonus_count", %sm.bonusCountRelation)
    let jRockets = newJArray()
    for el in sm.rockets:
        jRockets.add(%el)
    result.add("bonus_rockets_count", jRockets)
