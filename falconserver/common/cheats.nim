import json
import falconserver.auth.profile_random
import os
import tables
import oswalkdir
import nimongo.bson
import times
import boolseq
import falconserver / quest / [ quest_manager, quest, quest_task, generator, quests_config ]
import falconserver.slot.slot_data_types
import falconserver.common.game_balance
import falconserver.common.get_balance_config
import falconserver.common.db
import strutils
import falconserver / tutorial / [ tutorial_server, tutorial_types ]
import falconserver / auth / [profile_helpers, profile_vip_helpers]
import falconserver.map.building.builditem
import falconserver.map.map

import asyncdispatch
import falconserver.tournament.tournaments
import falconserver.free_rounds.free_rounds
import falconserver.boosters.boosters
import notifications
import falconserver / fortune_wheel / fortune_wheel
import falconserver / features / features
import shafa / game / reward_types

let areCheatsEnabled = getEnv("FALCON_ENV") == "stage"

proc verifyCheats*(profile: Profile): bool =
    #TODO: check sessionId in whitelist
    result = areCheatsEnabled
    if not result:
        result = profile.isBro

type MachineCheat = tuple[machine: string, fields: string]

proc readCheatConfig(): tuple[config: string, machines: seq[MachineCheat]] {.compileTime.} =
    const cheatDir = "../cheats"
    let cheatConfigstr = staticRead(cheatDir/"cheats_config.json")
    result.config = cheatConfigstr
    result.machines = @[]
    # initTable[string, string]()
    for r in oswalkdir.walkDirRec("cheats"):
        let sf = r.splitFile()
        let machine = parentDir(r).substr("cheats".len + 1)
        if sf.ext == ".json" and sf.name == "cheats":

            var machineCheat: MachineCheat
            machineCheat.machine = machine
            machineCheat.fields = staticRead( "../" & r)
            result.machines.add(machineCheat)

            # result.machines[machine] = staticRead( "../" & r)

const staticCheatsConfig* = readCheatConfig()

var initialized = false
var cheatsConfig: tuple[config: JsonNode, machines: Table[string, JsonNode]]

proc initCheatsConfig()=
    if not initialized:

        cheatsConfig.config = parseJson(staticCheatsConfig.config)
        cheatsConfig.machines = initTable[string, JsonNode]()

        for cm in staticCheatsConfig.machines:
            cheatsConfig.machines[cm.machine] = parseJson(cm.fields)

        if areCheatsEnabled:
            try:
                var deleteProfileCheat = json.`%*`({
                        "name":"deleteProfile",
                        "request":"/cheats/deleteProfile",
                        "value":0
                    })

                cheatsConfig.config["common"]["balance"].add(deleteProfileCheat)
            except:
                discard

        initialized = true

proc getCheatsConfig*(): JsonNode=
    initCheatsConfig()
    result = cheatsConfig.config
    var slotConf: JsonNode = nil

    for key, val in cheatsConfig.machines:
        var mach_jConf = newJArray()
        for mkey, mval in val:
            var cheat = newJObject()
            cheat.add("name", %"spin")
            cheat.add("request", %"/cheats/slot")
            cheat.add("value", %mkey)
            mach_jConf.add(cheat)

        if not mach_jConf.isNil():
            if slotConf.isNil():
                slotConf = newJObject()
            slotConf.add(key, mach_jConf)

    if not slotConf.isNil():
        result.add("slot", slotConf)

proc getCheatForMachine*(p: Profile, cheat, machine: string): JsonNode=
    initCheatsConfig()
    let machineConf = cheatsConfig.machines.getOrDefault(machine)
    if not machineConf.isNil:
        let cheatsArr = machineConf.getOrDefault(cheat)
        if not cheatsArr.isNil:
            let size = cheatsArr.len
            let index = p.random(size)
            return cheatsArr[index]

    result = nil

type CheatCommand = proc(profile: Profile, req: JsonNode): Future[JsonNode]
var cheatsCommands = initTable[string, CheatCommand]()

proc proceedCheatsCommand*(command: string, profile: Profile, jData: JsonNode): Future[JsonNode] {.async.} =
    let cheatCmd = cheatsCommands.getOrDefault(command)
    if not cheatCmd.isNil:
        result = await profile.cheatCmd(jData)

template registerCheat(cheatName:string, body: untyped) =
    cheatsCommands[cheatName] = proc(profile: Profile, req: JsonNode): Future[JsonNode] {.async.} =
        var req{.inject.} = req
        var profile{.inject.} = profile
        body

registerCheat("send_notification"):
    let r = await profile.sendAppToUserNotification("TEST NOTIFICATION", nidUnknown, nil)
    result = newJObject()
    result["sent"] = %r

registerCheat("update"):
    result = getCheatsConfig()

registerCheat("quests_complete"):
    let qid = req["questIndex"].getInt()
    var questManager = newQuestManager(profile)

    if qid >= 0:
        questManager.cheatCompleteTasks(qid)

    questManager.saveChangesToProfile()
    result = newJObject()
    result["quests"] = questManager.updatesForClient()

registerCheat("exp"):
    result = newJObject()
    var exp: int
    if req["value"].getStr() == "level_up":
        let lvl = profile.level
        exp = profile.getGameBalance().levelProgress[lvl - 1].experience - profile.experience + 1
    else:
        exp = parseInt(req["value"].getStr())

    let qman = newQuestManager(profile)
    qman.onProfileChanged(profile)

    let expRew = createReward(RewardKind.exp, exp)
    await profile.acceptRewards(@[expRew], result)
    qman.onProfileChanged(profile)
    qman.saveChangesToProfile()
    result["lvlData"] = profile.getLevelData()

registerCheat("level"):
    result = newJObject()
    var lvl = try: parseInt(req["value"].getStr()) except: profile.level
    let gb = profile.getGameBalance()

    profile.level = clamp(lvl, 1, gb.levelProgress.len)

    let qman = newQuestManager(profile)
    qman.onProfileChanged(profile)
    qman.saveChangesToProfile()
    result["lvlData"] = profile.getLevelData()

registerCheat("parts"):
    let cheatValue = parseInt($(req["value"]).getStr()).int64
    if cheatValue == 0:
        profile.parts = 0
    else:
        profile.parts = profile.parts + cheatValue

    result = newJObject()
    result["parts"] = %profile.parts

registerCheat("tourpoints"):
    let cheatValue = parseInt($(req["value"]).getStr()).int64
    if cheatValue == 0:
        profile.tourPoints = 0
    else:
        profile.tourPoints = profile.tourPoints + cheatValue

    result = newJObject()
    result["tourpoints"] = %profile.tourPoints

registerCheat("chips"):
    let chipsCheat = parseInt($(req["value"]).getStr()).int64
    if chipsCheat == 0:
        profile.chips = 0
    else:
        profile.chips = profile.chips + chipsCheat

    result = newJObject()
    result["chips"] = %profile.chips

registerCheat("bucks"):
    let bucksCheat =  parseInt($(req["value"]).getStr()).int64
    if bucksCheat == 0:
        profile.bucks = 0.toBson()
    else:
        profile.bucks = profile.bucks + bucksCheat

    result = newJObject()
    result["bucks"] = %profile.bucks

registerCheat("reset_cron"):
    result = newJObject()
    let ct = epochTime()
    profile.nextExchangeDiscountTime = 0.0

registerCheat("setExchangeDiscountIn"):
    result = newJObject()
    let nextDiscountInSeconds = parseInt($(req["value"])).float
    profile.nextExchangeDiscountTime = nextDiscountInSeconds + epochTime()
    result["cronTime"] = %profile.nextExchangeDiscountTime

proc resetProgress*(profile: Profile): Future[void] {.async.} =
    await profile.leaveAllTournaments()
    await profile.removeAllNotifications()

    var freshProfile = newProfile(profilesDB())
    for k in [$prfId, $prfDevices, $prfFBToken, $prfIsBro]:
        if not profile{k}.isNil:
            freshProfile{k} = profile{k}

    # we bulk update DB from freshProfile, and we willn't make profile.commit() latere
    #asyncCheck freshProfile.commit()
    discard await profilesDB().update(bson.`%*`({"_id": profile.id}), freshProfile.bson, multi = false, upsert = false)
    discard await freeRoundsDB().remove(bson.`%*`({"_id": profile.id}))


registerCheat("reset_progress"):
    result = newJObject()
    asyncCheck profile.resetProgress()

registerCheat("generate_task_for_slot"):
    let taskType = parseQuestTaskType(req["qtt"].getStr(), 100_500)
    let target = parseEnum[BuildingId](req["target"].getStr())
    var qman = newQuestManager(profile)

    var replQid = profile.questsGenId
    for q in qman.quests:
        if q.id >= QUEST_GEN_START_ID and q.tasks[0].target == target:
            replQid = q.id
            break

    qman.cheatDeleteQuestById(replQid)
    let genQuest = profile.generateTaskForCheat(target, taskType, replQid)
    if genQuest.isNil:
        echo "genQuest isNil "
        return

    if replQid == profile.questsGenId:
        profile.questsGenId = profile.questsGenId + 1
        qman.replaceSlotQuest(target, replQid)

    qman.quests.add(genQuest)

    qman.saveChangesToProfile()

    result = newJObject()
    result["quests"] = qman.updatesForClient()

registerCheat("reset_tutorial"):
    result = newJObject()

    profile.tutorialState = binuser("")
    result["tutorial"] = profile.tutorialStateForClient()

registerCheat("skip_tutorial"):
    result = newJObject()

    var tutState = newBoolSeq("")
    for ts in low(TutorialState) .. high(TutorialState):
        if ts != TutorialState.tsInvalidStep:
            var idx = ts.int
            if idx >= tutState.len:
                tutState.setLen(idx + 1)
            tutState[idx] = true

    profile.tutorialState = binuser(tutState.string)
    result["tutorial"] = profile.tutorialStateForClient()

registerCheat("gameOver"):
    result = newJObject()

    var questState = newBoolSeq("")
    for qc in profile.getStoryConfig():
        if qc.enabled:
            if qc.quest.id >= questState.len:
                questState.setLen(qc.quest.id)
            questState[qc.quest.id - 1] = true
            profile.updateMapStateOnQuestComplete(qc)

    var tutState = newBoolSeq("")
    for ts in low(TutorialState) .. high(TutorialState):
        if ts != TutorialState.tsInvalidStep:
            var idx = ts.int
            if idx >= tutState.len:
                tutState.setLen(idx + 1)
            tutState[idx] = true

    profile.tutorialState = binuser(tutState.string)

    var quests = newBsonArray()
    for q in profile[$prfQuests]:
        if q[$qfId].toInt() >= 100_000:
            quests.add(q)

    let gb = profile.getGameBalance()

    profile.chips = 42_042_042_042
    profile.bucks = 42_000_000
    profile.parts = 42
    profile[$prfQuests] = quests
    profile.level = gb.levelProgress.len().toBson()
    profile.statistics.questsCompleted = binuser(questState.string)

    result["bucks"]       = newJInt(profile.bucks)
    result["chips"]       = newJInt(profile.chips)
    result["parts"]       = newJInt(profile.parts)
    result["tourPoints"]  = newJInt(profile.tourPoints)
    result["pvpPoints"]   = newJInt(profile.pvpPoints)
    result["xp"]          = newJInt(profile.experience)
    result["txp"]         = %gb.levelProgress[profile.level - 1].experience
    result["lvl"]         = newJInt(profile.level)
    result["state"]       = profile.getClientState()
    result["tutorial"]    = profile.tutorialStateForClient()


registerCheat("reachQuest"):
    result = newJObject()

    var lvl = 1
    var questState = newBoolSeq("")

    for qc in profile.getStoryConfig():
        if qc.name == req["quest"].getStr():
            var i = 0
            var dependencies = newSeq[QuestConfig]()

            dependencies.add(qc.deps)
            lvl = max(lvl, qc.lockedByLevel)

            while i < dependencies.len:
                let qc = dependencies[i]

                if qc.quest.id >= questState.len:
                    questState.setLen(qc.quest.id)

                if not questState[qc.quest.id - 1]:
                    questState[qc.quest.id - 1] = true
                    profile.updateMapStateOnQuestComplete(qc)

                    dependencies.add(qc.deps)
                    lvl = max(lvl, qc.lockedByLevel)
                i.inc
            break

    var quests = newBsonArray()
    for q in profile[$prfQuests]:
        if q[$qfId].toInt() >= 100_000:
            quests.add(q)

    profile.chips = 42_042_042_042
    profile.bucks = 42_000_000
    profile.parts = 42_000_000
    profile[$prfQuests] = quests
    profile.level = lvl.toBson()
    profile.statistics.questsCompleted = binuser(questState.string)

    let gb = profile.getGameBalance()

    profile.experience = if profile.level > 1: gb.levelProgress[profile.level - 2].experience else: 0

    result["bucks"]       = newJInt(profile.bucks)
    result["chips"]       = newJInt(profile.chips)
    result["parts"]       = newJInt(profile.parts)
    result["tourPoints"]  = newJInt(profile.tourPoints)
    result["pvpPoints"]   = newJInt(profile.pvpPoints)
    result["xp"]          = newJInt(profile.experience)
    result["txp"]         = %gb.levelProgress[profile.level - 1].experience
    result["lvl"]         = newJInt(profile.level)
    result["state"]       = profile.getClientState()
    result["tutorial"]    = profile.tutorialStateForClient()
    result["lvlData"]     = profile.getLevelData()

proc addBooster(profile: Profile, tag: string, req: JsonNode): Future[JsonNode] {.async.} =
    result = newJObject()
    let value = parseInt($(req["value"]).getStr()).float
    await profile.boosters.add(tag, value, true)
    result["boosters"] = profile.boosters.stateResp()

registerCheat("addbooster_inc"):
    result = await profile.addBooster($btIncome, req)

registerCheat("addbooster_exp"):
    result = await profile.addBooster($btExperience, req)

registerCheat("addbooster_tp"):
    result = await profile.addBooster($btTournamentPoints, req)

registerCheat("removeboosters"):
    result = newJObject()
    profile.boostersData = newBsonDocument()
    result["boosters"] = profile.boosters.stateResp()

registerCheat("vip"):
    result = newJObject()
    let vipConfig = profile.getGameBalance().vipConfig
    let points = req{"points"}.getBiggestInt(-1)
    if profile.vipPoints >= points:
        profile.vipPoints = points
        profile.vipLevel = profile.vipLevelForPoints(points)
        result["vip"] = %{"points": %profile.vipPoints, "level": %profile.vipLevel}
        return
    await profile.gainVipPoints(points - profile.vipPoints, result)
    var qman = newQuestManager(profile)
    result["quests"] = qman.questsForClient()

registerCheat("nfs"):
    let nextFreeSpinInSeconds = req{"value"}.getInt(0)

    profile.setNextFreeSpinTime(nextFreeSpinInSeconds)

    result = newJObject()
    result["nfs"] = %nextFreeSpinInSeconds
    await result.updateWithWheelFreeSpin(profile)

registerCheat("setWheelFreespins"):
    let amountToSet = req{"value"}.getInt(0)

    let x = amountToSet - profile.fortuneWheelState.freeSpinsLeft

    profile.addWheelFreeSpins(x)

    result = newJObject()
    await result.updateWithWheelFreeSpin(profile)


registerCheat("addFreeRounds"):
    let rounds = req{"rounds"}.getInt(0)
    let gameSlotID = req{"slotId"}.getStr()

    let machine = await profile.getSlotMachineByGameID(gameSlotID)
    if machine.isNil:
        echo "Incorrect slotId " & gameSlotID & "!"
        return

    let freeRounds = await profile.id.getOrCreateFreeRounds()
    freeRounds.addFreeRounds(gameSlotID, rounds)
    await freeRounds.save()

    result = newJObject()
    result.updateWithFreeRounds(freeRounds)
