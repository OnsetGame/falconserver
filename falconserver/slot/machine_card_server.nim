import json, strutils

import nimongo.bson
import falconserver.auth.profile_types
import falconserver.auth.profile
import falconserver.auth.profile_random
import falconserver.map.building.builditem
import machine_base_server
import machine_card
import slot_data_types

method getResponseAndState*(sm: SlotMachineCard, profile: Profile, prevState: Bson, jData: JsonNode, resp: var JsonNode, slotState: var Bson) =
    let slotID = sm.getSlotID()
    var freespinsTotalWin: int64
    var cheatSpin :seq[int8]
    var cheatName: string

    if not prevState.isNil:
        if not prevState{$sdtWinFreespins}.isNil:
            sm.winFreespins = prevState{$sdtWinFreespins}.toBool()
        if not prevState{$sdtFreespinCount}.isNil:
            sm.freeSpinsCount = prevState{$sdtFreespinCount}.toInt32()
        if not prevState{$sdtCardFreespinsType}.isNil:
            sm.fsType = parseEnum[FreespinsType](prevState{$sdtCardFreespinsType}.toString())
        if not prevState{$sdtFreespinTotalWin}.isNil:
            freespinsTotalWin = prevState{$sdtFreespinTotalWin}.toInt32()
        if not prevState[$sdtCheatName].isNil:
            cheatName = prevState[$sdtCheatName].toString()
        if not prevState[$sdtCheatSpin].isNil and prevState[$sdtCheatSpin].kind != BsonKindNull:
            cheatSpin = @[]
            for v in prevState[$sdtCheatSpin]:
                cheatSpin.add(v.toInt().int8)

    let bet = jData[$srtBet].getBiggestInt().int64
    let lines = jData[$srtLines].getInt()
    var stage = Stage.Spin

    if sm.freeSpinsCount > 0:
        stage = Stage.FreeSpin

    if jData.hasKey($srtData):
        var fsType = try: parseEnum[FreespinsType](jData[$srtData].getStr()) except: jData[$srtData].getInt().FreespinsType
        if fsType != FreespinsType.NoFreespin:
            sm.fsType = fsType
    else:
        if sm.freeSpinsCount == 0:
            sm.fsType = NoFreespin

    let spin = sm.getFullSpinResult(profile, bet, lines, stage, cheatSpin, cheatName)

    if sm.winFreespins:
        sm.freeSpinsCount = sm.freespins

        # let r = profile.random(1..4)
        # sm.fsType = r.FreespinsType

    if stage == Stage.FreeSpin:
        freespinsTotalWin += sm.getPayout(bet, spin[0])
    else:
        freespinsTotalWin = 0

    resp = sm.createResponse(spin, profile[$prfChips], bet, freespinsTotalWin)
    sm.freeSpinsCount = resp[$srtFreespinCount].getInt()

    if stage == Stage.FreeSpin:
        sm.freeSpinsCount.dec()

    slotState = newBsonDocument()
    slotState[$sdtFreespinCount] = sm.freeSpinsCount.toBson()
    slotState[$sdtFreespinTotalWin] = freespinsTotalWin.toBson()
    slotState[$sdtBet] = bet.toBson()
    slotState[$sdtCardFreespinsType] = ($sm.fsType).toBson()
    slotState[$sdtWinFreespins] = sm.winFreespins.toBson()
    slotState[$sdtCheatSpin] = null()
    slotState[$sdtCheatName] = null()

const cardDefaultZsm* = staticRead("../resources/slot_009_card.zsm")
registerSlotMachine($cardSlot, newSlotMachineCard, cardDefaultZsm)
