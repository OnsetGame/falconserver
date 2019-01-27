## UFO Slot Machine Model implementation
import json
import hashes
import math
import sets
import machine_base
import tables
import falconserver.auth.profile_random
import slot_data_types
import sequtils
import machine_ufo_bonus
const ReelCountUfo* = 5
const ReverseLineFrom = 10
    ## Number of slot machine reels (columns on field)

const DEFAULT_NEW_WILD_CHANCE = 29 # 0,1%
const DEFAULT_NEW_WILD_CHANCE_IN_FREESPINS = 540
const DEFAULT_NEW_WILD_CHANCE_IN_RESPINS = 105

## Default slot values
const DEFAULT_FS_ALL_COUNT = 10
const DEFAULT_FS_ADITIONAL_COUNT = 2
const DEFAULT_BONUS_SPIN_COUNT = 5


type SlotMachineUfo* = ref object of SlotMachine
    ## Ufo & Cows slot machine model
    freespinsAdditionalCount: int
    freespinsAllCount: int
    bonusSpins: int
    wildChance: int
    fsWildChance: int
    respinWildChance: int

type
    WildPos* = ref object of RootObj
        id*: ItemKind
        pos*: seq[int]

    SpinResult* = ref object of RootObj
        stage*: Stage
        field*: seq[int8]
        lines*: seq[WinningLine]
        freespinsCount*: int
        freespinsTotalWin*: int64
        respinsCount*: int
        wildPos*: seq[WildPos] # i mod 2 != 0 - x, i mod 2 == 0 - y
        wildApears*: seq[WildPos]
        noPayout*: bool
        meetIndex*: int

proc index*(wp: ItemKind): int =
    if wp == IWild2:
        result = 1
    else:
        result = 0

proc `$`*(wp:WildPos): string =
    result = "WildPos(id : " & $wp.id & "; pos:"
    for p in wp.pos:
        result &= " " & $p
    result &= ")"

proc getIndexOf*(wps: seq[WildPos], kind: ItemKind): int =
    for i, v in wps:
        if v.id == kind:
            return i
    return -1

method getSlotID*(sm: SlotMachineUfo): string =
    result = "b"

method getBigwinMultipliers*(sm: SlotMachineUfo): seq[int] =
    result = @[10, 15, 25]

method itemSetDefault*(sm: SlotMachineUfo): ItemSet =
    ## Generate default Item Set for Cows and UFO slot as of design document
    @[
        ItemObj(id:  0, kind: IWild, name: "red"),
        ItemObj(id:  1, kind: IWild2, name: "green"),
        ItemObj(id:  2, kind: IBonus, name: "cow"),
        ItemObj(id:  3, kind: ISimple, name: "pig"),
        ItemObj(id:  4, kind: ISimple, name: "dog"),
        ItemObj(id:  5, kind: ISimple, name: "scarerow"),
        ItemObj(id:  6, kind: ISimple, name: "elk"),
        ItemObj(id:  7, kind: ISimple, name: "barrow"),
        ItemObj(id:  8, kind: ISimple, name: "bone"),
        ItemObj(id:  9, kind: ISimple, name: "wheel"),
        ItemObj(id:  10, kind: ISimple, name: "hay"),
        ItemObj(id:  11, kind: ISimple, name: "pumpkin")
    ]

method reelCount*(sm: SlotMachineUfo): int = ReelCountUfo
    ## Number of slot machine reels

proc newSlotMachineUfo*(): SlotMachineUfo =
    ## Constructor for the Ufo & Cows slot machine
    result.new
    result.initSlotMachine()

proc parseZsmConfig(sm: SlotMachineUfo, jMachine: JsonNode) =
    sm.freespinsAdditionalCount = jMachine{"freespinsAdditionalCount"}.getInt(DEFAULT_FS_ADITIONAL_COUNT)
    sm.freespinsAllCount        = jMachine{"freespinsAllCount"}.getInt(DEFAULT_FS_ALL_COUNT)
    sm.bonusSpins               = jMachine{"bonusSpins"}.getInt(DEFAULT_BONUS_SPIN_COUNT)
    sm.wildChance               = jMachine{"wildChance"}.getInt(DEFAULT_NEW_WILD_CHANCE)
    sm.fsWildChance             = jMachine{"fsWildChance"}.getInt(DEFAULT_NEW_WILD_CHANCE_IN_FREESPINS)
    sm.respinWildChance         = jMachine{"respinWildChance"}.getInt(DEFAULT_NEW_WILD_CHANCE_IN_RESPINS)

proc newSlotMachineUfo*(jMachine: JsonNode): SlotMachineUfo =
    ## Constructor for the Ufo & Cows slot machine from Json Object
    result.new
    result.initSlotMachine(jMachine)
    result.parseZsmConfig(jMachine)

when declared(parseFile):
    proc newSlotMachineUfo*(filename: string): SlotMachineUfo =
        ## Constructor for the Ufo & Cows slot machine from ZSM file
        result.new
        result.initSlotMachine(filename)

method canStartBonusGame*(sm: SlotMachineUfo, field: openarray[int8]): bool =
    ## Checks if slot-machine field initiates bonus game.
    var dummyx, dummyy: int
    result = sm.countSymbolsOfType(field, IBonus, dummyx, dummyy) >= 3

proc positionsOfSymbols*(sm: SlotMachineUfo, field: openarray[int8], kind: ItemKind): seq[int] =
    result = @[]
    for i in 0 ..< sm.reelCount:
        for j in 0 ..< sm.fieldHeight:
            let posOnField = j * sm.reelCount + i
            if sm.items[field[posOnField]].kind == kind:
                # if kind == IWild2:
                #     echo "IWild2 spawned ", i, " ", j
                result.add(i)
                result.add(j)

proc numberOfNewRespins*(sm: SlotMachineUfo, field: openarray[int8], wildPos: var seq[WildPos]): int =
    var
        wild0 = sm.positionsOfSymbols(field, IWild)
        wild1 = sm.positionsOfSymbols(field, IWild2)

    proc getMaximumX(t: seq[WildPos], kind: ItemKind): int =
        var mid = if kind == IWild: -1
                              else: 5
        for wp in t:
            var index = 0
            while index < wp.pos.len:
                var x = wp.pos[index]
                if kind == IWild:
                    if x > mid:
                        mid = x
                else:
                    if x < mid:
                        mid = x
                inc index, 2
        result = mid

    proc updatePos(t: var seq[WildPos], kind: ItemKind, pos: seq[int])=
        var idx = t.getIndexOf(kind)
        if idx < 0:
            var wp = new(WildPos)
            wp.id = kind
            t.add(wp)
            idx = t.getIndexOf(kind)
        t[idx].pos = pos

    var
        count1 = -1
        count2 = -1

    if wild0.len > 0:
        wildPos.updatePos(IWild, wild0)
        count1 =  sm.reelCount - wildPos.getMaximumX(IWild)

    if wild1.len > 0:
        wildPos.updatePos(IWild2, wild1)
        count2 = wildPos.getMaximumX(IWild2) + 1

    # echo "wp_count: ", wildPos
    result = max(count1, count2)

proc numberOfNewFreeSpins*(sm: SlotMachineUfo, sr:SpinResult, alreadyInFreespins: bool): int =
    let wildPos = sr.wildPos

    if wildPos.len < 2:
        return 0

    var green_index = wildPos.getIndexOf(IWild2)

    var red_index = if green_index == 0: 1
                                   else: 0

    var green_pos = wildPos[green_index].pos
    var red_pos = wildPos[red_index].pos

    var g_i = 0
    while g_i < green_pos.len - 1:
        var
            g_x = green_pos[g_i]
            g_y = green_pos[g_i + 1]
            r_i = 0

        while r_i < red_pos.len - 1:
            var
                r_x = red_pos[r_i]
                r_y = red_pos[r_i + 1]
            if g_y == r_y and (g_x - r_x in [-1,0]):
                if alreadyInFreespins:
                    if g_x - r_x == 0:
                        sr.meetIndex = r_x + r_y * 5
                    return sm.freespinsAdditionalCount
                else:
                    sr.meetIndex = r_x + r_y * 5
                    wildPos[green_index].pos.delete(g_i)
                    wildPos[green_index].pos.delete(g_i+1)
                return sm.freespinsAllCount
            inc r_i, 2
        inc g_i, 2

    return 0

proc moveWilds(sm: SlotMachineUfo, wildPos: var seq[WildPos])=
    var index = 0
    while index < wildPos.len:
        var pos_index = 0
        var skip = false
        var wp = wildPos[index]
        while pos_index < wp.pos.len:
            var
                x = wp.pos[pos_index]
                _ = wp.pos[pos_index + 1]  # y = ... was here and not used
            if wp.id == IWild:
                inc x
            elif wp.id == IWild2:
                dec x
            if x >= 0 and x < sm.reelCount:
                wp.pos[pos_index] = x
                inc pos_index, 2
            else:
                wp.pos.delete(pos_index)
                wp.pos.delete(pos_index)
                if wp.pos.len == 0:
                    wildPos.delete(index)
                    skip = true
        if not skip:
            inc index

proc placeWilds(sm: SlotMachineUfo, wildPos: var seq[WildPos], field: var seq[int8])=
    for wp in wildPos:
        var index = 0
        while index < wp.pos.len - 1:
            var
                x = wp.pos[index]
                y = wp.pos[index + 1]
            field[y * sm.reelCount + x] = index(wp.id).int8
            inc index, 2

method combinations*(sm: SlotMachineUfo, field: openarray[int8], lineCount: int): seq[Combination] =
    var mfield = newSeq[int8]()
    for f in field:
        mfield.add(f)

    for i in 0..<mfield.len:
        if mfield[i] == 1: #replace wild2 with wild, to calculate winlines
            mfield[i] = 0

    var reverse_field = newSeq[int8]()
    for row in 1..3:
        for line in 1..5:
            reverse_field.add( mfield[ (row) * 5 - line ] )

    result = sm.combinations(sm.reels, mfield, lineCount)
    for comb in sm.combinations(sm.reels, reverse_field, lineCount):
        result.add(comb)

proc spin*(sm: SlotMachineUfo, p: Profile, stage: Stage): seq[int8] =
    case stage
    of Stage.Spin:
        result = sm.reels.spin(p, sm.fieldHeight)
    of Stage.Respin:
        result = sm.reelsRespin.spin(p, sm.fieldHeight)
    of Stage.Freespin:
        result = sm.reelsFreespin.spin(p, sm.fieldHeight)
    else:
        echo "not implemented"
    # echo "spin_res: ", result.field

proc getPayout*(bet: int64, r: SpinResult): int64 =
    if r.stage == Stage.Spin:
        result -= (r.lines.len div 2) * bet # we have reverse field also #TODO: remove after proper zsm file # what do you mean?
    if r.stage != Stage.Bonus:
        for ln in r.lines:
            result += ln.payout * bet

proc getFinalPayout*(bet: int64, res: openarray[SpinResult]): int64 =
    for r in res:
        result += getPayout(bet, r)

proc createStageResult(sm: SlotMachineUfo, p: Profile, stage: Stage, cheatSpin: seq[int8] = @[]): SpinResult =
    result.new()

    if stage == Stage.Bonus:
        result.stage = stage
    else:
        if cheatSpin.len != 0:
            result.field = cheatSpin
        else:
            result.field = sm.spin(p, stage)
        result.freespinsCount = 0
        result.freespinsTotalWin = 0
        result.stage = stage
        result.noPayout = false
        result.meetIndex = -1
        sm.freespinCount = 0

method numberOfLines*(sm: SlotMachineUfo): int = sm.lines.len * 2

proc addNewWildOnField(p: Profile, sr:var SpinResult, wKind:ItemKind) =
    const WILD1 = 0
    const WILD2 = 1
    let w1position = random([0.int8,5,10])
    let w2position = random([4.int8,9,14])

    if wKind == IWild:
        sr.field[w1position] = WILD1
    else:
        sr.field[w2position] = WILD2

proc hasSymbolOnReel(field: openarray[int8], symId:int8, reelIndex:int): bool =
    var posOnReel = reelIndex
    result = false
    while posOnReel <= field.high:
        if field[posOnReel] == symId:
            return true
        posOnReel += ReelCountUfo

proc newWildsLogic(sm: SlotMachineUfo, p: Profile, sr:var SpinResult, stage: Stage) =
    var shouldTryAddWild1 = not any(sr.wildPos, proc(wp:WildPos):bool = return wp.id == IWild)
    var shouldTryAddWild2 = not any(sr.wildPos, proc(wp:WildPos):bool = return wp.id == IWild2)

    const BONUS_SYM_ID = 2

    # Add wild symbol on reel only when no bonus symbol on it.
    if shouldTryAddWild1:
        shouldTryAddWild1 = not hasSymbolOnReel(sr.field,BONUS_SYM_ID,0)
    if shouldTryAddWild2:
        shouldTryAddWild2 = not hasSymbolOnReel(sr.field,BONUS_SYM_ID,4)

    var chance = sm.wildChance

    if stage == Stage.Respin:
        chance = sm.respinWildChance
    elif stage == Stage.Freespin:
        chance = sm.fsWildChance

    if shouldTryAddWild1:
        let r = p.random(1000)
        if r < chance:
            addNewWildOnField(p, sr, IWild)

    if shouldTryAddWild2:
        let r = p.random(1000)
        if r < chance:
            addNewWildOnField(p, sr, IWild2)

proc hasWilds(wildPos: seq[WildPos]): bool =
    wildPos.len > 0

proc skipDouble5InARowWinLines(winLines:var seq[WinningLine]) =
    let lastStraightLineIndex = winLines.high div 2
    let totalStraightLines = winLines.len div 2
    for i in 0..lastStraightLineIndex:
        if winLines[i].numberOfWinningSymbols == 5:
            winLines[i+totalStraightLines].numberOfWinningSymbols = 0
            winLines[i+totalStraightLines].payout = 0

proc getFullSpinResult*(sm: SlotMachineUfo, p: Profile, bet:int64, lines: int, wildPos: seq[WildPos], freespinsCount: var int, freespinsTotalWin,linesPayout: var int64, cheatSpin: seq[int8]) : seq[SpinResult] =
    result = @[]

    var wildsMoved = wildPos

    let inFreespins = freespinsCount > 0
    if hasWilds(wildPos):
        sm.moveWilds(wildsMoved)

    var stage = Stage.Spin

    if inFreespins:
        stage = Stage.Freespin
    elif hasWilds(wildPos):
        stage = Stage.Respin

    var spin = sm.createStageResult(p, stage, cheatSpin)
    spin.wildPos = wildsMoved

    newWildsLogic(sm, p,spin,stage)

    var newWildPos = newSeq[WildPos]()
    let rc = sm.numberOfNewRespins(spin.field, newWildPos)
    if rc > 0:
        if stage != Stage.Freespin:
            spin.respinsCount = rc

        spin.wildApears = newWildPos
        if spin.wildPos.len == 0:
            spin.wildPos = newWildPos
        else:
            for nwp in newWildPos:
                var wpIndex = spin.wildPos.getIndexOf(nwp.id)
                if wpIndex < 0:
                    spin.wildPos.add(nwp)
                else:
                    for p in nwp.pos:
                        spin.wildPos[wpIndex].pos.add(p)

    let new_fc = sm.numberOfNewFreeSpins(spin, inFreespins)
    if new_fc > 0:
        if not inFreespins:
            spin.noPayout = true
        freespinsCount += new_fc
        spin.freespinsCount = freespinsCount

    if hasWilds(spin.wildPos):
        sm.placeWilds(spin.wildPos, spin.field)

    spin.lines = @[]

    if not inFreespins and spin.freespinsCount > 0: # just entered freespins.
        spin.wildPos.setLen(0)
    else:
        # no payout on respin which triggers free spins.
        spin.lines = sm.payouts(sm.combinations(spin.field, lines))
        skipDouble5InARowWinLines(spin.lines)
        linesPayout = getFinalPayout(bet, [spin])

    if inFreespins:
        freespinsTotalWin += linesPayout
        spin.freespinsTotalWin = freespinsTotalWin
        spin.freespinsCount = freespinsCount

    if stage != Stage.Freespin and spin.respinsCount > 0:
            spin.stage = Stage.Respin

    if spin.stage == Stage.Respin and not hasWilds(spin.wildPos) and spin.meetIndex < 0:
        spin.stage = Stage.Spin

    result.add(spin)

    if sm.canStartBonusGame(spin.field):
        result.add(sm.createStageResult(p, Stage.Bonus))

proc createResponse*(sm: SlotMachineUfo, spin: openarray[SpinResult], initialBalance, linesPayout, bet:int64, lines: int): JsonNode =
    result = newJObject()
    var res = newJArray()

    var fc = 0
    var noPayout = false
    var bonusTotalWin:int64 = 0
    for s in spin:
        var stageResult = newJObject()
        stageResult[$srtStage] = %($s.stage)

        if s.meetIndex > 0:
            stageResult["meetIndex"] = %s.meetIndex

        if s.stage == Stage.Respin:
            # stageResult["respinsCount"] = %s.respinsCount
            fc = s.freespinsCount
            var wild_aprears = newJArray()
            for wp in s.wildApears:
                var js_wp = newJObject()
                js_wp["id"] = %wp.id.int
                var pos_arr = newJArray()
                for pos in wp.pos:
                    pos_arr.add(%pos)
                js_wp["pos"] = pos_arr
                wild_aprears.add(js_wp)
            stageResult["wildApears"] = wild_aprears

        elif s.stage == Stage.Freespin:
            fc = s.freespinsCount
            noPayout = s.noPayout
            stageResult[$srtFreespinTotalWin] = %s.freespinsTotalWin

        elif s.stage == Stage.Bonus:
            let bonusData = newUfoBonusData(bet*lines, sm.bonusSpins)
            stageResult["bonusData"] = bonusData.toJson
            bonusTotalWin = bonusData.totalWin
            stageResult[$srtPayout] = %bonusTotalWin

        if s.stage != Stage.Bonus:
            stageResult[$srtLines] = winToJson(s.lines, bet)

            var field = newJArray()
            for n in s.field:
                field.add(%n)

            stageResult[$srtField] = field

        res.add(stageResult)

    let payout = linesPayout + bonusTotalWin
    let balance = if noPayout: initialBalance
                         else: initialBalance + payout

    result[$srtChips] = %balance
    result[$srtFreespinCount] = %fc
    result[$srtStages] = res

method paytableToJson*(sm: SlotMachineUfo): JsonNode =
    result = procCall sm.SlotMachine.paytableToJson()
    result.add("freespinsAllCount", %sm.freespinsAllCount)
    result.add("freespinsAdditionalCount", %sm.freespinsAdditionalCount)
    result.add("bonusSpins", %sm.bonusSpins)
