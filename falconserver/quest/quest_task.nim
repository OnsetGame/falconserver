import quest_task_decl
export quest_task_decl

import nimongo.bson
import json
import falconserver.map.building.builditem
import times, tables, strutils
import falconserver.auth.profile_types
import falconserver.common.game_balance
import quest_types

import falconserver.auth.gameplay_config_decl

var progressDBWorkers* = initTable[QuestTaskType, proc(gconf: GameplayConfig, qt: QuestTask, data: Bson)]()
var progressResponseWorkers* = initTable[QuestTaskType, proc(gconf: GameplayConfig, qt: QuestTask, data: JsonNode)]()

proc toBson*(qt: QuestTask): Bson=
    result = newBsonDocument()
    result[$qtfType] = ($qt.kind).toBson()
    result[$qtfObject] = ($qt.target).toBson()
    result[$qtfProgress] = newBsonArray()
    result[$qtfDifficulty] = qt.difficulty.int.toBson()

    if qt.prevStage.len > 0:
        result[$qtfStage] = qt.prevStage.toBson()

    for tp in qt.progresses:
        var btp = newBsonDocument()
        btp[$qtfCurrentProgress] = tp.current.int64.toBson()
        btp[$qtfTotalProgress] = tp.total.int64.toBson()
        btp[$qtfProgressIndex] = tp.index.int.toBson()
        result[$qtfProgress].add(btp)

proc loadTask*(data: Bson, id: int): QuestTask =
    if not data.isNil():
        result.new()
        result.kind = parseQuestTaskType(data[$qtfType].toString(), id)
        result.target = parseEnum[BuildingId](data[$qtfObject].toString())
        result.progresses = @[]
        if $qtfProgress in data:
            for bp in data[$qtfProgress]:
                var tp = new(TaskProgress)
                tp.current = bp[$qtfCurrentProgress].toInt64().uint64
                tp.total = bp[$qtfTotalProgress].toInt64().uint64
                tp.index = bp[$qtfProgressIndex].toInt32().uint
                result.progresses.add(tp)

        if not data{$qtfDifficulty}.isNil:
            result.difficulty = data[$qtfDifficulty].toInt32().DailyDifficultyType

        if not data{$qtfStage}.isNil:
            result.prevStage = data[$qtfStage].toString()

proc createTask*(t: QuestTaskType, taskTotalProgs: seq[int | int32 | int64], target: BuildingId, diff: DailyDifficultyType = trivial): QuestTask =
    result.new()
    result.kind   = t
    result.target = target
    result.progresses = @[]
    result.difficulty = diff

    for i, p in taskTotalProgs:
        var taskP = new(TaskProgress)
        taskP.index = i.uint
        taskP.current = 0
        taskP.total = p.uint64
        result.progresses.add(taskP)

proc currentProgress*(t: QuestTask): float =
    var n = 0
    for p in t.progresses:
        if p.total != 0:
            result += p.current.int / p.total.int
            inc n
    if n != 0:
        result /= n.float

proc setCurrentProgress*(t: QuestTask, p: uint64|int64|int, index: uint = 0) =
    for tp in t.progresses:
        if tp.index == index:
            if tp.current != p.uint64:
                tp.current = p.uint64
                t.progressState = qtpHasProgress

            if tp.current >= tp.total:
                tp.current = tp.total
                t.progressState = qtpCompleted
            break

proc completeProgress*(t: QuestTask, index: uint = 0)=
    for tp in t.progresses:
        if tp.index == index:
            tp.current = tp.total
            t.progressState = qtpCompleted
            break

proc incProgress*(t: QuestTask, amount: uint64|int64|int, index: uint = 0) =
    var taskP: TaskProgress
    for tp in t.progresses:
        if tp.index == index:
            taskP = tp
            break

    if not taskP.isNil:
        t.setCurrentProgress(taskP.current + amount.uint64, index)


proc progress*(gconf: GameplayConfig, t: QuestTask, data: Bson): QuestTaskProgress=
    if t.currentProgress() >= 1.0 and (t.prevStage.len == 0 or t.prevStage == "Spin"):
        result = qtpCompleted
    else:
        let progressDbWorker = progressDBWorkers.getOrDefault(t.kind)
        if not progressDbWorker.isNil:
            gconf.progressDbWorker(t, data)

        result = t.progressState


proc getCurrentStage*(t: QuestTask, data: JsonNode): string=
    let resp = data["res"]
    var stages = resp{"stages"}
    if not stages.isNil and stages.len > 0:
        result = stages[0]["stage"].getStr()
        var fc = -1

        if "fc" in resp:
            fc = resp["fc"].getInt()

        elif "freeSpinsCount" in resp: # balloon slot
            fc = resp["freeSpinsCount"].getInt()

        if result == "FreeSpin" or fc > 0:
            var lastFsC = 1
            if t.target in [candySlot, witchSlot]:
                lastFsC = 0

            if fc == lastFsC:
                result = "Spin"
            else:
                result = "FreeSpin"

        elif result == "Bonus": #hello balloon slot
            result = "Spin"
    else:
        result = "Spin"

proc registerTask*(qtt: QuestTaskType, callback:proc(gconf: GameplayConfig, qt: QuestTask, data: Bson))=
    progressDBWorkers[qtt] = callback

proc registerTask*(qtt: QuestTaskType, callback:proc(gconf: GameplayConfig, qt: QuestTask, data: JsonNode))=
    progressResponseWorkers[qtt] = callback
