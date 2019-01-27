
import unittest

import tests
import json
import strutils
import tables
import boolseq
import nimongo.bson
import falconserver / slot / [ machine_base_server, machine_classic_server, machine_balloon_server, machine_candy_server]
import falconserver / quest / [ quest_task, tasks_script, quest_types, quests_config, generator, quest, quest_manager, quests_config ]
import falconserver.map.building.builditem
import falconserver / auth / [ profile_types, profile ]
import falconserver / common / [ game_balance, response, notifications ]
import shafa.slot.slot_data_types
import shafa.game.reward_types

const
    minimumBet = 5000
    playerLevel = 10
    activeSlots = 6

let maxBet = sharedGameBalance().betLevels(playerLevel)[^1]

var questCounter = 100000

let machineEiffel  = newSlotMachineClassic(slotMachineDesc("falconserver/resources/slot_001_dreamtower.zsm"))
let machineBalloon = newSlotMachineBalloon(slotMachineDesc("falconserver/resources/slot_003_balloons.zsm"))
let machineCandy   = newSlotMachineCandy(slotMachineDesc("falconserver/resources/slot_004_candy.zsm"))

var machineState = initTable[BuildingId, Bson]()
var machines = initTable[BuildingId, SlotMachine]()

var regularFields = initTable[BuildingId, seq[int8]]()
regularFields[dreamTowerSlot] = @[1.int8, 2, 3, 3, 3, 3, 6, 6, 6, 3, 7, 5, 7, 7, 7]
regularFields[candySlot]      = @[5.int8, 4, 3, 3, 3, 3, 6, 2, 6, 3, 7, 5, 7, 7, 1]
regularFields[balloonSlot]    = @[1.int8, 2, 3, 3, 3, 3, 6, 6, 6, 3, 7, 5, 7, 7, 7]

var bigWinFields = initTable[BuildingId, seq[int8]]()
bigWinFields[dreamTowerSlot]  = @[7.int8, 9, 8, 0, 0, 6, 10, 0, 11, 10, 0, 0, 4, 4, 9]
bigWinFields[candySlot]       = @[0.int8, 0, 0, 0, 0, 0,  0, 0,  0,  0, 0, 0, 0, 0, 0]
bigWinFields[balloonSlot]     = @[5.int8, 5, 5, 5, 5, 5,  5, 0,  0,  5, 5, 5, 5, 5, 5]

var bonusFields = initTable[BuildingId, seq[int8]]()
bonusFields[dreamTowerSlot] = @[1.int8, 2, 2, 2, 3, 3, 6, 6, 6, 3, 7, 5, 7, 7, 7]
bonusFields[candySlot]      = @[5.int8, 4, 3, 2, 3, 3, 6, 2, 6, 3, 7, 2, 7, 7, 4]
bonusFields[balloonSlot]    = @[1.int8, 1, 3, 3, 2, 3, 1, 6, 6, 3, 7, 5, 7, 7, 7]

var freeSpinFields = initTable[BuildingId, seq[int8]]()
freeSpinFields[dreamTowerSlot] = @[1.int8, 1, 1, 2, 3, 3, 6, 6, 6, 3, 7, 5, 7, 7, 7]
freeSpinFields[candySlot]      = @[5.int8, 4, 3, 2, 3, 3, 6, 2, 6, 3, 7, 2, 7, 7, 1]
freeSpinFields[balloonSlot]    = @[5.int8, 5, 5, 5, 5, 5, 5, 0, 0, 5, 5, 5, 5, 5, 5]

var looseFields = initTable[BuildingId, seq[int8]]()
looseFields[dreamTowerSlot] = @[6.int8, 5, 4, 3, 2, 6, 5, 4, 3, 1, 7, 6, 5, 4, 3]
looseFields[candySlot]      = @[7.int8, 6, 5, 4, 3, 7, 6, 5, 4, 3, 7, 6, 7, 7, 7]
looseFields[balloonSlot]    = @[7.int8, 6, 5, 4, 3, 7, 6, 5, 4, 3, 7, 6, 5, 4, 3]

proc createSlotQuest(qtt: QuestTaskType, targetProg: int, target: BuildingId): Quest=
    let task = createTask(qtt, @[targetProg], target)
    result = createQuest(questCounter, @[task])
    result.kind = QuestKind.Daily
    inc questCounter

proc createProfile(): Profile =
    result = newProfile(nil)
    result.level = playerLevel

proc getBetLevel(totalBet: int64): int=
    let gb = sharedGameBalance()
    result = -1
    for i, v in gb.bets:
        if totalBet == v:
            result = i
            break

proc prepareJsonDataForTask(target: BuildingId, totalBet: int64, resp: JsonNode): JsonNode=
    result = newJObject()
    result["req"] = newJObject() # currently don't used
    result["res"] = resp
    result["slot"] = %($target)
    result["plvl"] = %playerLevel
    result["betLevel"] = %getBetLevel(totalBet)

proc prepareJsonReq(totalBet: int64, lines: int): JsonNode=
    result = newJObject()
    result["bet"] = %(totalBet div lines)
    result["lines"] = %lines

proc getFieldFromResp(resp: JsonNode): seq[int8]=
    result = @[]
    let stage = resp["stages"][0]
    if "field" in stage:
        for v in stage["field"]:
            result.add(v.getNum().int8)

proc validateFields(one, two: seq[int8]): bool=
    result = one.len == two.len
    if result:
        for i, o in one:
            result = o == two[i]
            if not result:
                echo "validateFields: one ", one, " two ", two
                return
    else:
        echo "validateFields: one ", one.len , " two ", two.len

proc resetMachineState(bi: BuildingId)=
    machineState[bi] = newBsonDocument()
    machines[bi].freespinCount = 0
    case bi:
    of balloonSlot:
        machineState[bi]["lf"] = regularFields[bi].toBson()
        let balloonSlotMachine = machines[bi].SlotMachineBalloon
        balloonSlotMachine.lastField = nil
        balloonSlotMachine.prevSpin = nil
        balloonSlotMachine.lastWin = nil
        balloonSlotMachine.freegame = false
        balloonSlotMachine.bonusgame = false
        balloonSlotMachine.destructions = 0
    else:
        discard

proc spinOn(bi: BuildingId, profile: Profile, jData:JsonNode, resp: var JsonNode, cheatField: seq[int8], cheatName = "custom") =
    var prevState = machineState.getOrDefault(bi)
    if prevState.isNil:
        prevState = newBsonDocument()

    var nextSpin = newBsonArray()
    if cheatField.isNil:
        prevState[$sdtCheatSpin] = null()
        prevState[$sdtCheatName] = null()
    else:
        for v in cheatField:
            nextSpin.add(v.toBson())
        prevState[$sdtCheatSpin] = nextSpin
        prevState[$sdtCheatName] = cheatName.toBson()

    var slotState: Bson
    machines[bi].getResponseAndState(profile, prevState, jData, resp, slotState)
    machineState[bi] = slotState

proc getRespStages(resp: JsonNode): seq[Stage]=
    result = @[]
    for stage in resp["stages"]:
        result.add(parseEnum[Stage](stage["stage"].getStr()))

proc totalLinesWin(jStage: JsonNode):int64=
    let jLines = jStage["lines"]
    if not jLines.isNil:
        for li in jLines:
            result += li["payout"].getNum().int64

proc getSpinPayout(resp: JsonNode): int64=
    result = 0
    for stage in resp["stages"]:
        if stage["stage"].getStr() != "Bonus":
            result += totalLinesWin(stage)

proc getBonusPayout(resp: JsonNode): int64=
    result = 0
    for stage in resp["stages"]:
        if stage["stage"].getStr() == "Bonus":
            result += stage["payout"].getBiggestInt()

doTests:
    var profile = createProfile()
    var qman = newQuestManager(profile, autogenerateSlotQuests = false)

    disableNotifications = true

    machines[dreamTowerSlot] = machineEiffel
    machines[balloonSlot] = machineBalloon
    machines[candySlot] = machineCandy

    test("GameBalance parsing"):
        checkCond(not sharedGameBalance().isNil, "GameBalance brocken")

    test("Daily config parsing"):
        checkCond(not sharedDailyGeneratorConfig().isNil, "DailyConfig brocken")

    test("Stages generator"):
        for level in 1 .. 60:
            profile.level = level

            for i in 0 ..< 1000:
                for slot in [dreamTowerSlot, balloonSlot, candySlot]:
                    var (stageLevel, q) = profile.generateSlotQuest(slot)
                    #checkCond(quests.len > 0, "Stage didnt generated")
                    checkCond(not q.isNil, "Stage didnt generated")
                    #checkCond(quests.len == activeSlots, "Stage " & $stageLevel & " don't cover all slots")
                    #for q in quests:
                    let dbgMsg = " stage: " & $(i + 1) &  " level: " & $level & " t: " & $q.tasks[0].kind & "_" & $q.tasks[0].target
                    checkCond(not q.isNil, "Generated daily is nil " & dbgMsg)
                    checkCond(q.tasks[0].progresses.len > 0, "Daily hasnt progresses " & dbgMsg )
                    checkCond(q.tasks[0].progresses[0].total != 0'u64, "Daily has zero total progress " & dbgMsg)

        profile.level = playerLevel

    test("Storyline tests"):
        profile.parts = 1_000_000
        profile.bucks = 1_000_000
        profile.tourPoints = 1_000_000
        let prevLevel = profile.level
        profile.level = 60
        profile.vipLevel = 100

        var quests = qman.initialQuests()
        #qman.quests.setLen(0)   # delete default slot tasks
        qman.quests.add(quests)

        checkCond(quests.len > 0, "StoryLine hasn't root quests")

        var partsSpend = 0
        var bucksSpend = 0
        var questDone = 0

        proc getAllDepsForQc(qc: QuestConfig, outRes: var seq[QuestConfig])=
            for dep in qc.deps:
                outRes.add(dep)
                getAllDepsForQc(dep, outRes)

        while qman.quests.len > 0:
            for q in qman.quests:
                var qmanQuest = qman.questById(q.id)
                checkCond(not qmanQuest.isNil, "Quest manager dont have " & $q.id)
                let config = qman.config(q)
                var jData = json.`%*`({"questIndex": q.id})

                block acceptQuestTests:
                    var (resp, statusCode) = waitFor qman.proceedCommand("accept", jData)
                    var questProg = qmanQuest.data[$qfStatus].toInt().QuestProgress
                    checkCond(not config.isNil, "Quest " & $q.id & " config is nil")
                    checkCond(statusCode == StatusCode.OK, "Invalid command for " & config.name & " Status: " & $statusCode)
                    checkCond(questProg >= QuestProgress.InProgress, "Quest " & config.name & " not started " & $questProg)
                    checkCond(config.price >= 0, "Quest " & config.name & " price is invalid " & $config.price)
                    partsSpend += config.price

                if config.time > 0.0:
                    block speedUpTests:
                        bucksSpend += qman.speedUpPrice(q)
                        var (resp, statusCode) = waitFor qman.proceedCommand("speedUp", jData)
                        var questProg = qmanQuest.data[$qfStatus].toInt().QuestProgress

                        checkCond(statusCode == StatusCode.OK, "Invalid command for " & config.name & " Status: " & $statusCode)
                        checkCond(questProg >= QuestProgress.GoalAchieved, "Quest " & config.name & " not speeduped " & $questProg)


                block completeTests:
                    var (resp, statusCode) = waitFor qman.proceedCommand("complete", jData)
                    var questProg = qmanQuest.data[$qfStatus].toInt().QuestProgress

                    checkCond(statusCode == StatusCode.OK, "Invalid command for " & config.name & " Status: " & $statusCode)
                    checkCond(questProg == QuestProgress.Completed, "Quest " & config.name & " not speeduped " & $questProg)

                block getRewardsTests:
                    var prevLvl = profile.level
                    var prevExp = profile.experience
                    var (resp, statusCode) = waitFor qman.proceedCommand("getReward", jData)

                    # now quest may have no exp reward
                    # checkCond(prevLvl != profile.level or prevExp != profile.experience, "Quest rewards not gained for " & config.name)
                    checkCond(statusCode == StatusCode.OK, "Invalid command for " & config.name & " Status: " & $statusCode)

                    for qq in qman.quests:
                        var qc = qman.config(qq)
                        if not qc.isNil:
                            var allDepsId = newSeq[QuestConfig]()
                            getAllDepsForQc(qc, allDepsId)
                            for dep in allDepsId:
                                let qid = dep.quest.id - 1
                                checkCond(qid < qman.completedQuests.len, "Incorrect quest config " & $(qid + 1))
                                checkCond(qman.completedQuests[qid], "Dep " & dep.name & " not compeleted for " & qc.name)
                    inc questDone

        echo "partsSpend ", partsSpend
        echo "bucksSpend ", bucksSpend
        echo "questsDone ", questDone
        echo "level ", profile.level
        echo "exp ", profile.experience

        profile.level = prevLevel

    template generateQttSpinNTimesTest(bi: BuildingId)=
        test("qttSpinNTimes_" & $bi): # todo: add freespin/bonus stage
            block:
                resetMachineState(bi)

                let spinsCount = 10
                let taskTargetProg = 10
                let quest = createSlotQuest(qttSpinNTimes, taskTargetProg, bi)
                let qid = quest.id
                qman.quests.add(quest)
                qman.acceptQuest(qid)

                for i in 0 ..< spinsCount:
                    let req = prepareJsonReq(minimumBet, machines[bi].lines.len)
                    var resp = newJObject()
                    var spinField = regularFields[bi]

                    spinOn(bi, profile, req, resp, spinField)
                    resetMachineState(bi)

                    let prevQstate = quest.tasks[0].currentProgress()
                    qman.onSlotSpin(prepareJsonDataForTask(bi, minimumBet, resp))
                    let stagesFromResp = getRespStages(resp)

                    checkCond(validateFields(spinField, getFieldFromResp(resp)), "Cheat spin doesnt work")

                    qman.saveChangesToProfile()
                    let curProg = quest.tasks[0].currentProgress()
                    if Stage.Spin in stagesFromResp:
                        checkCond(curProg > prevQstate, "Task progress on Spin stage failure")
                    else:
                        checkCond(abs(quest.tasks[0].currentProgress() - prevQstate) <= 0.01, "Task must progress only on Spin stage ")

                let msg = "Quest qttSpinNTimes doesnt work " & $quest.tasks[0].currentProgress()
                checkCond(quest.isCompleted(), msg) # todo: reproduce this bug

    generateQttSpinNTimesTest(dreamTowerSlot)
    generateQttSpinNTimesTest(balloonSlot)
    generateQttSpinNTimesTest(candySlot)

    template generateQttWinBigWinsTest(bi: BuildingId) =
        test("qttWinBigWins_" & $bi):
            block:
                resetMachineState(bi)
                let spinsCount = 10
                let taskTargetProg = 5
                let quest = createSlotQuest(qttWinBigWins, taskTargetProg, bi)
                let qid = quest.id
                qman.quests.add(quest)
                qman.acceptQuest(qid)
                for i in 0 ..< spinsCount:
                    let req = prepareJsonReq(minimumBet,  machines[bi].lines.len)
                    var resp = newJObject()

                    var spinField: seq[int8] = bigWinFields[bi]
                    spinOn(bi, profile, req, resp, spinField)
                    resetMachineState(bi)
                    let prevQstate = quest.tasks[0].currentProgress()
                    qman.onSlotSpin(prepareJsonDataForTask(bi, minimumBet, resp))
                    let stagesFromResp = getRespStages(resp)
                    checkCond(validateFields(spinField, getFieldFromResp(resp)), "Cheat spin doesnt work")
                    qman.saveChangesToProfile()
                    if Stage.Spin in stagesFromResp:
                        checkCond(quest.isCompleted() or quest.tasks[0].currentProgress() > prevQstate, "Task progress on Spin stage failure " & $(getSpinPayout(resp) div minimumBet))
                    else:
                        checkCond(abs(quest.tasks[0].currentProgress() - prevQstate) <= 0.01, "Task must progress only on Spin stage ")

                checkCond(quest.isCompleted(), "Quest qttSpinNTimes doesnt work")

    generateQttWinBigWinsTest(dreamTowerSlot)
    generateQttWinBigWinsTest(balloonSlot)
    generateQttWinBigWinsTest(candySlot)

    template generateQttMakeWinSpins(bi: BuildingId) =
        test("qttMakeWinSpins_" & $bi):
            block:
                resetMachineState(bi)
                let spinsCount = 10
                let taskTargetProg = 5
                let quest = createSlotQuest(qttMakeWinSpins, taskTargetProg, bi)
                let qid = quest.id
                qman.quests.add(quest)
                qman.acceptQuest(qid)
                for i in 0 ..< spinsCount:
                    let req = prepareJsonReq(minimumBet,  machines[bi].lines.len)
                    var resp = newJObject()

                    var spinField: seq[int8] = bigWinFields[bi]
                    spinOn(bi, profile, req, resp, spinField)
                    resetMachineState(bi)

                    let prevQstate = quest.tasks[0].currentProgress()
                    qman.onSlotSpin(prepareJsonDataForTask(bi, minimumBet, resp))
                    let stagesFromResp = getRespStages(resp)

                    checkCond(validateFields(spinField, getFieldFromResp(resp)), "Cheat spin doesnt work")

                    qman.saveChangesToProfile()
                    if Stage.Spin in stagesFromResp:
                        checkCond(quest.isCompleted() or quest.tasks[0].currentProgress() > prevQstate, "Task progress on Spin stage failure " & $(getSpinPayout(resp) div minimumBet))
                    else:
                        checkCond(abs(quest.tasks[0].currentProgress() - prevQstate) <= 0.01, "Task must progress only on Spin stage ")

                checkCond(quest.isCompleted(), "Quest qttSpinNTimes doesnt work")

    generateQttMakeWinSpins(dreamTowerSlot)
    generateQttMakeWinSpins(balloonSlot)
    generateQttMakeWinSpins(candySlot)

    template generateQttWinChipOnSpins(bi: BuildingId) =
        test("qttWinChipOnSpins_" & $bi):
            block:
                resetMachineState(bi)
                let spinsCount = 10
                let taskTargetProg = 50000
                let quest = createSlotQuest(qttWinChipOnSpins, taskTargetProg, bi)
                let qid = quest.id
                qman.quests.add(quest)
                qman.acceptQuest(qid)
                for i in 0 ..< spinsCount:
                    let req = prepareJsonReq(minimumBet,  machines[bi].lines.len)
                    var resp = newJObject()

                    var spinField: seq[int8] = bigWinFields[bi]
                    spinOn(bi, profile, req, resp, spinField)
                    resetMachineState(bi)

                    let prevQstate = quest.tasks[0].currentProgress()
                    qman.onSlotSpin(prepareJsonDataForTask(bi, minimumBet, resp))
                    let stagesFromResp = getRespStages(resp)

                    checkCond(validateFields(spinField, getFieldFromResp(resp)), "Cheat spin doesnt work")

                    qman.saveChangesToProfile()
                    if Stage.Spin in stagesFromResp:
                        checkCond(quest.isCompleted() or quest.tasks[0].currentProgress() > prevQstate, "Task progress on Spin stage failure " & $(getSpinPayout(resp) div minimumBet))
                    else:
                        checkCond(abs(quest.tasks[0].currentProgress() - prevQstate) <= 0.01, "Task must progress only on Spin stage ")

                checkCond(quest.isCompleted(), "Quest qttSpinNTimes doesnt work")

    generateQttWinChipOnSpins(dreamTowerSlot)
    generateQttWinChipOnSpins(balloonSlot)
    generateQttWinChipOnSpins(candySlot)

    template generateQttWinNChips(bi: BuildingId) =
        test("qttWinNChips_" & $bi):
            block:
                resetMachineState(bi)
                let spinsCount = 10
                let taskTargetProg = 50000
                let quest = createSlotQuest(qttWinNChips, taskTargetProg, bi)
                let qid = quest.id
                qman.quests.add(quest)
                qman.acceptQuest(qid)
                for i in 0 ..< spinsCount:
                    let req = prepareJsonReq(minimumBet,  machines[bi].lines.len)
                    var resp = newJObject()

                    var spinField: seq[int8] = bigWinFields[bi]
                    spinOn(bi, profile, req, resp, spinField)
                    resetMachineState(bi)

                    let prevQstate = quest.tasks[0].currentProgress()
                    qman.onSlotSpin(prepareJsonDataForTask(bi, minimumBet, resp))
                    let stagesFromResp = getRespStages(resp)

                    checkCond(validateFields(spinField, getFieldFromResp(resp)), "Cheat spin doesnt work")

                    qman.saveChangesToProfile()
                    if Stage.Spin in stagesFromResp:
                        checkCond(quest.isCompleted() or quest.tasks[0].currentProgress() > prevQstate, "Task progress on Spin stage failure " & $(getSpinPayout(resp) div minimumBet))
                    else:
                        checkCond(abs(quest.tasks[0].currentProgress() - prevQstate) <= 0.01, "Task must progress only on Spin stage ")

                checkCond(quest.isCompleted(), "Quest qttSpinNTimes doesnt work")

    generateQttWinNChips(dreamTowerSlot)
    generateQttWinNChips(balloonSlot)
    generateQttWinNChips(candySlot)

    template generateQttWinN5InRow(bi: BuildingId) =
        test("qttWinN5InRow_" & $bi):
            block:
                resetMachineState(bi)
                let spinsCount = 10
                let taskTargetProg = 10
                let quest = createSlotQuest(qttWinN5InRow, taskTargetProg, bi)
                let qid = quest.id
                qman.quests.add(quest)
                qman.acceptQuest(qid)
                for i in 0 ..< spinsCount:
                    let req = prepareJsonReq(minimumBet,  machines[bi].lines.len)
                    var resp = newJObject()

                    var spinField: seq[int8] = bigWinFields[bi]
                    spinOn(bi, profile, req, resp, spinField)
                    resetMachineState(bi)

                    let prevQstate = quest.tasks[0].currentProgress()
                    qman.onSlotSpin(prepareJsonDataForTask(bi, minimumBet, resp))
                    let stagesFromResp = getRespStages(resp)
                    checkCond(validateFields(spinField, getFieldFromResp(resp)), "Cheat spin doesnt work")

                    qman.saveChangesToProfile()
                    if Stage.Spin in stagesFromResp:
                        checkCond(quest.isCompleted() or quest.tasks[0].currentProgress() > prevQstate, "Task progress on Spin stage failure " & $(getSpinPayout(resp) div minimumBet))
                    else:
                        checkCond(abs(quest.tasks[0].currentProgress() - prevQstate) <= 0.01, "Task must progress only on Spin stage ")

                checkCond(quest.isCompleted(), "Quest qttWinN5InRow doesnt work")

    generateQttWinN5InRow(dreamTowerSlot)
    generateQttWinN5InRow(balloonSlot)
    generateQttWinN5InRow(candySlot)

    template generateQttWinN4InRow(bi: BuildingId) =
        test("qttWinN4InRow_" & $bi):
            block:
                resetMachineState(bi)
                let spinsCount = 10
                let taskTargetProg = 25
                let quest = createSlotQuest(qttWinN4InRow, taskTargetProg, bi)
                let qid = quest.id
                qman.quests.add(quest)
                qman.acceptQuest(qid)
                for i in 0 ..< spinsCount:
                    let req = prepareJsonReq(minimumBet,  machines[bi].lines.len)
                    var resp = newJObject()

                    var spinField: seq[int8] = bigWinFields[bi]
                    spinOn(bi, profile, req, resp, spinField)
                    resetMachineState(bi)

                    let prevQstate = quest.tasks[0].currentProgress()
                    qman.onSlotSpin(prepareJsonDataForTask(bi, minimumBet, resp))
                    let stagesFromResp = getRespStages(resp)

                    checkCond(validateFields(spinField, getFieldFromResp(resp)), "Cheat spin doesnt work")

                    qman.saveChangesToProfile()
                    if Stage.Spin in stagesFromResp:
                        checkCond(quest.isCompleted() or quest.tasks[0].currentProgress() > prevQstate, "Task progress on Spin stage failure " & $(getSpinPayout(resp) div minimumBet))
                    else:
                        checkCond(abs(quest.tasks[0].currentProgress() - prevQstate) <= 0.01, "Task must progress only on Spin stage ")

                checkCond(quest.isCompleted(), "Quest qttWinN4InRow doesnt work")

    generateQttWinN4InRow(dreamTowerSlot)
    generateQttWinN4InRow(balloonSlot)
    generateQttWinN4InRow(candySlot)

    template generateQttWinN3InRow(bi: BuildingId) =
        test("qttWinN3InRow_" & $bi):
            block:
                resetMachineState(bi)
                let spinsCount = 10
                let taskTargetProg = 25
                let quest = createSlotQuest(qttWinN3InRow, taskTargetProg, bi)
                let qid = quest.id
                qman.quests.add(quest)
                qman.acceptQuest(qid)
                for i in 0 ..< spinsCount:
                    let req = prepareJsonReq(minimumBet,  machines[bi].lines.len)
                    var resp = newJObject()

                    var spinField: seq[int8] = bigWinFields[bi]
                    spinOn(bi, profile, req, resp, spinField)
                    resetMachineState(bi)

                    let prevQstate = quest.tasks[0].currentProgress()
                    qman.onSlotSpin(prepareJsonDataForTask(bi, minimumBet, resp))
                    let stagesFromResp = getRespStages(resp)

                    checkCond(validateFields(spinField, getFieldFromResp(resp)), "Cheat spin doesnt work")

                    qman.saveChangesToProfile()
                    if Stage.Spin in stagesFromResp:
                        checkCond(quest.isCompleted() or quest.tasks[0].currentProgress() > prevQstate, "Task progress on Spin stage failure " & $(getSpinPayout(resp) div minimumBet))
                    else:
                        checkCond(abs(quest.tasks[0].currentProgress() - prevQstate) <= 0.01, "Task must progress only on Spin stage ")

                checkCond(quest.isCompleted(), "Quest qttWinN3InRow doesnt work")

    generateQttWinN3InRow(dreamTowerSlot)
    generateQttWinN3InRow(balloonSlot)
    generateQttWinN3InRow(candySlot)

    template generateQttSpinNTimesMaxBet(bi: BuildingId) =
        test("qttSpinNTimesMaxBet_" & $bi): # todo: add freespin/bonus stage
            block:
                resetMachineState(bi)

                let spinsCount = 10
                let taskTargetProg = 10
                let quest = createSlotQuest(qttSpinNTimesMaxBet, taskTargetProg, bi)
                let qid = quest.id
                qman.quests.add(quest)
                qman.acceptQuest(qid)

                for i in 0 ..< spinsCount:
                    let req = prepareJsonReq(maxBet, machines[bi].lines.len)
                    var resp = newJObject()
                    var spinField = regularFields[bi]

                    spinOn(bi, profile, req, resp, spinField)
                    resetMachineState(bi)

                    let prevQstate = quest.tasks[0].currentProgress()
                    qman.onSlotSpin(prepareJsonDataForTask(bi, maxBet, resp))
                    let stagesFromResp = getRespStages(resp)

                    checkCond(validateFields(spinField, getFieldFromResp(resp)), "Cheat spin doesnt work")

                    qman.saveChangesToProfile()
                    let curProg = quest.tasks[0].currentProgress()
                    if Stage.Spin in stagesFromResp:
                        checkCond(curProg > prevQstate, "Task progress on Spin stage failure")
                    else:
                        checkCond(abs(quest.tasks[0].currentProgress() - prevQstate) <= 0.01, "Task must progress only on Spin stage ")

                let msg = "Quest qttSpinNTimesMaxBet doesnt work " & $quest.tasks[0].currentProgress()
                checkCond(quest.isCompleted(), msg) # todo: reproduce this bug

    generateQttSpinNTimesMaxBet(dreamTowerSlot)
    generateQttSpinNTimesMaxBet(balloonSlot)
    generateQttSpinNTimesMaxBet(candySlot)

    template generateQttCollectScatters(bi: BuildingId) =
        test("qttCollectScatters_" & $bi):
            block:
                resetMachineState(bi)
                let spinsCount = 10
                let taskTargetProg = 10
                let quest = createSlotQuest(qttCollectScatters, taskTargetProg, bi)
                let qid = quest.id
                qman.quests.add(quest)
                qman.acceptQuest(qid)
                for i in 0 ..< spinsCount:
                    let req = prepareJsonReq(minimumBet,  machines[bi].lines.len)
                    var resp = newJObject()

                    var spinField: seq[int8] = regularFields[bi]
                    spinOn(bi, profile, req, resp, spinField)
                    resetMachineState(bi)

                    let prevQstate = quest.tasks[0].currentProgress()
                    qman.onSlotSpin(prepareJsonDataForTask(bi, minimumBet, resp))
                    let stagesFromResp = getRespStages(resp)

                    checkCond(validateFields(spinField, getFieldFromResp(resp)), "Cheat spin doesnt work")

                    qman.saveChangesToProfile()
                    if Stage.Spin in stagesFromResp:
                        checkCond(quest.isCompleted() or quest.tasks[0].currentProgress() > prevQstate, "Task progress on Spin stage failure " & $(getSpinPayout(resp) div minimumBet))
                    else:
                        checkCond(abs(quest.tasks[0].currentProgress() - prevQstate) <= 0.01, "Task must progress only on Spin stage ")

                checkCond(quest.isCompleted(), "Quest qttCollectScatters doesnt work")

    generateQttCollectScatters(dreamTowerSlot)
    generateQttCollectScatters(candySlot)


    template generateQttCollectBonus(bi: BuildingId) =
        test("qttCollectBonus_" & $bi):
            block:
                resetMachineState(bi)
                let spinsCount = 10
                let taskTargetProg = 10
                let quest = createSlotQuest(qttCollectBonus, taskTargetProg, bi)
                let qid = quest.id
                qman.quests.add(quest)
                qman.acceptQuest(qid)
                for i in 0 ..< spinsCount:
                    let req = prepareJsonReq(minimumBet,  machines[bi].lines.len)
                    var resp = newJObject()

                    var spinField: seq[int8] = regularFields[bi]
                    spinOn(bi, profile, req, resp, spinField)
                    resetMachineState(bi)

                    let prevQstate = quest.tasks[0].currentProgress()
                    qman.onSlotSpin(prepareJsonDataForTask(bi, minimumBet, resp))
                    let stagesFromResp = getRespStages(resp)

                    checkCond(validateFields(spinField, getFieldFromResp(resp)), "Cheat spin doesnt work")

                    qman.saveChangesToProfile()
                    if Stage.Spin in stagesFromResp:
                        checkCond(quest.isCompleted() or quest.tasks[0].currentProgress() > prevQstate, "Task progress on Spin stage failure " & $(getSpinPayout(resp) div minimumBet))
                    else:
                        checkCond(abs(quest.tasks[0].currentProgress() - prevQstate) <= 0.01, "Task must progress only on Spin stage ")

                checkCond(quest.isCompleted(), "Quest qttCollectBonus doesnt work")

    generateQttCollectBonus(dreamTowerSlot)
    generateQttCollectBonus(balloonSlot)
    generateQttCollectBonus(candySlot)

    template generateQttCollectWild(bi: BuildingId) =
        test("qttCollectWild_" & $bi):
            block:
                resetMachineState(bi)
                let spinsCount = 10
                let taskTargetProg = 10
                let quest = createSlotQuest(qttCollectWild, taskTargetProg, bi)
                let qid = quest.id
                qman.quests.add(quest)
                qman.acceptQuest(qid)
                for i in 0 ..< spinsCount:
                    let req = prepareJsonReq(minimumBet,  machines[bi].lines.len)
                    var resp = newJObject()

                    var spinField: seq[int8] = bigWinFields[bi]
                    spinOn(bi, profile, req, resp, spinField)
                    resetMachineState(bi)

                    let prevQstate = quest.tasks[0].currentProgress()
                    qman.onSlotSpin(prepareJsonDataForTask(bi, minimumBet, resp))
                    let stagesFromResp = getRespStages(resp)

                    checkCond(validateFields(spinField, getFieldFromResp(resp)), "Cheat spin doesnt work")

                    qman.saveChangesToProfile()
                    if Stage.Spin in stagesFromResp:
                        checkCond(quest.isCompleted() or quest.tasks[0].currentProgress() > prevQstate, "Task progress on Spin stage failure " & $(getSpinPayout(resp) div minimumBet))
                    else:
                        checkCond(abs(quest.tasks[0].currentProgress() - prevQstate) <= 0.01, "Task must progress only on Spin stage ")

                checkCond(quest.isCompleted(), "Quest qttCollectWild doesnt work")

    generateQttCollectWild(dreamTowerSlot)
    generateQttCollectWild(balloonSlot)
    generateQttCollectWild(candySlot)

    template generateQttWinFreespinsCount(bi: BuildingId) =
        test("qttWinFreespinsCount_" & $bi):
            block:
                resetMachineState(bi)
                let spinsCount = 100
                let taskTargetProg = 2
                let quest = createSlotQuest(qttWinFreespinsCount, taskTargetProg, bi)
                let qid = quest.id
                qman.quests.add(quest)
                qman.acceptQuest(qid)
                var freespinsTrig = false
                for i in 0 ..< spinsCount:
                    let req = prepareJsonReq(minimumBet,  machines[bi].lines.len)
                    var resp = newJObject()

                    if not freespinsTrig:
                        var spinField: seq[int8] = freeSpinFields[bi]
                        spinOn(bi, profile, req, resp, spinField)
                        if bi != balloonSlot:
                            checkCond(validateFields(spinField, getFieldFromResp(resp)), "Cheat spin doesnt work")
                    else:
                        spinOn(bi, profile, req, resp, looseFields[bi])

                    let prevQstate = quest.tasks[0].currentProgress()
                    qman.onSlotSpin(prepareJsonDataForTask(bi, minimumBet, resp))

                    let stagesFromResp = getRespStages(resp)
                    qman.saveChangesToProfile()
                    if Stage.FreeSpin in stagesFromResp:
                        freespinsTrig = true
                        if quest.tasks[0].currentProgress() < 1.0:
                            checkCond(quest.isCompleted() or quest.tasks[0].currentProgress() > prevQstate, "Task progress on FreeSpin stage failure " & $(getSpinPayout(resp) div minimumBet))
                    else:
                        checkCond(abs(quest.tasks[0].currentProgress() - prevQstate) <= 0.01, "Task must progress only on FreeSpin stage ")
                        freespinsTrig = false
                        if quest.isCompleted():
                            break

                checkCond(quest.isCompleted(), "Quest qttWinFreespinsCount doesnt work")

    generateQttWinFreespinsCount(dreamTowerSlot)
    generateQttWinFreespinsCount(balloonSlot)
    generateQttWinFreespinsCount(candySlot)

    template generateQttWinChipOnFreespins(bi: BuildingId) =
        test("qttWinChipOnFreespins_" & $bi):
            block:
                resetMachineState(bi)
                let spinsCount = 1000
                let taskTargetProg = 5000
                let quest = createSlotQuest(qttWinChipOnFreespins, taskTargetProg, bi)
                let qid = quest.id
                qman.quests.add(quest)
                qman.acceptQuest(qid)
                var freespinsTrig = false
                # for i in 0 ..< spinsCount:
                var spins = 0
                while not quest.isCompleted():
                    checkCond(spins < spinsCount, "Task progress stuck!")
                    let req = prepareJsonReq(maxBet,  machines[bi].lines.len)
                    var resp = newJObject()
                    let prevQstate = quest.tasks[0].currentProgress()

                    if not freespinsTrig:
                        var spinField: seq[int8] = freeSpinFields[bi]
                        spinOn(bi, profile, req, resp, spinField)
                        if bi != balloonSlot:
                            checkCond(validateFields(spinField, getFieldFromResp(resp)), "Cheat spin doesnt work")
                    else:
                        if bi != balloonSlot:
                            spinOn(bi, profile, req, resp, bigWinFields[bi])
                        else:
                            spinOn(bi, profile, req, resp, nil)

                    qman.onSlotSpin(prepareJsonDataForTask(bi, maxBet, resp))

                    let stagesFromResp = getRespStages(resp)
                    qman.saveChangesToProfile()
                    if Stage.FreeSpin in stagesFromResp:
                        freespinsTrig = true
                        checkCond(quest.tasks[0].progresses[0].current <= quest.tasks[0].progresses[0].total, "Task progress can't overflow")

                        var spinPay = "Task progress on FreeSpin stage failure " & $getSpinPayout(resp)

                        if quest.tasks[0].currentProgress() < 1.0:
                            checkCond(quest.tasks[0].currentProgress() >= prevQstate, spinPay)
                    else:
                        checkCond(abs(quest.tasks[0].currentProgress() - prevQstate) <= 0.01, "Task must progress only on FreeSpin stage ")
                        freespinsTrig = false

                    inc spins

                checkCond(quest.isCompleted(), "Quest qttWinChipOnFreespins doesnt work")

    generateQttWinChipOnFreespins(dreamTowerSlot)
    generateQttWinChipOnFreespins(balloonSlot)
    generateQttWinChipOnFreespins(candySlot)


    template generateQttWinBonusTimes(bi: BuildingId) =
        test("qttWinBonusTimes_" & $bi):
            block:
                resetMachineState(bi)
                let spinsCount = 100
                let taskTargetProg = 5
                let quest = createSlotQuest(qttWinBonusTimes, taskTargetProg, bi)
                let qid = quest.id
                qman.quests.add(quest)
                qman.acceptQuest(qid)
                for i in 0 ..< spinsCount:
                    let req = prepareJsonReq(minimumBet,  machines[bi].lines.len)
                    var resp = newJObject()

                    var spinField: seq[int8] = bonusFields[bi]
                    if bi == balloonSlot and i mod 2 == 1:
                        spinOn(bi, profile, req, resp, nil)
                        resetMachineState(bi)
                    else:
                        spinOn(bi, profile, req, resp, spinField)

                        if bi != balloonSlot:
                            checkCond(validateFields(spinField, getFieldFromResp(resp)), "Cheat spin doesnt work")

                    let prevQstate = quest.tasks[0].currentProgress()
                    qman.onSlotSpin(prepareJsonDataForTask(bi, minimumBet, resp))
                    let stagesFromResp = getRespStages(resp)

                    qman.saveChangesToProfile()

                    if Stage.Bonus in stagesFromResp:
                        checkCond(quest.tasks[0].currentProgress() == 1.0 or quest.tasks[0].currentProgress() > prevQstate, "Task progress on Bonus stage failure " & $getBonusPayout(resp))
                    else:
                        checkCond(abs(quest.tasks[0].currentProgress() - prevQstate) <= 0.01, "Task must progress only on Bonus stage ")

                    if quest.isCompleted():
                        break

                let msg = $quest.tasks[0].currentProgress()
                checkCond(quest.isCompleted(), "Quest qttWinBonusTimes doesnt work " & msg)

    generateQttWinBonusTimes(dreamTowerSlot)
    generateQttWinBonusTimes(balloonSlot)
    generateQttWinBonusTimes(candySlot)

    template generateQttWinChipsOnBonus(bi: BuildingId) =
        test("qttWinChipsOnBonus_" & $bi):
            block:
                resetMachineState(bi)
                let spinsCount = 10
                let taskTargetProg = 30000
                let quest = createSlotQuest(qttWinChipsOnBonus, taskTargetProg, bi)
                let qid = quest.id
                qman.quests.add(quest)
                qman.acceptQuest(qid)
                for i in 0 ..< spinsCount:
                    let req = prepareJsonReq(maxBet,  machines[bi].lines.len)
                    var resp = newJObject()

                    var spinField: seq[int8] = bonusFields[bi]
                    if bi == balloonSlot and i mod 2 == 1:
                        spinOn(bi, profile, req, resp, nil)
                        # resetMachineState(bi)
                    else:
                        spinOn(bi, profile, req, resp, spinField)

                        if bi != balloonSlot:
                            checkCond(validateFields(spinField, getFieldFromResp(resp)), "Cheat spin doesnt work")

                    let prevQstate = quest.tasks[0].currentProgress()
                    qman.onSlotSpin(prepareJsonDataForTask(bi, maxBet, resp))
                    let stagesFromResp = getRespStages(resp)

                    qman.saveChangesToProfile()

                    if Stage.Bonus in stagesFromResp:
                        checkCond(getBonusPayout(resp) > 0 and (quest.isCompleted() or quest.tasks[0].currentProgress() > prevQstate), "Task progress on Bonus stage failure " & $getBonusPayout(resp))
                    else:
                        checkCond(abs(quest.tasks[0].currentProgress() - prevQstate) <= 0.01, "Task must progress only on Bonus stage ")

                let msg = $quest.tasks[0].currentProgress()
                checkCond(quest.isCompleted(), "Quest qttWinChipsOnBonus doesnt work " & msg)

    generateQttWinChipsOnBonus(dreamTowerSlot)
    generateQttWinChipsOnBonus(balloonSlot)
    generateQttWinChipsOnBonus(candySlot)

    template generateQttMakeNRespins(bi: BuildingId) =
        test("qttMakeNRespins_" & $bi):
            block:
                resetMachineState(bi)
                let spinsCount = 100
                let taskTargetProg = 5
                let quest = createSlotQuest(qttMakeNRespins, taskTargetProg, bi)
                let qid = quest.id
                qman.quests.add(quest)
                qman.acceptQuest(qid)
                var respinsTrig = false
                var spins = 0
                while not quest.isCompleted():

                    checkCond(spins < spinsCount, "Task progress stuck!")
                    let req = prepareJsonReq(minimumBet,  machines[bi].lines.len)
                    var resp = newJObject()

                    if not respinsTrig:
                        var spinField: seq[int8] = bigWinFields[bi]
                        spinOn(bi, profile, req, resp, spinField)
                        if bi != balloonSlot:
                            checkCond(validateFields(spinField, getFieldFromResp(resp)), "Cheat spin doesnt work")
                    else:
                        spinOn(bi, profile, req, resp, nil)

                    let prevQstate = quest.tasks[0].currentProgress()
                    qman.onSlotSpin(prepareJsonDataForTask(bi, minimumBet, resp))
                    let stagesFromResp = getRespStages(resp)

                    qman.saveChangesToProfile()
                    if Stage.Respin in stagesFromResp:
                        respinsTrig = true
                        checkCond(quest.tasks[0].currentProgress() == 1.0 or quest.tasks[0].currentProgress() > prevQstate, "Task progress on Respin stage failure " & $(getSpinPayout(resp) div minimumBet))
                    else:

                        checkCond(abs(quest.tasks[0].currentProgress() - prevQstate) <= 0.01, "Task must progress only on Respin stage ")
                        respinsTrig = false

                    inc spins

                checkCond(quest.isCompleted(), "Quest qttMakeNRespins doesnt work")

    generateQttMakeNRespins(balloonSlot)

    test("qttBlowNBalloon_balloonSlot"):
        block:
            let bi = balloonSlot
            resetMachineState(bi)

            let spinsCount = 10
            let taskTargetProg = 30
            let quest = createSlotQuest(qttBlowNBalloon, taskTargetProg, bi)
            let qid = quest.id
            qman.quests.add(quest)
            qman.acceptQuest(qid)

            for i in 0 ..< spinsCount:
                let req = prepareJsonReq(maxBet, machines[bi].lines.len)
                var resp = newJObject()
                var spinField = bigWinFields[bi]

                spinOn(bi, profile, req, resp, spinField)
                resetMachineState(bi)
                let prevQstate = quest.tasks[0].currentProgress()
                qman.onSlotSpin(prepareJsonDataForTask(bi, maxBet, resp))
                let stagesFromResp = getRespStages(resp)

                checkCond(validateFields(spinField, getFieldFromResp(resp)), "Cheat spin doesnt work")

                qman.saveChangesToProfile()
                let curProg = quest.tasks[0].currentProgress()

                checkCond(quest.isCompleted() or curProg > prevQstate, "Task must progress allways with this cheatField")

            let msg = "Quest qttSpinNTimes doesnt work " & $quest.tasks[0].currentProgress()
            checkCond(quest.isCompleted(), msg) # todo: reproduce this bug

    test("qttPolymorphNSymbolsIntoWild_candySlot"):
        block:
            let bi = candySlot
            resetMachineState(bi)

            let spinsCount = 10
            let taskTargetProg = 30
            let quest = createSlotQuest(qttPolymorphNSymbolsIntoWild, taskTargetProg, bi)
            let qid = quest.id
            qman.quests.add(quest)
            qman.acceptQuest(qid)

            for i in 0 ..< spinsCount:
                let req = prepareJsonReq(maxBet, machines[bi].lines.len)
                var resp = newJObject()
                var spinField = @[3.int8, 3, 4, 5, 0, 3, 3, 4, 5, 0, 0, 6, 6, 6, 0]

                spinOn(bi, profile, req, resp, spinField)

                let prevQstate = quest.tasks[0].currentProgress()
                qman.onSlotSpin(prepareJsonDataForTask(bi, maxBet, resp))
                let stagesFromResp = getRespStages(resp)

                checkCond(validateFields(spinField, getFieldFromResp(resp)), "Cheat spin doesnt work")

                qman.saveChangesToProfile()
                let curProg = quest.tasks[0].currentProgress()
                if Stage.Spin in stagesFromResp:
                    checkCond(quest.isCompleted() or curProg > prevQstate, "Task progress on Spin stage failure")
                else:
                    checkCond(curProg == prevQstate, "Task must progress only on Spin stage ")

            let msg = "Quest qttSpinNTimes doesnt work " & $quest.tasks[0].currentProgress()
            checkCond(quest.isCompleted(), msg) # todo: reproduce this bug
