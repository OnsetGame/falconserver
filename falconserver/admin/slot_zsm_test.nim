import json, tables, asyncdispatch, times, strutils, logging, threadpool, locks, asyncfile
import nimongo / bson
import shafa / slot / slot_data_types
import falconserver / common / [ db, bson_helper ]
import falconserver / auth / [ profile_types, profile, profile_random ]
import falconserver / slot / [ machine_base, machine_base_server, machine_balloon_server, machine_classic_server,
                               machine_candy_server, machine_ufo_server, machine_witch_server, machine_mermaid_server, machine_candy2_server,
                               machine_groovy_server, machine_card_server ]

import shafa / bot / [slot_statistic, slot_protocols]
import falconserver / utils / asyncspawn


proc performTest(machine: SlotMachine, name: string, zsm: JsonNode, spins: int): JsonNode {.gcsafe.} =
    let gameSlotID = zsm["slot"].getStr()
    let slotId = machine.getSlotID()

    let profile = newProfile(nil)
    profile.chips = 100_000_000_000
    var state = machine.createInitialState(profile)
    profile{$sdtSlotResult, slotId} = state

    var linesCoords: seq[seq[int]] = @[]
    let jLines = zsm["lines"]
    for jl in jLines:
        var l = newSeq[int]()
        for ji in jl:
            l.add(ji.getInt())
        linesCoords.add(l)

    let lines = jLines.len
    let bet = 1_000 div lines
    var statistic = newStatistic(name, lines * bet, lines, spins, profile.chips.int64, gameSlotID, false, linesCoords)
    statistic.protocol = Protocols.new()
    statistic.protocol.readProtocols()

    var fst = 0

    for i in 0 ..< spins:
        var nextState: Bson
        var resp: JsonNode

        var jData = json.`%*`({$srtBet: bet, $srtLines: lines})
        if gameSlotID == "cardSlot" and fst > 0:
            jData["data"] = %fst

        machine.getResponseAndState(profile, state, jData, resp, nextState)

        if gameSlotID == "cardSlot":
            var winFreespins = false
            if $srtWinFreespins in resp:
                winFreespins = resp[$srtWinFreespins].getBVal()

            if winFreespins:
                fst = profile.random(1..4)

            elif $sdtCardFreespinsType in resp:
                fst = resp[$sdtCardFreespinsType].getInt()

        statistic.parseResponce(resp, i + 1)

        profile{$sdtSlotResult, slotId} = nextState
        profile.chips = resp["chips"].getBiggestInt()
        state = nextState

    result = statistic.collect()


proc startTest(machine: SlotMachine, name: string, zsm: JsonNode, spins: int, initialData: (string, JsonNode)) {.async.} =
    discard await sharedDB()["zsm"].update(
        bson.`%*`({"name": name}),
        bson.`%*`({"$set": {"stat." & initialData[0]: initialData[1].toBson()}}),
        false, true
    )

    info "Start testing: ", name, ", ", initialData[0]

    var res = await asyncSpawn machine.performTest(name, zsm, spins)
    res["endDate"] = %epochTime()
    for k, v in initialData[1]:
        if k notin res:
            res[k] = v

    discard await sharedDB()["zsm"].update(
        bson.`%*`({"name": name}),
        bson.`%*`({"$set": {"stat." & initialData[0]: res.toBson()}}),
        false, false
    )

    info "Complete testing: ", name, ", ", initialData[0]


proc startTest*(name: string, zsm: JsonNode, spins: int): (string, JsonNode) =
    let gameSlotID = zsm["slot"].getStr()

    let initializer = slotMachineInitializers.getOrDefault(gameSlotID)
    if initializer.isNil:
        return

    let machine = initializer(zsm)

    let startDate = epochTime()
    result[0] = (startDate * 1_000_000).int64.toHex(13)
    result[1] = json.`%*`({"startDate": startDate})

    asyncCheck machine.startTest(name, zsm, spins, result)
