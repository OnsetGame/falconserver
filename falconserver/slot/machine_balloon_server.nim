import json
import tables
import sequtils

import nimongo.bson

import falconserver.auth.profile_types
import falconserver.auth.profile
import falconserver.common.bson_helper
import falconserver.map.building.builditem
import machine_balloon
import machine_base_server
import slot_data_types

export machine_balloon

method getResponseAndState*(sm: SlotMachineBalloon, profile: Profile, prevState: Bson, jData: JsonNode, resp: var JsonNode, slotState: var Bson) {.gcsafe.} =
    var
        bet = jData[$srtBet].getBiggestInt().int64
        lines = jData[$srtLines].getInt()
        totalFreespinWin: int64
        spinPayout: int64
        cheatSpin: seq[int8]
        cheatName: string
    
    sm.lastWin = @[]
    sm.lastField = @[]

    # load from mongo
    if not prevState.isNil:
        if "md" in prevState:
            sm.destructions = prevState["md"]
        if "lf" in prevState:
            prevState["lf"].toSeqInt8(sm.lastField)
        if "lw" in prevState:
            prevState["lw"].toSeqIntTuple(sm.lastWin)
        if "fs" in prevState:
            sm.freespinCount = prevState["fs"]
        if "ls" in prevState:
            if sm.freespinCount > 0:
                prevState["ls"].toSeqInt8(sm.reelsFreespin.lastSpin)
            else:
                prevState["ls"].toSeqInt8(sm.reels.lastSpin)
        if "bt" in prevState:
            if sm.freespinCount > 0:
                bet = prevState["bt"]
        if "bg" in prevState:
            sm.bonusgame = prevState["bg"]
        if $sdtFreespinTotalWin in prevState:
            totalFreespinWin = prevState[$sdtFreespinTotalWin]
        if not prevState[$sdtCheatSpin].isNil and prevState[$sdtCheatSpin].kind != BsonKindNull:
            cheatSpin = @[]
            for v in prevState[$sdtCheatSpin]:
                cheatSpin.add(v.toInt().int8)
        if not prevState[$sdtCheatName].isNil and prevState[$sdtCheatName].kind != BsonKindNull:
            cheatName = prevState[$sdtCheatName].toString()

    var chips = profile.chips
    var jSymbols: seq[JsonNode] = @[]

    let prevFreespins = sm.freespinCount
    let prevDestructions = sm.destructions

    let spinResult = sm.spin(profile, bet, lines, cheatSpin)

    if prevFreespins == 0 and prevDestructions == 0:
        chips -= lines * bet

    # hotfix bonus cheat
    if cheatSpin.len != 0 and sm.lastField.len > 15:
        sm.lastField.delete(20, 24)
        sm.lastField.delete(0, 4)

    if sm.canStartBonusGame(sm.lastField) and sm.destructions == 0:

        inc sm.destructions

        let bonusResults = sm.runBonusGame(profile)
        for i in bonusResults.field: jSymbols.add(newJInt(i))
        var jRockets = newJArray()
        var bonusGamePayout: int64
        var targets = initTable[int, int]()
        for rocket, aims in bonusResults.rockets:
            var jRocket = newJObject()
            var jAims = newJObject()

            var indx = 0
            for k, v in aims:
                var jMultiplierPayout = newJArray()
                jMultiplierPayout.add(newJInt(k[0])) # target index
                jMultiplierPayout.add(newJInt(k[1])) # symbol count in line
                jMultiplierPayout.add(newJInt(v*bet)) # payout
                jAims.add($(indx), jMultiplierPayout)
                inc indx

                bonusGamePayout += (v*bet).int64

            jRocket[rocket] = jAims
            jRockets.add(jRocket)

        chips += bonusGamePayout

        var stages = newJArray()
        var stageResult = newJObject()
        stageResult[$srtStage] = %("Bonus")
        stageResult[$srtField] = %(jSymbols)
        stageResult["rockets"] = jRockets
        stageResult[$srtPayout] = %(bonusGamePayout)
        stages.add(stageResult)
        resp = json.`%*`({
            "freeSpinsCount": sm.freespinCount,
            $srtChips: chips,
            $srtStages: stages
        })

        template markDestroyedItems()=
            const MARKER: int8 = -1
            for i in bonusResults.destrIds:
                if (i-5) < sm.lastField.len and (i-5) >= 0:
                    sm.lastField[i-5] = MARKER
            for i in 0..<sm.lastField.len:
                if sm.lastField[i] == 1: sm.lastField[i] = MARKER

        markDestroyedItems()
        sm.shiftUpLines(sm.reels)

        sm.bonusgame = true

        if sm.freespinCount == 0: totalFreespinWin = 0
        else: totalFreespinWin += bonusGamePayout
    else:

        if cheatName == "freespins":
            sm.freespinCount += 5

        for ln in spinResult.lines:
            spinPayout += ln.payout.int64 * bet.int64
        chips += spinPayout

        if sm.freespinCount == 0: totalFreespinWin = 0
        else: totalFreespinWin += spinPayout

        for i in spinResult.field:
            jSymbols.add(newJInt(i))

        var stage: string
        if sm.freespinCount > 0:
            stage = "FreeSpin"
        else:
            if prevDestructions > 0: stage = "Respin"
            else: stage = "Spin"

        var stages = newJArray()
        var stageResult = newJObject()
        stageResult[$srtStage] = %(stage)
        stageResult[$srtField] = %(jSymbols)
        stageResult[$srtLines] = winToJson(spinResult.lines, bet)
        stageResult[$srtFreespinTotalWin] = %(totalFreespinWin)

        if spinResult.destruction.len != 0:
            stageResult["destructions"] = %spinResult.destruction

        stages.add(stageResult)
        resp = json.`%*`({
            "freeSpinsCount": sm.freespinCount,
            $srtChips: chips,
            $srtStages: stages
        })

        sm.bonusgame = false

    # save state to mongo
    let lastSpin = if sm.freespinCount > 0: sm.reelsFreespin.lastSpin.toBson() else: sm.reels.lastSpin.toBson()
    let lastField = sm.lastField.toBson()
    let lastWin = sm.lastWin.toBson()
    slotState = bson.`%*`({
        "md": sm.destructions.toBson(),
        "ls": lastSpin,
        "lf": lastField,
        "lw": lastWin,
        "fs": sm.freespinCount.toBson(),
        "bt": bet.toBson(),
        "bg": sm.bonusgame.toBson(),
        $sdtFreespinTotalWin: totalFreespinWin.toBson(),
        $sdtCheatSpin: null(),
        $sdtCheatName: null()
    })

const ballonsDefaultZsm* = staticRead("../resources/slot_003_balloons.zsm")
registerSlotMachine($balloonSlot, newSlotMachineBalloon, ballonsDefaultZsm)
