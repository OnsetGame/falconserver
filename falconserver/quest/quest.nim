## Quests-related logic

import quest_decl
export quest_decl

import quest_task
export quest_task

import falconserver.common.bson_helper
import times


proc onStoryStart*(quest: Quest, time: float, autoComplete: bool)=
    if quest.kind == QuestKind.Story:
        quest.data[$qfState][$qdfCompleteTime] = (epochTime() + time).toBson()
        quest.data[$qfState][$qdfAutoComplete] = autoComplete.toBson()


proc onStorySpeedUp*(quest: Quest)=
    if quest.kind == QuestKind.Story:
        quest.data[$qfState][$qdfCompleteTime] = (epochTime() - 1.0).toBson()

proc loadQuestData(quest: Quest, data: Bson = nil) =
    quest.data = newBsonDocument()
    for f in low(QuestFields) .. high(QuestFields):
        if not data{$f}.isNil:
            quest.data[$f] = data[$f]

proc loadQuest*(bson: Bson): Quest=
    result.new()
    result.loadQuestData(bson)

    var tasks = newSeq[QuestTask]()
    for t in result.data[$qfTasks]:
        tasks.add(loadTask(t, result.id))

    result.tasks   = tasks
    if not result.data[$qfKind].isNil:
        result.kind = result.data[$qfKind].int.QuestKind
    else:
        result.kind = QuestKind.Daily
        result.data[$qfKind] = result.kind.int.toBson()

proc timeToGoalAchieved*(quest: Quest): float=
    if quest.kind == QuestKind.Story and quest.isQuestActive():
        if not quest.data[$qfState][$qdfCompleteTime].isNil:
            result = quest.data[$qfState][$qdfCompleteTime].toFloat64().float

proc toBson*(quest: Quest): Bson=
    quest.data[$qfKind] = quest.kind.int.toBson()

    var tasks = newBsonArray()
    for t in quest.tasks:
        tasks.add(t.toBson())

    quest.data[$qfTasks] = tasks
    result = quest.data

proc isCompleted*(quest: Quest): bool=
    result = quest.data[$qfStatus].toInt().QuestProgress == QuestProgress.Completed

proc createQuest*(id: int, tasks: seq[QuestTask]): Quest=
    var data = newBsonDocument()
    data[$qfStatus] = QuestProgress.Ready.int32.toBson()
    data[$qfState]  = newBsonDocument()
    data[$qfId]     = id.toBson()
    data[$qfKind]   = 0.toBson()

    data[$qfTasks] = newBsonArray()
    for t in tasks:
        data[$qfTasks].add(t.toBson())

    result.new()
    result.loadQuestData(data)
    result.tasks   = tasks
