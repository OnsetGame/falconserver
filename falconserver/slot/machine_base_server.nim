import json

import nimongo.bson

import machine_base
import falconserver.auth.profile

import slot_data_types

export machine_base

method getResponseAndState*(sm: SlotMachine, profile: Profile, prevState: Bson, jData: JsonNode, resp: var JsonNode, slotState: var Bson) {.base, gcsafe.} = discard

proc calcPayout*(stageResp: JsonNode): int64 =
    let stagePay = stageResp{$srtPayout}
    if not stagePay.isNil:
        result += stagePay.getBiggestInt()

    let lines = stageResp{$srtLines}
    if not lines.isNil:
        for l in lines:
            let linePay = l{$srtPayout}
            if not linePay.isNil:
                result += linePay.getBiggestInt()
