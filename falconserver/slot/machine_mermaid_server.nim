import json

import nimongo.bson

import falconserver.auth.profile_types
import falconserver.auth.profile
import falconserver.map.building.builditem
import machine_base_server
import machine_mermaid
import slot_data_types

export machine_mermaid

method getResponseAndState*(sm: SlotMachineMermaid, profile: Profile, prevState: Bson, jData: JsonNode, resp: var JsonNode, slotState: var Bson) =
    var freespinCount: int = 0
    var freespinTotalWin: int64 = 0
    var cheatSpin: seq[int8]

    if not prevState.isNil:
        if prevState[$sdtFreespinCount].isNil:
            freespinCount = 0
        else:
            freespinCount = prevState[$sdtFreespinCount]
        if prevState[$sdtFreespinTotalWin].isNil:
            freespinTotalWin = 0
        else:
            freespinTotalWin = prevState[$sdtFreespinTotalWin]
        if not prevState[$sdtCheatSpin].isNil and prevState[$sdtCheatSpin].kind != BsonKindNull:
            cheatSpin = @[]
            for v in prevState[$sdtCheatSpin]:
                cheatSpin.add(v.toInt().int8)
        if not prevState[$sdtFreeMultipleWild].isNil:
            sm.wildMultiplier = prevState[$sdtFreeMultipleWild].toInt()

    let bet = jData[$srtBet].getBiggestInt().int64
    let lines = jData[$srtLines].getInt()
    let oldFreespins = freespinCount
    let spinResult = sm.getFullSpinResult(profile, bet, lines, freespinCount, freespinTotalWin, cheatSpin)
    resp = sm.createResponse(spinResult.spin, spinResult.mermaidPos, profile[$prfChips], bet, lines)

    if freespinCount > 0 :
        if oldFreespins > 0:
            dec freespinCount
            if freespinCount == 0:
                freespinTotalWin = 0

    slotState = newBsonDocument()
    slotState[$sdtFreespinCount] = freespinCount.toBson()
    slotState[$sdtFreespinTotalWin] = freespinTotalWin.toBson()
    slotState[$sdtBet] = bet.toBson()
    slotState[$sdtFreeMultipleWild] = sm.wildMultiplier.toBson()
    slotState[$sdtCheatSpin] = null()
    slotState[$sdtCheatName] = null()


const mermaidDefaultZsm* = staticRead("../resources/slot_006_mermaid.zsm")
registerSlotMachine($mermaidSlot, newSlotMachineMermaid, mermaidDefaultZsm)
