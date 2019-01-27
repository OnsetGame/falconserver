import nimongo.bson
import asyncdispatch
import falconserver / auth / [ profile, profile_types, profile_helpers, gameplay_config ]
import falconserver / common / [ currency, response, orm ]
import falconserver / map / building / [ builditem, jsonbuilding ]
import falconserver.map.map
import falconserver / quest / [ quest_task, tasks_script, quest_types, quests_config, generator, quest ]
import json
import tables, boolseq, strutils, math, sequtils

import falconserver.common.bson_helper

import times
import falconserver.common.notifications
import falconserver.boosters.boosters
import shafa / game / reward_types

export QuestConfig

type
    TasksStage = ref object
        stage: int
        tasksIds: seq[int]
        done: bool

    SlotQuest* = ref object
        stage*: int
        questId*: int

    QuestManager* = ref object
        ## QuestManager performs quests processing:
        ## - generates quests objects from profile data
        ## - calls quest state change trigger methods
        ## - prepares profile update queries
        profile: Profile
        quests*: seq[Quest]
        completedQuests*: BoolSeq
        slotQuests*: TableRef[BuildingId, SlotQuest]
        autogenerateSlotQuests: bool


proc getStoryConfig*(manager: QuestManager): seq[QuestConfig] =
    manager.profile.gconf.getStoryConfig()


proc config*(manager: QuestManager, quest: Quest): QuestConfig=
    if quest.id - 1 < manager.getStoryConfig().len:
        result = manager.getStoryConfig()[quest.id - 1]


proc questsOfType*(manager: QuestManager, t: QuestTaskType): seq[Quest]=
    result = @[]
    if manager.quests.len() > 0:
        for quest in manager.quests:
            for task in quest.tasks:
                if task.kind == t:
                    result.add(quest)
                    break


proc speedUpPrice*(manager: QuestManager, quest: Quest): int =
    case quest.kind
    of QuestKind.Story:
        if quest.isQuestActive():
            let ttga = max(quest.timeToGoalAchieved() - epochTime(), 0.0)
            if ttga == 0.0:
                result = 0
            else:
                let gb = manager.profile.gconf.getGameBalance()
                result = (max(ttga/60.0, 1.0) * gb.questSpeedUpPrice.float).int
    of QuestKind.Daily:
        result = manager.profile.gconf.getDailyConfig().skipCost[quest.tasks[0].difficulty]
    else:
        discard


proc readProfile*(quest: Quest, p: Profile)=
    quest.data[$qfState][$prfExperience] = p[$prfExperience]
    if quest.data{$qfState, $prfLevel}.isNil:
        quest.data[$qfState][$qdfOldLvl] = p[$prfLevel]
    else:
        quest.data[$qfState][$qdfOldLvl] = quest.data[$qfState][$prfLevel]
    quest.data[$qfState][$prfLevel] = p[$prfLevel]

proc getRewards*(m: QuestManager, q: Quest): seq[Reward]=
    case q.kind:
    of QuestKind.LevelUp:
        let gb = m.profile.gconf.getGameBalance()
        let lvli = clamp(m.profile.level - 1, 0, gb.levelProgress.len - 1)
        return gb.levelProgress[lvli].rewards

    of QuestKind.Story:
        let qc = m.config(q)
        if not qc.isNil:
            return qc.rewards

    of QuestKind.Daily:
        let gb = m.profile.gconf.getDailyConfig()
        let difficulty = q.tasks[0].difficulty
        return gb.rewards[difficulty]

    else:
        discard

proc toClientJson*(manager: QuestManager, quest: Quest): JsonNode=
    result = newJObject()
    result[$qfStatus] = quest.data[$qfStatus].toJson()
    result[$qfTasks]  = quest.data[$qfTasks].toJson()
    result[$qfId]     = quest.data[$qfId].toJson()
    result[$qfKind]   = quest.data[$qfKind].toJson()
    result["skipPrice"] = %manager.speedUpPrice(quest)

    if quest.kind == QuestKind.Daily:
        result["rews"] = manager.getRewards(quest).toJson()

## user for cheats
proc onProfileChanged*(manager: QuestManager, prof: Profile)=
    for q in manager.quests:
        q.readProfile(prof)


proc proceedSlotResponse*(gconf: GameplayConfig, t: QuestTask, data: JsonNode)=
    let progressResponseWorker = progressResponseWorkers.getOrDefault(t.kind)
    if not progressResponseWorker.isNil:
        var curStage = t.getCurrentStage(data)
        gconf.progressResponseWorker(t, data)
        if curStage != "Spin":
            t.progressState = qtpHasProgress
        t.prevStage = curStage
    else:
        echo "Response worker not found for ", t.kind


proc onSlotSpin*(gconf: GameplayConfig, quest: Quest, data: JsonNode) =
    ## This event is called when `spin` API call came from client
    if not quest.isQuestActive(): return
    if quest.kind == QuestKind.Daily:
        var bi : BuildingId
        try:
            bi = parseEnum[BuildingId](data["slot"].getStr())
        except: discard

        for t in quest.tasks:
            if bi == t.target:
                gconf.proceedSlotResponse(t, data)


proc onSlotSpin*(manager: QuestManager, res: JsonNode)=
    for quest in manager.quests:
        manager.profile.gconf.onSlotSpin(quest, res)
        quest.readProfile(manager.profile)


proc getSlotQuestsBson*(manager: QuestManager): Bson =
    #result = manager.currentStage.tasksIds
    result = newBsonDocument()
    for k,v in manager.slotQuests:
        result[$k] = bson.`%*`({"s": v.stage, "q": v.questId})


proc progress*(gconf: GameplayConfig, quest: Quest): QuestProgress =
    ## Return QuestProgress for quest
    result = quest.data[$qfStatus].toInt().QuestProgress
    if quest.isQuestActive():
        result = QuestProgress.None

        let state = quest.data[$qfState]
        for task in quest.tasks:
            case gconf.progress(task, state)
            of qtpCompleted:
                if result == QuestProgress.None:
                    result = QuestProgress.GoalAchieved
            else:
                result = QuestProgress.InProgress

        quest.data[$qfStatus] = result.int32.toBson()


proc saveChangesToProfile*(manager: QuestManager) =
    ## Processes all updates that were set by quest objects
    ## and prepares one big MongoDB update request
    var quests = newBsonArray()
    var levelupCount = 0
    for quest in manager.quests:
        var prog = manager.profile.gconf.progress(quest)
        var data = quest.toBson()

        if prog == QuestProgress.GoalAchieved or prog == QuestProgress.Completed:
            if quest.kind != QuestKind.Story or (not manager.config(quest).isNil and manager.config(quest).autoComplete):
                data[$qfStatus] = QuestProgress.Completed.int32.toBson()
                quest.data[$qfStatus] = data[$qfStatus]

        if quest.kind == QuestKind.LevelUp:
            inc levelupCount

        quests.add(data)

    manager.profile.quests = quests
    if manager.completedQuests.string.len != 0:
        manager.profile.statistics.questsCompleted = binuser(manager.completedQuests.string)
    manager.profile.slotQuests = manager.getSlotQuestsBson()


proc questsForClient*(manager: QuestManager): JsonNode =
    result = newJObject()
    var quests = newJArray()
    for quest in manager.quests:
        if quest.id < 0: continue
        var jQuest = manager.toClientJson(quest)
        let conf = manager.config(quest)
        if quest.kind == QuestKind.Story and not conf.isNil:
            jQuest["config"] = conf.toJson()
            jQuest["config"]["endTime"] = %quest.timeToGoalAchieved()

        quests.add(jQuest)
    result["queseq"] = quests
    result["questate"] = %(manager.completedQuests.toIntSeq())
    result["slotQuests"] = newJObject()
    for k,v in manager.slotQuests:
        result["slotQuests"][$k] = json.`%*`({"s": v.stage, "q": v.questId})


proc updatesForClient*(manager: QuestManager): JsonNode =
    result = newJObject()
    var quests = newJArray()
    for quest in manager.quests:
        if quest.data[$qfStatus].toInt() > 0 and not quest.data[$qfId].toInt() < 0: # quest progress completed or has updates
            quests.add(manager.toClientJson(quest))
    result["queseq"] = quests
    result["questate"] = %(manager.completedQuests.toIntSeq())
    result["slotQuests"] = newJObject()
    for k,v in manager.slotQuests:
        result["slotQuests"][$k] = json.`%*`({"s": v.stage, "q": v.questId})


proc questById*(manager: QuestManager, questId: int, onQFind:proc(q: Quest, i: int)) =
    var i = -1
    for q in manager.quests:
        inc i
        if q.id == questId:
            onQFind(q, i)
            return
    onQFind(nil, i)


proc questById*(manager: QuestManager, questId: int): Quest =
    var res: Quest
    manager.questById(questId) do(q: Quest, i: int):
        res = q
    result = res


proc getSlotQuest*(manager: QuestManager, target: BuildingId): SlotQuest =
    if target notin manager.slotQuests:
        result = new SlotQuest
        manager.slotQuests[target] = result
    else:
        result = manager.slotQuests[target]


proc cheatCompleteTasks*(manager: QuestManager, idx: int)=
    manager.questById(idx) do(q: Quest, i: int):
        if not q.isNil:
            for t in q.tasks:
                t.completeProgress()
            manager.saveChangesToProfile()


proc acceptQuest*(manager: QuestManager, idx: int): bool {.discardable.}=
    var r = false
    manager.questById(idx) do(q: Quest, i: int):
        if not q.isNil:
            r = true
            q.data[$qfStatus] = (QuestProgress.InProgress).int.toBson()
            if q.kind == QuestKind.Story:
                let conf = manager.config(q)
                q.onStoryStart(conf.time, conf.autoComplete)
                manager.saveChangesToProfile()
                if conf.time > 0:
                    forkNotifyQuestIsComplete(manager.profile, conf.name, conf.isMainQuest, epochtime() + conf.time)
    result = r


proc generateNextStageSlotQuest*(manager: QuestManager, target: BuildingId, removeOldQuest: bool = true): bool =
    let (stageLevel, quest) = manager.profile.generateSlotQuest(target)
    if quest.isNil:
        return false

    result = true
    if target notin manager.slotQuests:
        manager.slotQuests[target] = new SlotQuest
    else:
        if removeOldQuest:
            manager.questById(manager.slotQuests[target].questId) do(q: Quest, i: int):
                if not q.isNil:
                    manager.quests.del(i)

    inc manager.slotQuests[target].stage
    manager.quests.add quest
    manager.slotQuests[target].questId = quest.id
    #echo "generateNextStageSlotQuest for ", target, " -> quest ", quest.id, ", stage ", manager.slotQuests[target].stage

    manager.saveChangesToProfile()


proc speedUpQuest*(manager: QuestManager, idx: int): Future[void] {.async.} =
    var q = manager.questById(idx)
    if not q.isNil:
        case q.kind
        of QuestKind.Story:
            q.onStorySpeedUp()
            # if not q.config.isNil:
            #     manager.profile.updateMapStateOnQuestComplete(q.config)
            manager.saveChangesToProfile()
            await cancelNotifyQuestIsComplete(manager.profile, manager.config(q).name)
        of QuestKind.Daily:
            discard manager.generateNextStageSlotQuest(q.tasks[0].target)
        else:
            discard


template pause(q: Quest) =
    q.data[$qfStatus] = (QuestProgress.Ready).int.toBson()


proc pauseQuest*(manager: QuestManager, idx: int)=
    manager.questById(idx) do(q: Quest, i: int):
        if not q.isNil:
            q.pause()
            manager.saveChangesToProfile()


proc completeQuest*(manager: QuestManager, idx: int)=
    manager.questById(idx) do(q: Quest, i: int):
        if not q.isNil:
            if q.kind == QuestKind.Story:
                if q.data[$qfStatus].toInt32().QuestProgress == QuestProgress.GoalAchieved:
                    q.data[$qfStatus] = QuestProgress.Completed.int32.toBson()
                    if not manager.config(q).isNil:
                        manager.profile.updateMapStateOnQuestComplete(manager.config(q))
                    manager.saveChangesToProfile()
            elif q.kind == QuestKind.Daily:
                discard manager.generateNextStageSlotQuest(q.tasks[0].target, removeOldQuest = false)


proc nextQuestsAfter*(manager: QuestManager, qid: int): seq[Quest]


proc markQuestAsCompleted(manager: QuestManager, qid: int)=
    let idx = qid - 1
    if idx >= manager.completedQuests.len:
        manager.completedQuests.setLen(qid)

    manager.completedQuests[idx] = true
    manager.saveChangesToProfile()

proc gainVipAccess*(manager: QuestManager, target: string)=
    let qcs = manager.getStoryConfig()
    for i, qc in qcs:
        if qc.target == target:

            manager.profile.updateMapStateOnQuestComplete(qc)

            var quests = manager.nextQuestsAfter(i + 1)
            if quests.len > 0:
                manager.quests.add(quests)
            manager.markQuestAsCompleted(i + 1)
            return

proc deleteQuestById(manager: QuestManager, questId:int)=
    manager.questById(questId) do(q: Quest, i: int):
        if not q.isNil:
            manager.quests.delete(i)

            var pi = 0
            for pq in manager.profile.quests:
                if pq[$qfId].toInt() == questId:
                    manager.profile.quests.del(pi)
                    break
                inc pi

proc cheatDeleteQuestById*(manager: QuestManager, qid: int)=
    manager.deleteQuestById(qid)


proc replaceSlotQuest*(manager: QuestManager, target: BuildingId, questId: int) =
    let sq = manager.getSlotQuest(target)
    if sq.questId > 0:
        manager.deleteQuestById(sq.questId)
    sq.questId = questId
    manager.saveChangesToProfile()


proc getRewardsAndRemoveIfCompleted*(manager: QuestManager, questId: int): seq[Reward]=
    var rewards: seq[Reward]
    manager.questById(questId) do(q: Quest, i: int):
        if not q.isNil:
            if q.isCompleted():
                rewards = manager.getRewards(q)

                if q.kind == QuestKind.Story and not manager.config(q).isNil:
                    #manager.profile.updateMapStateOnQuestComplete(q.config)
                    manager.markQuestAsCompleted(questId)

                else:
                    for k,v in manager.slotQuests:
                        if v.questId == q.id:
                            v.questId = 0
                            break

                manager.deleteQuestById(q.id)

            manager.saveChangesToProfile()

    result = rewards


proc getActiveSlotQuest*(manager: QuestManager, target: BuildingId): Quest =
    if target in manager.slotQuests:
        let q = manager.questById(manager.slotQuests[target].questId)
        if not q.isNil and q.isQuestActive():
            return q


proc getActiveSlotQuest*(manager: QuestManager, targetstr: string): Quest =
    try:
        var bi = parseEnum[BuildingId](targetstr)
        return manager.getActiveSlotQuest(bi)
    except:
        return nil


proc isFirstTaskCompleted*(manager: QuestManager): bool =
    for k, v in manager.slotQuests:
        if v.stage > 1 or v.questId == 0:
            return true


proc isQuestCompleted*(manager: QuestManager, qid: int): bool =
    let qid = qid - 1
    result = qid < manager.completedQuests.len and manager.completedQuests[qid]


proc isAllDepsCompeleted(manager:QuestManager, qc: QuestConfig): bool =
    if not qc.enabled: return false
    result = true

    for depqc in qc.deps:
        let dqid = depqc.quest.id
        if not manager.isQuestCompleted(dqid):
            result = false


proc isFirstSeenQuest(manager: QuestManager, q: Quest): bool {.inline.}=
    return not manager.isQuestCompleted(q.id) and manager.questById(q.id).isNil


proc isLockedByLvl(qc: QuestConfig): bool = qc.lockedByLevel != notLockedByLevel

proc isLockedByVipLvl(qc: QuestConfig): bool = qc.lockedByVipLevel != notLockedByLevel

proc levelReached(man: QuestManager, qc: QuestConfig): bool = qc.lockedByLevel <= man.profile.level

proc vipLevelReached(man: QuestManager, qc: QuestConfig): bool = qc.lockedByVipLevel.int64 <= man.profile.vipLevel

proc isQuestAvailable(m: QuestManager, qc: QuestConfig): bool =
    m.levelReached(qc) and m.vipLevelReached(qc) and m.isAllDepsCompeleted(qc) and m.isFirstSeenQuest(qc.quest) and not qc.vipOnly

proc questsForLevel(manager: QuestManager, queseq: var seq[Quest]) =
    for qc in manager.getStoryConfig():
        if not qc.enabled: continue
        if qc.isLockedByLvl() and manager.isQuestAvailable(qc):
            queseq.add(qc.quest)

proc questForVipLevel(manager: QuestManager, queseq: var seq[Quest]) =
    for qc in manager.getStoryConfig():
        if not qc.enabled: continue
        if qc.isLockedByVipLvl() and manager.isQuestAvailable(qc):
            queseq.add(qc.quest)

proc nextQuestsAfter*(manager: QuestManager, qid: int): seq[Quest]=
    result = @[]
    if qid > 0 and qid - 1 < manager.getStoryConfig().len:
        let qc = manager.getStoryConfig()[qid - 1]
        for openqc in qc.opens:
            if manager.isQuestAvailable(openqc):
                result.add(openqc.quest)

    if qid == -1:
        manager.questsForLevel(result)

proc rootQuestsConfig*(manager: QuestManager): seq[QuestConfig]=
    result = @[]
    for qc in manager.getStoryConfig():
        if qc.deps.len == 0:
            result.add(qc)


proc printQuestTree(manager: QuestManager, fromQ: QuestConfig = nil): string=
    if fromQ.isNil:
        let rootqs = manager.rootQuestsConfig()
        result = ""
        for rt in rootqs:
            result &= "\n QUESTS_TREE: " & manager.printQuestTree(rt)
    else:
        result = " " & fromQ.name & ": " & $fromQ.quest.id & " "
        if fromQ.opens.len > 0:
            result &= " --> "
        else:
            result &= "\n"
        for qc in fromQ.opens:
            result &= manager.printQuestTree(qc)

proc initialQuests*(manager: QuestManager): seq[Quest]=
    result = @[]
    let rqc = manager.rootQuestsConfig()
    for qc in rqc:
        if not qc.enabled: continue
        if manager.isFirstSeenQuest(qc.quest) and not qc.isLockedByLvl() and manager.vipLevelReached(qc) and not qc.vipOnly:
            result.add(qc.quest)

    for i , qc in manager.getStoryConfig():
        for openqc in qc.opens:
            if manager.isAllDepsCompeleted(openqc) and manager.isFirstSeenQuest(openqc.quest) and not openqc.vipOnly:
                if openqc.quest notin result and manager.levelReached(openqc) and manager.vipLevelReached(openqc):
                    result.add(openqc.quest)

    manager.questsForLevel(result)

proc questIdFromName*(profile: Profile, name: string): int =
    for index, qc in profile.gconf.getStoryConfig():
        if qc.name == name:
            return index + 1 #WTF? Need refactoring quest system!

proc questsConfigForClient*(manager: QuestManager): JsonNode=
    result = newJArray()
    for qc in manager.getStoryConfig():
        var jc = newJObject()
        result.add(qc.toJson())


proc generateSlotQuests(manager: QuestManager) =
    var questSlots = manager.profile.slotsBuilded()
    if dreamTowerSlot notin questSlots:
        questSlots.add(dreamTowerSlot)

    for target in questSlots:
        if target notin manager.slotQuests or manager.slotQuests[target].questId == 0:
            discard manager.generateNextStageSlotQuest(target)
            # first quest in game should be automatically accepted
            if target == dreamTowerSlot and manager.slotQuests[target].stage == 1:
                manager.acceptQuest(manager.slotQuests[target].questId)


proc updateFromProfile*(manager: QuestManager) =
    manager.quests = @[]

    var questsSeen = newSeq[int]()
    for questData in manager.profile.quests:
        assert($qfTasks in questData)
        let q = loadQuest(questData)

        if q.id notin questsSeen:
            questsSeen.add(q.id)
            manager.quests.add(q)

    manager.slotQuests = newTable[BuildingId, SlotQuest]()
    if not manager.profile.slotQuests.isNil:
        for k,v in manager.profile.slotQuests:
            let slotQuest = new SlotQuest
            slotQuest.stage = max(v["s"].toInt32(), 0)
            slotQuest.questId = v["q"].toInt32()
            manager.slotQuests[parseEnum[BuildingId](k)] = slotQuest

    if manager.autogenerateSlotQuests:
        manager.generateSlotQuests()  # generate new quests here, if new building unlocked, or slot quest was complete

    var binStr = ""
    if not manager.profile.statistics.questsCompleted.isNil:
        binstr = manager.profile.statistics.questsCompleted.binstr()

    manager.completedQuests = newBoolSeq(binStr)


proc ensureLevelUpQuestExists*(manager: QuestManager) =
    for quest in manager.quests:
        if quest.kind == QuestKind.LevelUp:
            return
    let quest = manager.profile.createLevelUpQuest()
    if not quest.isNil:
        manager.profile[$prfQuests].add(quest.toBson())
        manager.updateFromProfile()

proc proceedVipLevelup*(manager: QuestManager)=
    var queseq = manager.quests
    manager.questForVipLevel(queseq)


proc newQuestManager*(profile: Profile, autogenerateSlotQuests: bool = true): QuestManager =
    ## Constructs quests manager which itself takes active quests data from profile
    ## and builds Quest object of it.
    result.new()
    result.profile = profile
    result.autogenerateSlotQuests = autogenerateSlotQuests
    result.slotQuests = newTable[BuildingId, SlotQuest]()
    result.updateFromProfile()

type QuestManagerCommand = proc(manager: QuestManager, questId: int): Future[tuple[resp:JsonNode, statusCode: StatusCode]]
var questManagerCommands = initTable[string, QuestManagerCommand]()


proc proceedCommand*(manager: QuestManager, command: string, jData: JsonNode): Future[tuple[resp:JsonNode, statusCode: StatusCode]] {.async.} =
    let indx = jData["questIndex"].getInt()

    let doCommand = questManagerCommands.getOrDefault(command)
    if not doCommand.isNil:
        result = await manager.doCommand(indx)
    else:
        result.resp = newJObject()
        result.statusCode = StatusCode.InvalidRequest


questManagerCommands["accept"] = proc(manager: QuestManager, questId: int): Future[tuple[resp:JsonNode, statusCode: StatusCode]] {.async.} =
    let q = manager.questById(questId)
    if q.isNil:
        return (newJObject(), StatusCode.QuestNotFound)
    if q.data[$qfStatus].toInt().QuestProgress > QuestProgress.Ready:
        return (newJObject(), StatusCode.InvalidQuestState)

    if q.kind == QuestKind.Story:
        let conf = manager.config(q)
        if manager.profile.tryWithdraw(conf.currency, conf.price):
            if not manager.acceptQuest(questId):
                return (newJObject(), StatusCode.QuestNotFound)
            else:
                manager.saveChangesToProfile()
                return (newJObject(), StatusCode.OK)
        else:
            return (newJObject(), StatusCode.NotEnougthParts)
    else:
        if not manager.acceptQuest(questId):
            return (newJObject(), StatusCode.QuestNotFound)
        else:
            if q.kind == QuestKind.Daily:
                for quest in manager.quests:
                    if quest.kind == QuestKind.Daily and quest != q:
                        quest.pause()

            manager.saveChangesToProfile()
            return (newJObject(), StatusCode.OK)


questManagerCommands["getReward"] = proc(manager: QuestManager, questId: int): Future[tuple[resp:JsonNode, statusCode: StatusCode]] {.async.} =
    result = (newJObject(), StatusCode.OK)

    let rewards = manager.getRewardsAndRemoveIfCompleted(questId)
    if rewards.len != 0:
        await manager.profile.acceptRewards(rewards, result.resp)

    if manager.autogenerateSlotQuests:
        manager.generateSlotQuests()

    manager.onProfileChanged(manager.profile)
    manager.saveChangesToProfile()

    if questId == qttLevelUp.int and rewards.len != 0:
        let nextLvl = createLevelUpQuest(manager.profile)
        if not nextLvl.isNil:
            manager.profile.quests.add(nextLvl.toBson())

    let nextQuests = manager.nextQuestsAfter(questId)

    for q in nextQuests:
        var hasQuest = false
        for mq in manager.quests:
            if mq.id == q.id:
                hasQuest = true

        if not hasQuest:
            manager.profile.quests.add(q.toBson())
            manager.quests.add(q)

    manager.profile.quests = manager.profile.quests
    result.resp["boosters"] = manager.profile.boosters.stateResp()


questManagerCommands["speedUp"] = proc(manager: QuestManager, questId: int): Future[tuple[resp:JsonNode, statusCode: StatusCode]] {.async.} =
    result.resp = newJObject()
    let q = manager.questById(questId)
    if q.isNil:
        return (newJObject(), StatusCode.QuestNotFound)

    if q.kind != QuestKind.Daily and q.data[$qfStatus].toInt().QuestProgress notin [QuestProgress.InProgress, QuestProgress.GoalAchieved]:
        return (newJObject(), StatusCode.InvalidQuestState)

    result.resp = newJObject()

    if manager.speedUpPrice(q) > 0:   # 0 is for non-speedup-able tasks
        if manager.speedUpPrice(q) <= manager.profile.bucks:
            manager.profile.bucks = manager.profile.bucks - manager.speedUpPrice(q)
            await manager.speedUpQuest(questId)
            result.statusCode = StatusCode.OK
        else:
            result.statusCode = StatusCode.NotEnougthBucks
    else:
        result.statusCode = StatusCode.InvalidRequest

    manager.saveChangesToProfile()


questManagerCommands["pause"] = proc(manager: QuestManager, questId: int): Future[tuple[resp:JsonNode, statusCode: StatusCode]] {.async.} =
    result.resp = newJObject()
    manager.pauseQuest(questId)
    manager.saveChangesToProfile()
    result.statusCode = StatusCode.OK


questManagerCommands["complete"] = proc(manager: QuestManager, questId: int): Future[tuple[resp:JsonNode, statusCode: StatusCode]] {.async.} =
    let q = manager.questById(questId)
    if q.isNil:
        return (newJObject(), StatusCode.QuestNotFound)

    if q.data[$qfStatus].toInt().QuestProgress != QuestProgress.GoalAchieved:
        return (newJObject(), StatusCode.InvalidQuestState)

    manager.completeQuest(questId)
    if manager.autogenerateSlotQuests:
        manager.generateSlotQuests()
    manager.saveChangesToProfile()
    for k,v in manager.slotQuests:
        if v.questId == questId:
            v.questId = 0
            manager.saveChangesToProfile()
            break

    result = (newJObject(), StatusCode.OK)


questManagerCommands["generateTask"] = proc(manager: QuestManager, questId: int): Future[tuple[resp:JsonNode, statusCode: StatusCode]] {.async.} =
    # let q = manager.questById(questId)
    # if q.isNil:
    #     return StatusCode.QuestNotFound
    # discard manager.generateNextStageSlotQuest(q.tasks[0].target)
    return (newJObject(), StatusCode.OK)    # quests now are autogenerated


questManagerCommands["completeQuestWithDeps"] = proc(manager: QuestManager, qi: int): Future[tuple[resp:JsonNode, statusCode: StatusCode]] {.async.} =
    if qi - 1 >= manager.getStoryConfig().len:
        return (newJObject(), StatusCode.QuestNotFound)

    var targetConfig = manager.getStoryConfig()[qi - 1]

    var alldeps = newSeq[QuestConfig]()
    var deps = targetConfig.deps
    while deps.len > 0:
        var tdeps = deps
        deps.setLen(0)
        for qc in tdeps:
            deps.add(qc.deps)
            alldeps.add(qc)

    alldeps.add(targetConfig)

    var rewards = newSeq[Reward]()
    for qc in alldeps:
        if not manager.isQuestCompleted(qc.quest.id):
            case qc.currency:
                of Currency.Parts:
                    manager.profile.parts = manager.profile.parts - qc.price
                of Currency.TournamentPoint:
                    manager.profile.tourPoints = manager.profile.tourPoints - qc.price
                else:
                    return (newJObject(), StatusCode.InvalidQuestState)

            manager.markQuestAsCompleted(qc.quest.id)
            rewards.add(qc.rewards)
            manager.deleteQuestById(qc.quest.id)
            manager.profile.updateMapStateOnQuestComplete(qc)

    if manager.profile.parts < 0:
        return (newJObject(), StatusCode.NotEnougthParts)
    elif manager.profile.tourPoints < 0:
        return (newJObject(), StatusCode.NotEnougthTourPoints)

    let resp = newJObject()
    await manager.profile.acceptRewards(rewards, resp)

    manager.onProfileChanged(manager.profile)
    if manager.autogenerateSlotQuests:
        manager.generateSlotQuests()
    manager.saveChangesToProfile()

    result = (resp, StatusCode.OK)
