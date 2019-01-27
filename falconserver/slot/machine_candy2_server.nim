import json

import nimongo.bson
import falconserver.auth.profile_types
import falconserver.auth.profile
import falconserver.map.building.builditem
import machine_base_server
import machine_candy2
import slot_data_types

method getResponseAndState*(sm: SlotMachineCandy2, profile: Profile, prevState: Bson, jData: JsonNode, resp: var JsonNode, slotState: var Bson) =

    let slotID = sm.getSlotID()
    var freeSpinsCount: int
    var freespinsTotalWin: int64
    var cheatSpin :seq[int8]
    var cheatName: string

    if not prevState.isNil:
        if not prevState{$sdtFreespinCount}.isNil:
            freeSpinsCount = prevState{$sdtFreespinCount}.toInt32()
        if not prevState{$sdtFreespinTotalWin}.isNil:
            freespinsTotalWin = prevState{$sdtFreespinTotalWin}.toInt64()
        if not prevState[$sdtCheatName].isNil:
            cheatName = prevState[$sdtCheatName].toString()
        if not prevState[$sdtCheatSpin].isNil and prevState[$sdtCheatSpin].kind != BsonKindNull:
            cheatSpin = @[]
            for v in prevState[$sdtCheatSpin]:
                cheatSpin.add(v.toInt().int8)

    let bet = jData[$srtBet].getBiggestInt().int64
    let lines = jData[$srtLines].getInt()
    var stage = Stage.Spin

    if freeSpinsCount > 0:
        stage = Stage.FreeSpin

    let spin = sm.getFullSpinResult(profile, bet, lines, stage, cheatSpin, cheatName)

    if stage == Stage.FreeSpin:
        freespinsTotalWin += sm.getPayout(bet, spin[0])
    else:
        freespinsTotalWin = 0

    resp = sm.createResponse(spin, profile[$prfChips], bet, freeSpinsCount, freespinsTotalWin)
    freeSpinsCount = resp[$srtFreespinCount].getInt()

    if stage == Stage.FreeSpin:
        freeSpinsCount.dec()

    slotState = newBsonDocument()
    slotState[$sdtFreespinCount] = freeSpinsCount.toBson()
    slotState[$sdtFreespinTotalWin] = freespinsTotalWin.toBson()
    slotState[$sdtBet] = bet.toBson()
    slotState[$sdtCheatSpin] = null()
    slotState[$sdtCheatName] = null()


const candy2DefaultZsm* = staticRead("../resources/slot_007_candy2.zsm")
registerSlotMachine($candySlot2, newSlotMachineCandy2, candy2DefaultZsm)