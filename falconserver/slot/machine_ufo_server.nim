import json

import nimongo.bson

import falconserver.auth.profile_types
import falconserver.auth.profile
import falconserver.map.building.builditem
import machine_base_server
import machine_ufo
import slot_data_types

export machine_ufo

method getResponseAndState*(sm: SlotMachineUfo, profile: Profile, prevState: Bson, jData: JsonNode, resp: var JsonNode, slotState: var Bson) =

    var wildPos: seq[WildPos] = @[]
    var freespinCount = 0
    var freespinTotalWin = 0'i64
    var cheatSpin :seq[int8]

    block ufo_loadFromDB:
        if not prevState.isNil:
            if not prevState{$sdtFreespinCount}.isNil:
                freespinCount = prevState{$sdtFreespinCount}
            if not prevState{$sdtFreespinTotalWin}.isNil:
                freespinTotalWin = prevState{$sdtFreespinTotalWin}
            var bwp:Bson = nil
            if not prevState{"wp"}.isNIl:
                bwp = prevState{"wp"}
            if not bwp.isNil and bwp.kind.int != BsonKindNull.int:
                for v in bwp:
                    var wp = new(WildPos)
                    wp.id = v["id"].toInt().ItemKind
                    wp.pos = @[]
                    var index = 0
                    for pos in v["pos"]:
                        if index >= 2:
                            break
                        wp.pos.add(pos)
                        inc index

                    wildPos.add(wp)

            if not prevState[$sdtCheatSpin].isNil and prevState[$sdtCheatSpin].kind != BsonKindNull:
                cheatSpin = @[]
                for v in prevState[$sdtCheatSpin]:
                    cheatSpin.add(v.toInt().int8)

    var oldFreespins = freespinCount
    let bet = jData[$srtBet].getBiggestInt().int64
    let lines = jData[$srtLines].getInt()
    var linesPayout = 0'i64
    let spin = sm.getFullSpinResult(profile, bet, lines, wildPos, freespinCount, freespinTotalWin, linesPayout, cheatSpin)
    resp = sm.createResponse(spin, profile.chips, linesPayout, bet, lines)

    wildPos = spin[0].wildPos

    if freespinCount > 0:
        if oldFreespins > 0:
            dec freespinCount
            if freespinCount == 0:
                wildPos.setLen(0)
                freespinTotalWin = 0

    slotState = newBsonDocument()
    slotState[$sdtFreespinCount] = freespinCount.toBson()
    slotState[$sdtFreespinTotalWin] = freespinTotalWin.toBson()
    slotState[$sdtBet] = bet.toBson()
    slotState[$sdtCheatSpin] = null()
    slotState[$sdtCheatName] = null()

    if wildPos.len > 0:
        var wild_dict = newBsonArray()
        for index, wp in wildPos:
            var doc = newBsonDocument()
            doc["id"] = (wp.id).int.toBson()
            doc["pos"] = newBsonArray()
            for pos in wp.pos:
                doc["pos"].add(pos.toBson())
            wild_dict.add(doc)
        slotState["wp"] = wild_dict
        slotState[$sdtRespinsCount] = 1.toBson()
    else:
        slotState["wp"] = null()
        slotState[$sdtRespinsCount] = 0.toBson()

const ufoDefaultZsm* = staticRead("../resources/slot_002_ufo.zsm")
registerSlotMachine($ufoSlot, newSlotMachineUfo, ufoDefaultZsm)
