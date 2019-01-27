## Quest Generator for Falcon Players
import json
import falconserver.auth.profile_random
import sequtils
import strutils
import tables
import math
import nimongo.bson
import times

import falconserver.auth.profile_types
import falconserver.auth.profile
import falconserver.map.building.builditem
import falconserver.map.map
import falconserver.common / [ game_balance, get_balance_config ]
import falconserver.quest.quest
import falconserver.quest.quest_task
import falconserver.quest.quest_types
import falconserver.quest.quests_config

import shafa.game.feature_types


# template logQuests*(args: varargs[untyped]) =
#     echo "[quests]:  ", args


proc generateQuestTaskForSlot(p: Profile, target: BuildingId, stage: int): QuestTask =
    let dgc = p.getDailyConfig()
    let stageConfig = dgc.stageConfig(target, stage)
    #logQuests "generateQuestTaskForSlot ", target, " @ ", stage, " => stage config is difficulty = ", stageConfig.difficulty, ", taskType = ", stageConfig.taskType
    #var slotTasks = dgc.allAvailableTasksForSlot(target, p.level, stageConfig.difficulty)
    var slotTasks = dgc.allAvailableTasksForSlotStage(target, stage, p.level)
    if slotTasks.len > 0:
        result = slotTasks[p.random(slotTasks.len)]


proc generateSlotQuest*(profile: Profile, target: BuildingId): tuple[stage: int, quest: Quest] =
    var slotQuests = profile.slotQuests
    if slotQuests.isNil:
        slotQuests = newBsonDocument()

    var slotQuest = slotQuests{$target}
    if slotQuest.isNil:
        slotQuest = newBsonDocument()
        slotQuests{$target} = slotQuest

    var stageLevel = if slotQuest{"s"}.isNil: 0 else: slotQuest{"s"}.toInt32
    let task = profile.generateQuestTaskForSlot(target, stageLevel)
    assert(not task.isNil)
    inc stageLevel
    slotQuest["s"] = stageLevel.toBson()

    let dgc = profile.getDailyConfig()
    var quest = createQuest(profile.questsGenId, @[task])
    quest.kind = QuestKind.Daily
    profile.questsGenId = profile.questsGenId + 1

    slotQuest["q"] = quest.id.toBson()

    profile.slotQuests = slotQuests
    result.stage = stageLevel
    result.quest = quest


proc generateTaskForCheat*(profile: Profile, target: BuildingId, qtt: QuestTaskType, qCounter: int): Quest=
    var activeSlots = @[target]
    let plLevel = profile.level - 1
    let config = profile.getDailyConfig()
    let allTasks = config.tasks
    echo "generateTaskForCheat ", target, " qtt ", qtt
    for difficulty, tasks in allTasks:
        let levelTasks = tasks[clamp(plLevel, 0, tasks.len)]
        echo "generateTaskForCheat at level ", plLevel
        for lt in levelTasks:
            echo lt.target, "\t", difficulty, "\t", lt.kind
            if lt.kind == qtt and lt.progresses[0].total > 0'u64 and lt.target == target:
                result = createQuest(qCounter, @[lt])
                result.kind = QuestKind.Daily
                echo " task generated ", qtt, " for ", plLevel
                return
