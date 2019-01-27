import json, logging, oids, sequtils, strutils, tables, times, osproc, cgi, asyncdispatch
import os except DeviceId
import httpcore except HttpMethod

import falconserver / [nester]

import falconserver / auth / [ profile, profile_random, profile_types, session, profile_helpers ]
import falconserver / quest / [ quest_manager, quest_types ]
import falconserver / map / [ map, building/builditem ]
import falconserver / slot / [ slot_data_types, machine_base_server, machine_balloon_server, machine_classic_server,
                            machine_candy_server, machine_ufo_server, machine_witch_server, machine_mermaid_server,
                            machine_groovy_server, slot_context ]

import falconserver / common / [ bson_helper, config, game_balance, get_balance_config, response, stats, response_wrapper ]

import falconserver / tournament / [ tournaments ]
import falconserver / free_rounds / [ free_rounds ]

import shafa / game / reward_types

import falconserver.boosters.boosters

import near_misses_pick

let areCheatsEnabled = getEnv("FALCON_ENV") == "stage"


proc linesToJson*(prf: Profile, gameID: string): Future[JsonNode] {.async.} =
    let machine = await prf.getSlotMachineByGameID(gameID)
    result = newJArray()
    for line in machine.lines:
        var jLine = newJArray()
        for elem in line:
            jLine.add(%elem)
        result.add(jLine)


let router = sharedRouter()


router.routes:
    sessionPost "/slot/getMode/{gameSlotID}":
        let gameSlotID = @"gameSlotID"
        var chips = profile.chips
        var resp = newJObject()

        let (err, sc) = await getSlotContext(profile, gameSlotID, requestBody)
        if not err.isNil:
            if "status" in err:
                err["reason"] = err["status"]
            err["result"] = %false
            err["status"] = %StatusCode.Ok.int
            respJson Http200, err
            return

        if not sc.state.isNil:
            if gameSlotID == $balloonSlot:
                let prevState = sc.state
                let machine = await profile.getSlotMachineByGameID($balloonSlot)
                let slotMachineBalloon = machine.SlotMachineBalloon

                # reset destruction after exit from slot
                slotMachineBalloon.destructions = 0

                var stages = newJArray()
                var stageResult = newJObject()
                var lastField: seq[int8]

                if "lf" in prevState:
                    prevState["lf"].toSeqInt8(lastField)
                    var jSymbols = newJArray()
                    for i in lastField: jSymbols.add(%i)
                    stageResult["field"] = %(jSymbols)
                if "fs" in prevState:
                    let freespinCount = prevState["fs"].toInt()
                    resp.add("freeSpinsCount", %freespinCount)
                    var stage: string
                    if lastField.len != 0 and slotMachineBalloon.canStartBonusGame(lastField):
                        stage = "Bonus"
                    elif freespinCount == 0:
                        stage = "Spin"
                    else:
                        stage = "FreeSpin"
                    stageResult["stage"] = %stage
                if "bt" in prevState:
                    resp.add($sdtBet, %prevState["bt"].toInt())
                if $sdtFreespinTotalWin in prevState:
                    stageResult[$sdtFreespinTotalWin] = %prevState[$sdtFreespinTotalWin].toInt()

                stages.add(stageResult)
                resp.add("stages", stages)
            else:
                for key, value in sc.state.toJson():
                    resp.add(key, value)

        let jsonLines = await profile.linesToJson(gameSlotId)
        resp.add($srtBigwinMultipliers, %sc.machine.getBigwinMultipliers())
        resp.add($srtLines, jsonLines)
        resp.add($srtPaytable, sc.machine.paytableToJson())
        resp.add("chips", %chips)
        resp.add("lvlData", profile.getLevelData())

        var betConf = sc.getBets()
        resp["betsConf"] = betConf.toJson()

        sc.updateResponse(resp)

        await wrapRespJson(clRequest.session.profile, resp, clRequest.clientVersion)
        respJson Http200, resp

    sessionPost "/slot/spin/{gameSlotID}":
        ## Spinning requires authentication
        let gameSlotID = @"gameSlotID"
        # echo "[SPIN] ORDINARY"
        ## Returns spin result for specified slot machine
        let cheats = profile{"cheats", gameSlotID}
        if not cheats.isNil:
            respJson Http200, parseJson(cheats)
        else:
            let (err, sc) = await getSlotContext(profile, gameSlotID, requestBody)
            if not err.isNil:
                if "status" in err:
                    err["reason"] = err["status"]
                err["result"] = %false
                err["status"] = %StatusCode.Ok.int
                respJson Http200, err
                return

            if sc.machine.isNil:
                respJson Http200, json.`%*`({"status": "Bad gameSlotID"})
            else:
                var nextPredefinedSpinIndex = 0
                let questManager = newQuestManager(profile)

                if not sc.state{$sdtPredefinedSpins}.isNil:
                    if $sdtCheatSpin in sc.state and sc.state[$sdtCheatSpin].kind != BsonKindNull:  # cheats have higher priority to predefined spins
                        nextPredefinedSpinIndex = sc.state[$sdtPredefinedSpins].toInt()  # try to do predefined next time
                    else:
                        let predefinedSpinIndex = sc.state[$sdtPredefinedSpins].toInt()
                        let nextSpin = sc.getPredefinedSpin(profile, predefinedSpinIndex)
                        if not nextSpin.isNil:
                            #echo "nextSpin[", predefinedSpinIndex, "] = ", nextSpin
                            sc.state[$sdtCheatSpin] = nextSpin
                            nextPredefinedSpinIndex = predefinedSpinIndex + 1

                var nextState: Bson
                var resp: JsonNode

                sc.machine.getResponseAndState(profile, sc.state, requestBody, resp, nextState)

                var payout = 0'i64
                for st in resp["stages"]:
                    payout += st.calcPayout()

                let isCheatSpin = $sdtCheatSpin in sc.state and sc.state[$sdtCheatSpin].kind != BsonKindNull
                #echo "NearMiss  nextPredefinedSpinIndex = ", nextPredefinedSpinIndex, ",  isCheatSpin = ", isCheatSpin, ",  payout = ", payout, ",  resp[\"stages\"].len = ", resp["stages"].len
                if not isCheatSpin and payout == 0 and resp["stages"].len > 0:
                    var bonusGameStarted = false
                    for st in resp["stages"]:
                        if st["stage"].getStr() == "Bonus":
                            bonusGameStarted = true
                            break

                    let nextFreespins = if $sdtFreespinCount in nextState: nextState[$sdtFreespinCount].toInt64()  else: 0
                    let prevFreespins = if $sdtFreespinCount in sc.state: sc.state[$sdtFreespinCount].toInt64()  else: 0
                    var freespinsAdded = nextFreespins > prevFreespins

                    #echo "NearMiss  bonusGameStarted = ", bonusGameStarted,  ",  freespinsAdded = ", freespinsAdded
                    if not bonusGameStarted and not freespinsAdded:
                        let field = resp["stages"][0]["field"].to(seq[int8])

                        let q = questManager.getActiveSlotQuest(parseEnum[BuildingId](gameSlotID))
                        var itemKindToFind: ItemKind
                        var itemCountToFind = -1
                        if not q.isNil:
                            case q.tasks[0].kind:
                                of qttCollectScatters:
                                    itemKindToFind = IScatter
                                    itemCountToFind = sc.machine.countSymbolsOfType(field, itemKindToFind)
                                of qttCollectBonus:
                                    itemKindToFind = IBonus
                                    itemCountToFind = sc.machine.countSymbolsOfType(field, itemKindToFind)
                                of qttCollectWild:
                                    itemKindToFind = IWild
                                    itemCountToFind = sc.machine.countSymbolsOfType(field, itemKindToFind)
                                else:
                                    logNearMisses "NearMiss  another task"
                            #echo "NearMiss  task ", q.tasks[0].kind, ", need to find ", itemCountToFind, " ", itemKindToFind, " item(s)"
                        else:
                            #echo "NearMiss  no task"
                            discard

                        let substitutedSpin = profile.nearMissConfig().pick(profile, gameSlotID, itemKindToFind, itemCountToFind)
                        if substitutedSpin.len != 0:
                            sc.state[$sdtCheatSpin] = substitutedSpin.toBson()
                            var substNextState: Bson
                            var substResp: JsonNode
                            sc.machine.getResponseAndState(profile, sc.state, requestBody, substResp, substNextState)
                            var substPayout = 0'i64
                            for st in resp["stages"]:
                                substPayout += st.calcPayout()
                            if substPayout > 0:  # error in patter occured
                                echo "WARNING: NearMiss  new payout = ", payout, ", ignoring spin"
                            else:
                                nextState = substNextState
                                resp = substResp
                                payout = substPayout
                                if areCheatsEnabled or profile.isBro:
                                    resp["nearMiss"] = json.`%*`({
                                        "scatters": sc.machine.countSymbolsOfType(field, IScatter),
                                        "bonuses": sc.machine.countSymbolsOfType(field, IBonus),
                                        "wilds": sc.machine.countSymbolsOfType(field, IWild),
                                        "prevField": field})

                if nextPredefinedSpinIndex > 0:
                    nextState[$sdtPredefinedSpins] = nextPredefinedSpinIndex.toBson()

                var isSpin = not resp{"stages"}.isNil and not resp["stages"][0]{"stage"}.isNil and resp["stages"][0]["stage"].getStr() == "Spin"
                if isSpin:
                    let totalBet = requestBody[$srtBet].getBiggestInt() * requestBody[$srtLines].getBiggestInt()
                    await reportSlotSpin(gameSlotID, totalBet.int64, payout)
                else:
                    await reportSlotPayout(gameSlotID, payout)

                # TODO: refactoring
                if sc of FreeRoundsSlotContext:
                    profile.chips = profile.chips + payout
                    if sc.numberOfFreespins() == 0 and sc.numberOfRespins() == 0:
                        var inc = true

                        # balloon slot
                        if "md" in nextState:
                            inc = nextState["md"].toInt() == 0

                        if inc:
                            sc.FreeRoundsSlotContext.freeRounds.incFreeRoundSpins(gameSlotID)
                    sc.FreeRoundsSlotContext.freeRounds.incFreeRoundReward(gameSlotID, payout)
                else:
                    profile.chips = resp["chips"].getBiggestInt()

                    let gb = profile.getGameBalance()
                    var betIndex = 0
                    let curBet = requestBody[$sdtBet].getBiggestInt().int64 * requestBody[$srtLines].getInt()
                    for i, v in gb.bets:
                        if curBet == v:
                            betIndex = i

                    var qData = newJObject()
                    qData["req"] = requestBody
                    qData["res"] = resp
                    qData["slot"] = %gameSlotID
                    qData["betLevel"] = %betIndex
                    qData["plvl"] = %profile.level
                    if isSpin:
                        var exp = gb.expFromBet(curBet)
                        var expRew = createReward(RewardKind.exp, exp)
                        await profile.acceptRewards(@[expRew], resp)
                    questManager.onSlotSpin(qData)
                    questManager.saveChangesToProfile()

                    var betConf = sc.getBets(fromSpin = true)
                    resp["betsConf"] = betConf.toJson()

                    if sc of TournamentSlotContext:
                        let tournament = sc.TournamentSlotContext.tournament

                        var spinSequenceEnd = true
                        if gameSlotID == "balloonSlot" and $srtLines in resp["stages"][0]:
                            spinSequenceEnd = resp["stages"][0][$srtLines].len == 0
                        await applyTournamentSpin(profile["_id"], tournament, requestBody, resp, spinSequenceEnd)

                        resp["tournScore"] = %tournament.participation.score
                        resp["tournScoreTime"] = %tournament.participation.scoreTime.toSeconds

                profile.incSpinOnSlot(gameSlotID)
                await sc.saveStateAndProfile(nextState)
                sc.updateResponse(resp)

                resp["chips"] = %profile.chips
                resp["quests"] = questManager.updatesForClient()
                resp["lvlData"] = getLevelData(profile)
                resp["exchangeNum"] = profile[$prfExchangeNum].toJson()
                resp["cronTime"] = %profile.nextExchangeDiscountTime

                await wrapRespJson(clRequest.session.profile, resp, clRequest.clientVersion)
                respJson Http200, resp
