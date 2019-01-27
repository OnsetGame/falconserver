## Base slot machine types and procedure
import json
import hashes
import math

import strutils
import sequtils
import tables
import nimongo.bson
import falconserver / common / [ bson_helper ]

import machine_base_types
export machine_base_types

var slotMachineRegistry = initTable[string, SlotMachine]()
type SlotInitializer = proc(j: JsonNode): SlotMachine
var slotMachineInitializers* = initTable[string, SlotInitializer]()


proc registerSlotMachine*[T](gameID: string, initializer: proc(j: JsonNode): T, defaultZsm: static[string]) =
    let creator = proc(j: JsonNode): SlotMachine =
        var j = j
        if j.isNil:
            j = parseJson(defaultZsm)
        return initializer(j)
    slotMachineInitializers[gameId] = creator
    slotMachineRegistry[gameID] = creator(nil)

proc getSlotMachineByGameID*(gameID: string): SlotMachine =
    let p = slotMachineRegistry.getOrDefault(gameID)
    if p.isNil:
        echo "SlotMachine with gameID " & gameID & " doesn't exist"
    result = p

proc getSlotMachines*(): Table[string, SlotMachine] =
    result = slotMachineRegistry

proc slotMachineDesc*(filename: static[string]): JsonNode =
    const contents = staticRead(filename)
    result = parseJson(contents)


proc newErrorInvalidZsm*(msg: string): ErrorInvalidZsm =
    ## Creates new instance of the ErrorInvalidZsm_ exception.
    result.new
    result.msg = msg

method itemSetDefault*(sm: SlotMachine): ItemSet {.base.} =
    ## Returns default (initial in editor) item set for the slot machine
    @[]

proc toBson*(s: seq[WinningLine]): Bson =
    var data: seq[tuple[k: int, v: int64]]
    for v in s: data.add( (v[0], v[1]) )
    return data.toBson()

proc toSeqIntTuple*(b: Bson, s: var seq[WinningLine]) =
    var ln: int = 0
    for v in b: inc ln
    s.setLen(0)
    var i = 0
    while i < ln:
        let k: int = b[i]
        let v: int64 = b[i+1]
        s.add( (k, v) )
        i += 2

method numberOfLines*(sm: SlotMachine): int {.base.} = sm.lines.len

method `$`*(sm: SlotMachine): string {.base.} =
    ## Stringification for beautiful textual output preferrably to the
    ## terminal.
    result = "SlotMachine:\n  Items:\n"
    for item in sm.items:
        result &= "    " & $item.id & ": " & $item.kind & "\n"
    result &= "  Field height:\n    " & $sm.fieldHeight & "\n"
    result &= "  Lines:\n"
    let linecounter: int = 1
    for line in sm.lines:
        result &= "    Line " & $linecounter & ": [ "
        for index in line:
            result &= $index & " "
        result &= "]\n"
    result &= "  Paytable:\n"
    var inarow: int8 = 1
    for column in sm.paytable:
        inc(inarow)
        result &= "    " & $inarow & "-in-a-row: [ "
        for row in column:
            result &= $row & " "
        result &= " ]\n"
    var reelnum: int8 = 0
    result &= "  Reels:\n"
    for reel in sm.reels.reels:
        inc(reelnum)
        result &= "    Reel " & $reelnum & ":\n      [ "
        for item in reel:
            result &= $item.id & " "
        result &= " ]\n"

proc getReels*(sm: SlotMachine, jMachine: JsonNode, name: string): Layout =
    var jRecord: JsonNode = nil

    result.new()
    result.reels = @[]

    if jMachine.hasKey(name):
        jRecord = jMachine{name}
        if not jRecord.isNil:
            for jReel in jRecord:
                var reel: Reel = @[]
                for item in jReel:
                    var id: int8 = 0
                    for i in sm.items:
                        if i.name == item["id"].getStr():
                            id = i.id
                            break
                    reel.add(ItemObj(id: id, kind: ItemKind(item["type"].getInt()), name: item["id"].getStr()))
                result.reels.add(reel)

method initSlotMachine*(sm: SlotMachine, jMachine: JsonNode = nil) {.base, gcsafe.} =
    ## Base slot machine constructor from ZSM file
    sm.items = @[]
    sm.paytable = @[]
    sm.fieldHeight = 3
    sm.lines = @[]
    sm.reelsFreespin.new
    sm.reelsFreespin.reels = @[]

    if not jMachine.isNil:
        sm.items = @[]

        var jRecord: JsonNode = nil

        jRecord = jMachine["item_set"]
        var i: int8 = 0
        for jItem in jRecord:
            let item = ItemObj(id: i, kind: ItemKind(jItem["type"].getInt()), name: jItem["id"].getStr())
            assert item notin sm.items
            sm.items.add(item)
            inc i

        jRecord = jMachine["field_height"]
        sm.fieldHeight = int8(jRecord.getInt())

        jRecord = jMachine["lines"]
        for jLine in jRecord:
            var line: Line = @[]
            for jItem in jLine:
                add(line, int8(jItem.getInt()))
            sm.lines.add(line)

        jRecord = jMachine["pay_table"]
        for jColumn in jRecord:
            var column: seq[int] = @[]
            for row in jColumn:
                column.add(row.getInt())
            sm.paytable.add(column)

        sm.reels = sm.getReels(jMachine, "reels")
        sm.reelsRespin = sm.getReels(jMachine, "reels_respin")
        sm.reelsFreespin = sm.getReels(jMachine, "reels_freespin")

when declared(parseFile):
    proc initSlotMachine*(sm: SlotMachine, filename: string) =
        ## Base Slot machine constructor from ZSM file.
        ##
        ## ZSM format represents classical slot machine with independent reels
        ## that contain items in a predefined spinning order on each reel.
        ##
        ## This constructor raises `ErrorInvalidZsm` exception if machine cannot be
        ## validly constructor from ZSM file.
        let jMachine: JsonNode = try: parseFile(filename) except JsonParsingError: nil
        if jMachine == nil:
            raise newErrorInvalidZsm("Error parsing json from: " & filename)
        sm.initSlotMachine(jMachine)

proc `==`*(item: ItemObj, other: ItemObj): bool =
    ## Test for items equality: id is enough, but still
    ## ItemKind_ equality assertion must also be fulfilled.
    assert if item.id == other.id: item.kind == other.kind else: true
    return item.id == other.id

proc `hash`*(item: ItemObj): Hash =
    ## Calculating hash for having ability to use ItemObj as a table key
    return hash(item.id)

# method bonusGameRandomNumber*(sm: SlotMachine, p: Profile, lowerBound: int, upperBound: int): int {.base.} =
#     ## Bonus game based on simple random number generator given in the specified
#     ## range (both lower and upper bounds are inclusive).
#     return lowerBound + p.random(upperBound - lowerBound + 1)

method bonusGameRandomSequence*(sm: SlotMachine, items: seq[int], returnSize: int): seq[int] {.base.} =
    ## Bonus game based on spreading sequence of elements randomly over larger
    ## sequence thus giving empty places after randomization.
    return @[]

# =============
#    LAYOUT
# =============

proc newLayout*(count: int): Layout =
    ## Reels Layout constructor
    result.new()
    result.reels = @[]
    for i in 0 ..< count: result.reels.add(@[])

proc reelCount*(layout: Layout): int = layout.reels.len
    ## Number of slot machine reels

method hasWon*(sm: SlotMachine, lines: seq[WinningLine]): bool {.base, gcsafe.} =
    ## Returns true if WinningLine sequence gives payouts, and false - otherwise
    any(lines, proc(item: WinningLine): bool = item.payout > 0)

proc hasLost*(sm: SlotMachine, lines: seq[WinningLine]): bool =
    ## Return true if WinningLines sequence does not give payouts, and true -
    ## otherwise
    not sm.hasWon(lines)


proc countSymbolsOfType*(sm: SlotMachine, field: openarray[int8], kind: ItemKind): int =
    ## Count symbols of specific type.
    for i in 0 ..< sm.reelCount:
        for j in 0 ..< sm.fieldHeight:
            let itemIndex = field[j * sm.reelCount + i]
            if itemIndex >= 0 and sm.items[itemIndex].kind == kind:
                inc result


proc countSymbolsOfType*(sm: SlotMachine, field: openarray[int8], kind: ItemKind, x, y: var int): int =
    ## Count symbols of specific type. Return coordinates (x = reel index) of the
    ## symbol closest to center. layout is a specific layout to count symbols
    ## for.
    let centerX = int((sm.reelCount + 1) / 2)
    let centerY = int((sm.fieldHeight + 1) / 2)

    var minDist = 10000000
    for i in 0 ..< sm.reelCount:
        for j in 0 ..< sm.fieldHeight:
            if sm.items[field[j * sm.reelCount + i]].kind == kind:
                inc result
                let dx = centerX - i
                let dy = centerY - j
                let d = dx * dx + dy * dy
                if d < minDist:
                    x = i
                    y = j
                    minDist = d

method countMaximumsOnField*(sm: SlotMachine, layout: Layout): Table[ItemObj, int] {.base.} =
    ## Counts how much elements are possible on field with current
    ## reels layout.
    result = initTable[ItemObj, int]()
    for item in sm.items:
        var maxForItem = 0
        for reel in layout.reels:
            var maxForItemOnReel = 0
            for i in 0 ..< reel.len() - sm.fieldHeight:
                var currentMaxForItemOnReel = 0
                for j in i ..< i + sm.fieldHeight:
                    if item.id == reel[j].id:
                        inc(currentMaxForItemOnReel)
                if currentMaxForItemOnReel > maxForItemOnReel:
                    maxForItemOnReel = currentMaxForItemOnReel
            maxForItem += maxForItemOnReel
        result[item] = maxForItem

method canStartBonusGame*(sm: SlotMachine, field: openarray[int8]): bool {.base, gcsafe.} =
    ## Checks if current spin result (field) is a winning result that
    ## allows to start bonus game (slot-specific)
    raise new(ErrorNotImplemented)

proc winToJson*(lines: openarray[WinningLine], bet: int64): JsonNode =
    result = newJArray()

    for i in 0..< lines.len:
        if lines[i].payout > 0:
            var line = newJObject()

            line["index"] = %i
            line["symbols"] = %lines[i].numberOfWinningSymbols
            line["payout"] = %(lines[i].payout.int64 * bet)
            result.add(line)


proc reverseField*(sm: SlotMachine, field: openarray[int8]): seq[int8]=
    result = @[]
    for row in 1..3:
        for line in 1..5:
            result.add(field[(row) * 5 - line])

proc combinations*(sm: SlotMachine, layout: Layout, field: openarray[int8], lineCount, reverseLineFrom: int): seq[Combination] =
    result = @[]
    let reverseField = sm.reverseField(field)
    for lineindex in 0 ..< lineCount:
        let line: Line = sm.lines[lineindex]
        var combination: Combination = @[]
        for reelnum, reel in layout.reels:
            if lineindex < reverseLineFrom:
                combination.add(sm.items[field[line[reelnum] * layout.reels.len + reelnum]])
            else:
                combination.add(sm.items[reverseField[line[reelnum] * layout.reels.len + reelnum]])
        result.add(combination)

proc combinations*(sm: SlotMachine, layout: Layout, field: openarray[int8], lineCount: int): seq[Combination] =
    ## Fetch winning combinations for given slot machine field generated
    ## after a spin with _justSpin_ procedure. _lines_ parameter defines
    ## how many lines one has put the bet on. _layout_ parameter defines
    ## specific layout to count combinations against (for multi-reels slots).
    result = @[]
    for lineindex in 0 ..< lineCount:
        let line: Line = sm.lines[lineindex]
        var combination: Combination = @[]
        for reelnum, reel in layout.reels:
            combination.add(sm.items[field[line[reelnum] * layout.reels.len + reelnum]])
        result.add(combination)


method getSlotID*(sm: SlotMachine): string {.base, gcsafe.} =
    raise new(ErrorNotImplemented)

method getBigwinMultipliers*(sm: SlotMachine): seq[int] {.base, gcsafe.} =
    ## should return Bigwin, Hugewin, Megawin multipliers
    raise new(ErrorNotImplemented)

method numberOfNewFreeSpins*(sm: SlotMachine, field: openarray[int8]): int {.base.} =
    ## Counts number of new free spins for current field
    raise new(ErrorNotImplemented)

proc debugSlotField*(sm: SlotMachine, field: seq[int8]): string =
    ## Return text representation of field
    result = ""
    for row in 0 ..< sm.fieldHeight:
        for col in 0 ..< sm.reelCount():
            result = result & $field[row * sm.reelCount() + col] & " "
        result &= "\n"

method paytableToJson*(sm: SlotMachine): JsonNode {.base.} =
    result = newJObject()
    var jItems = newJArray()
    for item in sm.items:
        jItems.add(%item.name)
    result.add("items", jItems)

    var jPayTable = newJArray()
    for row in sm.paytable:
        var jLine = newJArray()
        for elem in row:
            jLine.add(%elem)
        jPayTable.add(jLine)
    result.add("table", jPayTable)


import falconserver.auth.profile_random

method createInitialState*(sm: SlotMachine, profile: Profile): Bson {.base, gcsafe.} =
    result = newBsonDocument()

proc spin*(layout: Layout, p: Profile, height: int8): seq[int8] =
    ## Perform physical spin for selected layout (reel set)
    result = newSeq[int8](height * layout.reelCount)
    layout.lastSpin = @[]
    for index, reel in layout.reels:
        let offset = p.random(reel.len()).int16
        layout.lastSpin.add(offset.int8)
        for i in 0 ..< height:
            result[layout.reelCount * i + index] = reel[(offset + i) mod reel.len].id

proc spin*(sm: SlotMachine, p: Profile, layout: Layout, bet: int64, lineCount: int, isJackpot: var bool): tuple[field: seq[int8], lines: seq[WinningLine]]=
    let
        field = layout.spin(p, sm.fieldHeight)
        lines = sm.payouts(sm.combinations(field, lineCount), isJackpot)

    return (field: field, lines: lines)

proc spin*(sm: SlotMachine, p: Profile, layout: Layout, bet: int64, lineCount: int): tuple[field: seq[int8], lines: seq[WinningLine]] =
    let
        field = layout.spin(p, sm.fieldHeight)
        lines = sm.payouts(sm.combinations(field, lineCount))

    return (field: field, lines: lines)

method spin*(sm: SlotMachine, p: Profile, bet: int64, lineCount: int): tuple[field: seq[int8], lines: seq[WinningLine]] {.base.} =
    ## Spins every reel one-by-one creating spinResult as a sequence of
    ## offsets modeling reel spinning on a slot machine.
    raise new(ErrorNotImplemented)
