import json, oids, times, tables, boolseq, math

import nimongo.bson
import asyncdispatch

import falconserver / quest / [ quest, quest_manager, quests_config, quest_types ]
import falconserver / auth / profile_types
import falconserver / common / [ currency, message, game_balance ]
import falconserver / map / building / builditem
import falconserver / auth / profile
import falconserver / tutorial / tutorial_server
import falconserver / map / map
import falconserver / boosters / boosters
import falconserver / auth / profile_vip_helpers
import falconserver / free_rounds / free_rounds

var migrationProfileProc = newSeq[proc(dbProfile, emptyProfile: Profile): Future[Profile]](PROFILE_VERSION + 1)

proc resolveConflicts*(dbProfile, emptyProfile: Profile, oldVersion, currVersion: int): Future[Profile] {.async.} =
    result = dbProfile
    for i in oldVersion ..< currVersion:
        if not migrationProfileProc[i + 1].isNil:
            result = await migrationProfileProc[i + 1](result, emptyProfile)
            assert (not result.isNil)
            echo "migrationProc ", i + 1
            if result.version == currVersion:
                echo "migration done ", result.bson
                return result

proc closeAllTutorSteps(): BoolSeq =
    var ts = newBoolSeq("")
    for t in low(TutorialState) .. high(TutorialState):
        if t.int >= 0:
            if t.int >= ts.len:
                ts.setLen(t.int + 1)
            ts[t.int] = true

    result = ts

proc needRestoreTutorialForQuest(profile: Profile, questName: string): bool =
    let qid = profile.questIdFromName(questName)
    var questManager = newQuestManager(profile, autogenerateSlotQuests = false)
    if questManager.isQuestCompleted(qid):
        return false

    let quest = questManager.questById(qid)
    if not quest.isNil:
        if profile.gconf.progress(quest) == QuestProgress.Ready:
            return true
    else:
        return true

proc oldUserMigration(dbProfile, emptyProfile: Profile): Future[Profile] {.async.} =
    result = emptyProfile
    result[$prfId]      = dbProfile[$prfId]
    result[$prfDevices] = dbProfile[$prfDevices]
    result[$prfName]    = dbProfile[$prfName]
    result[$prfFBToken] = dbProfile[$prfFBToken]

migrationProfileProc[1] = oldUserMigration

migrationProfileProc[2] = oldUserMigration

migrationProfileProc[3] = oldUserMigration

migrationProfileProc[4] = oldUserMigration

migrationProfileProc[5] = oldUserMigration


migrationProfileProc[6] = oldUserMigration

migrationProfileProc[7] = proc(dbProfile, emptyProfile: Profile): Future[Profile] {.async.} =
    const removedQuestsIds = [32, 66, 91, 125]
    if not dbProfile.quests.isNil:
        var migQuests = newBsonArray()
        for bq in dbProfile.quests:
            let id = bq["i"].toInt32()
            if id in removedQuestsIds:
                continue
            migQuests.add(bq)

        dbProfile.quests = migQuests

    result = dbProfile

migrationProfileProc[8] = proc(dbProfile, emptyProfile: Profile): Future[Profile] {.async.} =
    let chipsKey = "lct_" & $Currency.Chips
    let bucksKey = "lct_" & $Currency.Bucks

    let clientState = dbProfile[$prfState]
    if clientState.isNil:
        return dbProfile

    if "gasStation" in clientState:
        var lastCollect = 0.0
        let bi1 = clientState["gasStation"].toBuildItem()
        lastCollect = bi1.lastCollectionTime
        if "gasStation_2" in clientState:
            let bi2 = clientState["gasStation_2"].toBuildItem()
            lastCollect = min(lastCollect, bi2.lastCollectionTime)
        dbProfile.setClientState(bucksKey, lastCollect.toBson())

    if "restaurant" in clientState:
        var lastCollect = 0.0
        let bi1 = clientState["restaurant"].toBuildItem()
        lastCollect = bi1.lastCollectionTime
        if "restaurant_2" in clientState:
            let bi2 = clientState["restaurant_2"].toBuildItem()
            lastCollect = min(lastCollect, bi2.lastCollectionTime)
        dbProfile.setClientState(chipsKey, lastCollect.toBson())

    result = dbProfile


migrationProfileProc[9] = proc(dbProfile, emptyProfile: Profile): Future[Profile] {.async.} =
    let oldStageData = dbProfile{$prfTaskStageOld}
    if oldStageData.isNil:
        echo "No old stage data"
        return dbProfile

    var slots = dbProfile.slotsBuilded()
    if dreamTowerSlot notin slots:
        slots.add dreamTowerSlot

    # fix invalid initial_slot, assigned to locked slot
    if not dbProfile{$prfState}{"initial_slot"}.isNil:
        let initSlot = dbProfile[$prfState]["initial_slot"].toInt().BuildingId
        if initSlot notin slots:
            dbProfile[$prfState]["initial_slot"] = dreamTowerSlot.int.toBson()
            dbProfile[$prfState] = dbProfile[$prfState]
            echo "initSlot ", initSlot, " is locked, changing to ", dbProfile[$prfState]["initial_slot"].toInt().BuildingId

    var oldStageLevel = if oldStageData{"stage"}.isNil: 0  else: oldStageData{"stage"}.toInt32()
    let oldStageIsDone = not oldStageData{"done"}.isNil and oldStageData{"done"}.toBool()
    if oldStageIsDone:
        oldStageLevel += 1 - slots.len.int32  # because we will generate quests for all slots afterwards, each slot stage will be increased
    echo "Converting quest stage with old level ", oldStageLevel, ", ", slots.len, " unlocked slots and done = ", oldStageIsDone, ",  target level => ", oldStageLevel

    var questManager = newQuestManager(dbProfile, autogenerateSlotQuests = false)

    var maxSpinsSlot: BuildingId
    var maxSpins = -1.int64
    var newStageLevelSum = 0

    for target in slots:
        let slotSpins = dbProfile.totalSpinsOnSlot($target)
        let slotQuest = new SlotQuest
        slotQuest.stage = max( round(((slotSpins.float - 8.0) / 12.0).pow(5.0/6.0)).int,  0 )
        echo "Converting quest stage for ", target, " with ", slotSpins, " spins  =>  stage = ", slotQuest.stage
        newStageLevelSum += slotQuest.stage
        slotQuest.questId = 0
        questManager.slotQuests[target] = slotQuest
        if slotSpins > maxSpins:
            maxSpinsSlot = target
            maxSpins = slotSpins

    var scaledStageLevelSum = 0
    let ratio = (oldStageLevel + slots.len) / (newStageLevelSum + slots.len)  # for calculations on _active_, not _completed_ stages (and to work with newStageLevelNum == 0)
    for k, v in questManager.slotQuests:
        v.stage = max(round((v.stage + 1).float * ratio).int - 1, 0)
        echo "Scaling quest stage for ", k, " by ", oldStageLevel + slots.len, "/", newStageLevelSum + slots.len, "  =>  stage = ", v.stage
        scaledStageLevelSum += v.stage

    questManager.slotQuests[maxSpinsSlot].stage += oldStageLevel - scaledStageLevelSum
    questManager.slotQuests[maxSpinsSlot].stage = max(questManager.slotQuests[maxSpinsSlot].stage, 0)
    echo "Correcting quest stage for ", maxSpinsSlot, " to ", oldStageLevel, " - ", scaledStageLevelSum, "  =>  stage = ", questManager.slotQuests[maxSpinsSlot].stage

    let oldTasks = dbProfile{$prfTaskStageOld, "tasks"}
    if not oldTasks.isNil:
        for v in oldTasks:
            let questId = v.toInt32()
            let quest = questManager.questById(questId)
            if not quest.isNil and quest.tasks.len > 0:
                let target = quest.tasks[0].target
                if target in questManager.slotQuests and questManager.slotQuests[target].questId == 0:
                    questManager.slotQuests[target].questId = questId
                else:
                    questManager.cheatDeleteQuestById(questId)

    questManager.saveChangesToProfile()

    result = dbProfile

    #complete all tutorial steps
    var ts = closeAllTutorSteps()
    result.tutorialState = binuser(ts.string)


migrationProfileProc[10] = proc(dbProfile, emptyProfile: Profile): Future[Profile] {.async.} =
    result = dbProfile
    #complete all tutorial steps
    var ts = closeAllTutorSteps()

    if dbProfile.needRestoreTutorialForQuest("gasStation_restore"):
        ts[tsGasStationQuestAvailble.int] = false
        ts[tsGasStationCollectRes.int] = false

    if dbProfile.needRestoreTutorialForQuest("bank_restore"):
        ts[tsBankQuestAvailble.int] = false
        ts[tsBankFeatureBttn.int] = false
        ts[tsBankWinExchangeBttn.int] = false
        ts[tsBankWinClose.int] = false

    if dbProfile.needRestoreTutorialForQuest("candySlot_build"):
        ts[tsCandyQuestAvailble.int] = false
        ts[tsMapPlayCandy.int] = false

    result.tutorialState = binuser(ts.string)
    result[$prfMessages] = newBsonArray()


proc needUpdateTutorialForBoosters(profile: Profile, questName: string): bool =
    let qid = profile.questIdFromName(questName)
    var questManager = newQuestManager(profile, autogenerateSlotQuests = false)
    if questManager.isQuestCompleted(qid):
        return true

    let quest = questManager.questById(qid)
    if not quest.isNil:
        if profile.gconf.progress(quest) > QuestProgress.None:
            return false
    return true

migrationProfileProc[11] = proc(dbProfile, emptyProfile: Profile): Future[Profile] {.async.} =
    result = dbProfile

    result.tutorialState = dbProfile.completeTutorialState(tsBankQuestReward)
    if dbProfile.needUpdateTutorialForBoosters("cityHall_restore"):
        result.tutorialState = dbProfile.completeTutorialState(tsBoosterQuestAvailble)
        waitfor result.boosters.add($btExperience, 24 * 60 * 60, true)


migrationProfileProc[12] = proc(dbProfile, emptyProfile: Profile): Future[Profile] {.async.} =
    result = dbProfile

    if dbProfile.vipLevel > 0:
        let msg = newMessage("vip_level_compensation")
        msg.data["oldVipLvl"] = newJInt(0)
        msg.data["newVipLvl"] = newJInt(dbProfile.vipLevel)

        result[$prfMessages] = result[$prfMessages]
        result[$prfMessages].add(msg.toBson())
        await result.gainVipLevelRewards(0.int, dbProfile.vipLevel.int, newJObject())


migrationProfileProc[13] = proc(dbProfile, emptyProfile: Profile): Future[Profile] {.async.} =
    result = dbProfile

    if $prfQuests in result:
        var bqs = result[$prfQuests]
        for bq in bqs:
            if $qfTasks in bq:
                for bt in bq[$qfTasks]:
                    let kind = bt[$qtfType].toString()
                    if kind == "ho":
                        bt[$qtfType] = "h0".toBson()

migrationProfileProc[14] = proc(dbProfile, emptyProfile: Profile): Future[Profile] {.async.} =
    result = dbProfile

    let qman = newQuestManager(result)
    let vipConfig = result.gconf.getGameBalance().vipConfig

    if dbProfile.vipLevel >= 3: # Add access to UFO
        var vipAccess = vipConfig.levels[3].getReward(RewardKind.vipaccess)
        if not vipAccess.isNil:
            let zoneReward = vipAccess.ZoneReward
            qman.gainVipAccess(zoneReward.zone)

    if dbProfile.vipLevel >= 6: # Add access to Magic Matters
        var vipAccess = vipConfig.levels[6].getReward(RewardKind.vipaccess)
        if not vipAccess.isNil:
            let zoneReward = vipAccess.ZoneReward
            qman.gainVipAccess(zoneReward.zone)

    var cardsSlotFreeRounds = 0

    if dbProfile.vipLevel >= 4:
        cardsSlotFreeRounds += 25
    if dbProfile.vipLevel >= 5:
        cardsSlotFreeRounds += 50

    if cardsSlotFreeRounds > 0:
        let freeRounds = await result.id.getOrCreateFreeRounds()
        freeRounds.addFreeRounds("cardSlot", cardsSlotFreeRounds)
        await freeRounds.save()

proc validateProfile*(dbProfile: Profile): Future[Profile] {.async.} =
    result = dbProfile
    let emptyProfile = newProfile(dbProfile.collection)

    var oldVersion = dbProfile.version
    let currVersion = emptyProfile.version

    if oldVersion != currVersion:
        result = await resolveConflicts(dbProfile, emptyProfile, oldVersion, currVersion)
        result.version = emptyProfile.version


