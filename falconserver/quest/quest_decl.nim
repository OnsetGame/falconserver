import quest_task_decl
export quest_task_decl

import quest_types
export quest_types

import nimongo.bson


type
    Quest* = ref object of RootObj
        ## Quest - a task for a player to fulfill in order to get
        ## some `Reward`.
        data*: Bson
        tasks*: seq[QuestTask]
        # rewards*: seq[QuestReward] ## todo: move rewards into task
        kind*: QuestKind


proc id*(quest: Quest): int =
    result = quest.data[$qfId].toInt()


proc isQuestActive*(quest: Quest): bool =
    let qProg = quest.data[$qfStatus].toInt().QuestProgress
    result = qProg == QuestProgress.InProgress or
        (quest.kind == QuestKind.LevelUp ) #and (qProg != QuestProgress.GoalAchieved or qProg != QuestProgress.Completed)
