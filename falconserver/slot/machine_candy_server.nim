import json

import nimongo.bson

import falconserver.auth.profile_types
import falconserver.auth.profile
import falconserver.map.building.builditem
import machine_base_server
import machine_candy
import slot_data_types

export machine_candy

method getResponseAndState*(sm: SlotMachineCandy, profile: Profile, prevState: Bson, jData: JsonNode, resp: var JsonNode, slotState: var Bson) =

    let slotID = sm.getSlotID()
    var scatters, freeSpinsCount: int
    var freespinsTotalWin, scattersTotalBet: int64
    var cheatSpin :seq[int8]
    var cheatName: string

    if not prevState.isNil:
        if not prevState{$sdtScatters}.isNil:
            scatters = prevState{$sdtScatters}.toInt32()
        if not prevState{$sdtFreespinCount}.isNil:
            freeSpinsCount = prevState{$sdtFreespinCount}.toInt32()
        if not prevState{$sdtFreespinTotalWin}.isNil:
            freespinsTotalWin = prevState{$sdtFreespinTotalWin}.toInt64()
        if not prevState{$sdtScattersTotalBet}.isNil:
            scattersTotalBet = prevState{$sdtScattersTotalBet}.toInt64()
        if not prevState[$sdtCheatName].isNil:
            cheatName = prevState[$sdtCheatName].toString()
        if not prevState[$sdtCheatSpin].isNil and prevState[$sdtCheatSpin].kind != BsonKindNull:
            cheatSpin = @[]
            for v in prevState[$sdtCheatSpin]:
                cheatSpin.add(v.toInt().int8)

    var bet = jData[$srtBet].getBiggestInt()
    let lines = jData[$srtLines].getInt()
    var stage = Stage.Spin

    if scatters == CANDY_MAX_SCATTERS:
        scatters = 0

    if freeSpinsCount > 0 or scatters == CANDY_MAX_SCATTERS:
        stage = Stage.FreeSpin
        bet = scattersTotalBet div 5

    let spin = sm.getFullSpinResult(profile, bet, lines, stage, cheatSpin, cheatName)
    let newScatters = sm.numberOfNewScatters(spin[0].field)

    if newScatters == 1:
        scatters.inc()
        scattersTotalBet += bet

    if scatters == CANDY_MAX_SCATTERS:
        freeSpinsCount = sm.freespinsMax

    if stage == Stage.FreeSpin:
        freespinsTotalWin += sm.getPayout(bet, spin[0])
        if freeSpinsCount == 1:
            scattersTotalBet = 0
        freeSpinsCount.dec()
    else:
        freespinsTotalWin = 0

    resp = sm.createResponse(spin, profile[$prfChips], bet, scatters, freeSpinsCount, freespinsTotalWin)
    slotState = newBsonDocument()
    slotState[$sdtScatters] = scatters.toBson()
    slotState[$sdtFreespinCount] = freeSpinsCount.toBson()
    slotState[$sdtFreespinTotalWin] = freespinsTotalWin.toBson()
    slotState[$sdtScattersTotalBet] = scattersTotalBet.toBson()
    slotState[$sdtBet] = bet.toBson()
    slotState[$sdtCheatSpin] = null()
    slotState[$sdtCheatName] = null()

const candyDefaultZsm* = staticRead("../resources/slot_004_candy.zsm")
registerSlotMachine($candySlot, newSlotMachineCandy, candyDefaultZsm)
