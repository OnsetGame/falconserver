import json

import nimongo.bson

import falconserver.auth.profile_types
import falconserver.auth.profile
import falconserver.map.building.builditem
import falconserver.common.bson_helper
import machine_base_server
import machine_groovy
import slot_data_types

export machine_groovy

method getResponseAndState*(sm: SlotMachineGroovy, profile: Profile, prevState: Bson, jData: JsonNode, resp: var JsonNode, slotState: var Bson) =
    var cheatSpin :seq[int8]
    var rd: GroovyRestoreData
    var prevBet: int64
    rd.sevenWildInReel = newSeq[bool](sm.reelCount)

    if not prevState.isNil:
        if prevState[$sdtSevensFreespinCount].isNil: rd.sevensFreespinCount = 0
        else: rd.sevensFreespinCount = prevState[$sdtSevensFreespinCount]
        if prevState[$sdtSevensFreespinTotalWin].isNil: rd.sevensFreespinTotalWin = 0
        else: rd.sevensFreespinTotalWin = prevState[$sdtSevensFreespinTotalWin]
        if prevState[$sdtSevensFreespinProgress].isNil: rd.sevensFreespinProgress = 0
        else: rd.sevensFreespinProgress = prevState[$sdtSevensFreespinProgress]

        if prevState[$sdtBarsFreespinCount].isNil: rd.barsFreespinCount = 0
        else: rd.barsFreespinCount = prevState[$sdtBarsFreespinCount]
        if prevState[$sdtBarsFreespinTotalWin].isNil: rd.barsFreespinTotalWin = 0
        else: rd.barsFreespinTotalWin = prevState[$sdtBarsFreespinTotalWin]
        if prevState[$sdtBarsFreespinProgress].isNil: rd.barsFreespinProgress = 0
        else: rd.barsFreespinProgress = prevState[$sdtBarsFreespinProgress]

        if not prevState[$sdtSevenWildInReel].isNil:
            let sevensInReels = prevState[$sdtSevenWildInReel]
            for i in 0..<sm.reelCount:
                rd.sevenWildInReel[i] = sevensInReels[i].bool

        if not prevState[$sdtCheatSpin].isNil and prevState[$sdtCheatSpin].kind != BsonKindNull:
            cheatSpin = @[]
            for v in prevState[$sdtCheatSpin]:
                cheatSpin.add(v.toInt().int8)

        if not prevState[$sdtBet].isNil:
            prevBet = prevState[$sdtBet].toInt64()

    var bet = jData[$srtBet].getBiggestInt().int64
    let lines = jData[$srtLines].getInt()
    resp = sm.getFullSpinResult(profile, prevBet, bet, lines, rd, cheatSpin)

    slotState = newBsonDocument()
    slotState[$sdtSevensFreespinCount] = rd.sevensFreespinCount.toBson()
    slotState[$sdtSevensFreespinTotalWin] = rd.sevensFreespinTotalWin.toBson()
    slotState[$sdtSevensFreespinProgress] = rd.sevensFreespinProgress.toBson()
    slotState[$sdtBarsFreespinCount] = rd.barsFreespinCount.toBson()
    slotState[$sdtBarsFreespinTotalWin] = rd.barsFreespinTotalWin.toBson()
    slotState[$sdtBarsFreespinProgress] = rd.barsFreespinProgress.toBson()
    if rd.sevensFreespinCount > 0:
        slotState[$sdtFreespinCount] = rd.sevensFreespinCount.toBson()
    elif rd.barsFreespinCount > 0:
        slotState[$sdtFreespinCount] = rd.barsFreespinCount.toBson()
    else:
        slotState[$sdtFreespinCount] = 0.toBson()
    slotState[$sdtSevenWildInReel] = rd.sevenWildInReel.toBson()
    slotState[$sdtRespinsCount] = rd.sevensFreespinProgress.toBson()
    if not resp{"stages"}.isNil and not resp["stages"][0]{"field"}.isNil:
        slotState[$sdtLastField] = resp["stages"][0]["field"].toBson()
    #todo: make respins restore on client
    # slotState[$sdtRespinsCount] = resp{$srtRespinCount}.getInt(0).toBson()
    slotState[$sdtBet] = bet.toBson()
    slotState[$sdtCheatSpin] = null()
    slotState[$sdtCheatName] = null()

const groovyDefaultZsm* = staticRead("../resources/slot_008_groovy.zsm")
registerSlotMachine($groovySlot, newSlotMachineGroovy, groovyDefaultZsm)

