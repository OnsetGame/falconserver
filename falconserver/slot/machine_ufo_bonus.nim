import sequtils, tables
import slot_data_types
import json, strutils
import falconserver.auth.profile_random
import machine_ufo_types

const PIPES_ON_FIELD = PIPES_IN_ROW * PIPES_IN_COLUMN
const CROSS_PIPE_POS = 3
const DOUBLE_WIN_PIPE_POS = 5
const TOTAL_PIPES = 7

const KEY_WIN = "w"
const KEY_DOUBLE = "d"
const KEY_FILLORDER = "fo"

proc newFillInfo(pos:int8,animDir:MilkFillDirection): FillInfo =
    result.new()
    result.pipePos = pos
    result.fillAnimDirection = animDir

proc newBonusSpinResult*(): BonusSpinResult =
    result.new()
    # random field with crossPipe at left mid pos.
    result.field = newSeq[int8](PIPES_ON_FIELD)
    for i in 0..<PIPES_ON_FIELD:
        result.field[i] = random(TOTAL_PIPES-1).int8 + 1
    result.field[CROSS_PIPE_POS] = pipeCross.int8

    #result.field = @[4.int8,3,5,0,5,6,2,1,2] #Double win field check.

    #result.field = @[6.int8,6,6,0,5,3,1,2,2]  # Both direction milk fill animation check

    # crossPipe will always got milk
    result.stateOfFullness = newSeq[bool](PIPES_ON_FIELD)
    result.stateOfFullness[CROSS_PIPE_POS] = true

    # crossPipe always be filled first
    result.fillOrder = newSeq[seq[FillInfo]]()
    result.fillOrder.add(@[newFillInfo(CROSS_PIPE_POS.int8,direct)])

    result.win = 0
    result.hasDouble = false


proc fillPipesWithMilk*(ubd:UfoBonusData)
proc generateBonusSpinResults*(ubd:UfoBonusData, bonusSpins: int) =
    ubd.spinResults = newSeq[BonusSpinResult](bonusSpins)

    for sri in 0..<bonusSpins: #spin result index
        ubd.spinResults[sri] = newBonusSpinResult()

    ubd.fillPipesWithMilk()

proc newUfoBonusData*(totalBet: int64, bonusSpins: int): UfoBonusData =
    result.new()
    result.totalWin = 0
    result.totalBet = totalBet
    result.generateBonusSpinResults(bonusSpins)

proc toString(bf:BonusField): string =
    result = ""
    for i in 0..<PIPES_IN_COLUMN:
        let firstRowIndex = i*PIPES_IN_ROW
        let lastRowIndex = i*PIPES_IN_ROW + PIPES_IN_ROW - 1
        for boundsIndex in firstRowIndex..lastRowIndex:
            result &= $bf[boundsIndex] & " "
        result &= "\n"

proc `$`*(fi:FillInfo): string =
    result = "{$#,$#}".format($fi.pipePos, $fi.fillAnimDirection.int)

proc `%`(fi:FillInfo): JsonNode =
    result = newJArray()
    result.add(%fi.pipePos)
    result.add(%fi.fillAnimDirection.int)

proc `$`*(ubd:UfoBonusData): string =

    for sr in ubd.spinResults:
        result &= sr.field.toString
        result &= "\n----------\n"

proc backwardDirection(pd:PipeDirection): PipeDirection =
    result = ((pd.int8 + 2) mod 4).PipeDirection

proc willGetMilk(bsr:BonusSpinResult, pipeIndex:int8): FillInfo =
    ## Check pipes from all directions.
    result = nil
    let neighborPipesIndexes = getNeighborPipesIndexes(pipeIndex)
    for dir in Left..Down:
        let pType = bsr.field[pipeIndex].Pipes
        if pipesConnectors[pType][dir.int]:
            let neighborPipeIndex = neighborPipesIndexes[dir.int]
            if neighborPipeIndex in 0..<PIPES_ON_FIELD:
                let dirToThisPipe = backwardDirection(dir)
                let neighborPipe = bsr.field[neighborPipeIndex].Pipes
                if bsr.stateOfFullness[neighborPipeIndex] and couldPipeProvideMilk(neighborPipe, dirToThisPipe):
                    if result.isNil:
                        let animDir = pipesFillAnimDirection[pType][dir]
                        result = newFillInfo(pipeIndex, animDir)
                    else:
                        result.fillAnimDirection = both

proc checkDoubleWin(bsr:BonusSpinResult):bool =
    let rightMidPipe = bsr.field[DOUBLE_WIN_PIPE_POS].Pipes
    bsr.hasDouble = bsr.stateOfFullness[DOUBLE_WIN_PIPE_POS] and pipesConnectors[rightMidPipe][Right.int]
    result = bsr.hasDouble

proc createPipesFillOrder(bsr:BonusSpinResult) =
    var lastFilledPipes = 1 # We got first filled crossPipe
    while lastFilledPipes > 0:
        var nextFilledPipes = newSeq[FillInfo]()
        for i,s in bsr.stateOfFullness:
            if not s:
                let fi = bsr.willGetMilk(i.int8)
                if not fi.isNil:
                    nextFilledPipes.add(fi)

        lastFilledPipes = nextFilledPipes.len
        if lastFilledPipes > 0:
            for fi in nextFilledPipes:
                bsr.stateOfFullness[fi.pipePos] = true
            bsr.fillOrder.add(nextFilledPipes)

proc fillPipesWithMilk*(ubd:UfoBonusData) =
    for i,sr in ubd.spinResults:
        sr.createPipesFillOrder()
        for pipes in sr.fillOrder:
            sr.win += pipes.len * ubd.totalBet
        if sr.checkDoubleWin():
            sr.win *= 2
        ubd.totalWin += sr.win


proc toJson*(bsr:BonusSpinResult): JsonNode =
    result = newJObject()
    var field = newJArray()
    for p in bsr.field:
        field.add(%p)
    result["field"] = field
    var fillOrder = newJArray()
    for fillInfos in bsr.fillOrder:
        var nextPipes = newJArray()
        for fi in fillInfos:
            nextPipes.add(%fi)
        fillOrder.add(nextPipes)
    result[KEY_FILLORDER] = fillOrder
    result[KEY_WIN] = %bsr.win
    result[KEY_DOUBLE] = %bsr.hasDouble

proc toJson*(ubd:UfoBonusData): JsonNode =
    result = newJObject()
    result[$srtPayout] = %ubd.totalWin
    var spinResults = newJArray()
    for bsr in ubd.spinResults:
        spinResults.add(bsr.toJson)
    result["sr"] = spinResults


when isMainModule:
    echo "UfoBonus"
    #randomize()
    let ubd = newUfoBonusData(5000, 5)

    echo ubd.toJson






