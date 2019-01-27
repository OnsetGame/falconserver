import json

import nimongo.bson

import falconserver.auth.profile_types
import falconserver.auth.profile
import falconserver.map.building.builditem
import falconserver.common.bson_helper
import machine_base_server
import machine_witch
import slot_data_types

export machine_witch


method createInitialState*(sm: SlotMachineWitch, profile: Profile): Bson =
    result = procCall sm.SlotMachine.createInitialState(profile)
    var potsStates = sm.initNewPots(profile)
    result[$sdtPotsStates] = potsStates.toBson()


method getResponseAndState*(sm: SlotMachineWitch, profile: Profile, prevState: Bson, jData: JsonNode, resp: var JsonNode, slotState: var Bson) =
    var freeSpinsCount, runeCounter: int
    var runeBetTotal: int64
    var freespinsTotalWin: int64
    var pots: string = "00000"
    var potsStates: seq[int] = @[]
    var cheatSpin :seq[int8]
    var cheatName: string

    if not prevState.isNil:
        if not prevState{$sdtFreespinCount}.isNil:
            freeSpinsCount = prevState{$sdtFreespinCount}.toInt32()
        if not prevState{$sdtFreespinTotalWin}.isNil:
            freespinsTotalWin = prevState{$sdtFreespinTotalWin}.toInt64()
        if not prevState{$sdtPots}.isNil:
            pots = prevState{$sdtPots}.toString()
        if not prevState{$sdtPotsStates}.isNil:
            prevState{$sdtPotsStates}.toSeqInt(potsStates)
        else:
            potsStates = sm.initNewPots(profile)
        if not prevState{$sdtRuneCounter}.isNil:
            runeCounter = prevState{$sdtRuneCounter}.toInt32()
        if not prevState{$sdtRuneBetTotal}.isNil:
            runeBetTotal = prevState{$sdtRuneBetTotal}.toInt64()
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
    let spin = sm.getFullSpinResult(profile, bet, lines, runeCounter, runeBetTotal, pots, potsStates, stage, cheatSpin, cheatName)

    if stage == Stage.FreeSpin:
        freespinsTotalWin += sm.getPayout(bet, spin[0])
        freeSpinsCount.dec()
    else:
        freespinsTotalWin = 0
    resp = sm.createResponse(spin, profile[$prfChips], bet, freeSpinsCount, pots, potsStates, freespinsTotalWin)
    freeSpinsCount = resp[$srtFreespinCount].getInt()

    if spin.len > 1:
        sm.runeCounter = 0
        sm.runeBetTotal = 0

    slotState = newBsonDocument()
    slotState[$sdtFreespinCount] = freeSpinsCount.toBson()
    slotState[$sdtFreespinTotalWin] = freespinsTotalWin.toBson()
    slotState[$sdtBet] = bet.toBson()
    slotState[$sdtPots] = spin[0].pots.toBson()
    slotState[$sdtPotsStates] = spin[0].potsStates.toBson()
    slotState[$sdtRuneCounter] = sm.runeCounter.toBson()
    slotState[$sdtRuneBetTotal] = sm.runeBetTotal.toBson()
    slotState[$sdtCheatSpin] = null()
    slotState[$sdtCheatName] = null()

const witchDefaultZsm* = staticRead("../resources/slot_005_witch.zsm")
registerSlotMachine($witchSlot, newSlotMachineWitch, witchDefaultZsm)