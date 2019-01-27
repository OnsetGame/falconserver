const writePersonalTasksLog = false

import json, logging

import oids
import sequtils
import strutils
import tables
import times
import os except DeviceId
import nuuid

import nimongo.bson
import nimongo.mongo

import falconserver / common / [db, config, bson_helper]

import asyncdispatch


proc taskLogDescr(task: Bson): string =
    let j = task.toJson()
    $j


var disableSchedule = getEnv("FALCON_DISABLE_SCHEDULE").len > 0
if disableSchedule:
    echo "Scheduling disabled."



type TaskFields* = enum
    tfTime = "t"
    tfRunTime = "rt"
    tfCommand = "c"
    tfProfile = "p"


var taskHandlers = newTable[string, proc(args: Bson): Future[float]]()
var regularTasks = newSeq[string]()

proc scheduleDB(): Collection[AsyncMongo] =
    result = sharedDB()["schedule"]

proc registerScheduleTask*(command: string, handler: proc(args: Bson): Future[float], regular: bool = false) =
    if disableSchedule: return
    if command in taskHandlers:
        echo "Warning: schedule task '", command, "' is already registered"
    echo "Registering schedule task '", command, "'"
    taskHandlers[command] = handler
    if regular:
        regularTasks.add(command)


proc scheduleTask*(time: float, command: string, args: Bson): Future[void] {.async.} =
    if disableSchedule: return
    args[$tfTime] = bson.`%*`(time)
    args[$tfCommand] = bson.`%*`(command)
    args[$tfRunTime] = bson.`%*`(0)
    if shouldLogSchedule():
        if writePersonalTasksLog or $tfProfile notin args:
            logSchedule "Scheduling task ", args.toJson()
    discard await scheduleDB().insert(args)


proc rescheduleTask*(command: string, args: Bson, newTime: float, moveOnlyCloser: bool = true): Future[void] {.async.} =
    if disableSchedule: return
    args[$tfCommand] = bson.`%*`(command)
    var findRequest = args
    if $tfProfile notin findRequest:
        deepCopy findRequest, args
        findRequest[$tfProfile] = bson.`%*`({"$exists": false})
    let record = await scheduleDB().find(findRequest).oneOrNone()
    if record.isNil:
        await scheduleTask(newTime, command, args)
    else:
        if shouldLogSchedule():
            if writePersonalTasksLog or $tfProfile notin args:
                logSchedule "Rescheduling task ", args.toJson()
        let filter = bson.`%*`({ "_id": record["_id"] })
        # with moveOnlyCloser, we reschedule task only if <newTime> is closer, not if more distant
        if moveOnlyCloser:
            filter["$or"] = bson.`%*`([
                { $tfTime: 0 },
                { $tfTime: { "$gt": newTime } }
            ])
        discard await scheduleDB().update( filter,
                                           bson.`%*`( { "$set": { $tfTime: newTime } } ),
                                           multi = false, upsert = false )


proc scheduleRegularTask*(command: string) {.async.} =
    if disableSchedule: return
    let tasksCount = await scheduleDB().find(bson.`%*`({$tfCommand: command, $tfProfile: {"$exists": false}})).count()
    if tasksCount == 0:
        logSchedule "Scheduling new task '", command, "' for ", epochtime()
        await scheduleTask( 1, command, bson.`%*`({}) )


proc rescheduleAfterProcessing(task: Bson, nextTime: float): Future[bool] {.async.} =
    assert(not disableSchedule)
    let rescheduled = await scheduleDB().update( bson.`%*`({
                                                     "_id": task["_id"],
                                                     $tfRunTime: task[$tfRunTime],
                                                     "$or": [
                                                         { $tfTime: task[$tfTime] },
                                                         { $tfTime:{ "$gt": nextTime } },
                                                     ] }),
                                                 bson.`%*`({ "$set": { $tfTime: nextTime, $tfRunTime: 0 } } ),
                                                 multi = false, upsert = false )
    result = rescheduled.ok and rescheduled.n == 1
    if result:
        task[$tfTime] = nextTime.toBson()
        task[$tfRunTime] = 0.toBson()
    else:
        logSchedule "Task '", task[$tfCommand].taskLogDescr(), "' was not rescheduled to ", nextTime
        let released = await scheduleDB().update( bson.`%*`({ "_id": task["_id"], $tfRunTime: task[$tfRunTime] }),
                                                  bson.`%*`({ "$set": { $tfRunTime: 0 } }),
                                                  multi = false, upsert = false )
        result = released.ok and released.n == 1


proc grabNextTask(): Future[Bson] {.async.} =
    assert(not disableSchedule)
    let curTime = epochTime()
    let executionDeadline = curTime - 60

    let response = await scheduleDB().findAndModify(
        selector = bson.`%*`({ $tfTime: { "$gt": 0, "$lt": curTime },
                               $tfRunTime: { "$lt": executionDeadline } }),  # also works for runTime == 0 (not handled yet)
        sort = bson.`%*`({ $tfTime: 1 }),
        update = bson.`%*`({ "$set": { $tfRunTime: curTime } } ),
        afterUpdate = true, upsert = false)

    result = response.bson{"value"}
    if not result.isNil and result.kind == BsonKindNull:
        result = nil
    if not result.isNil:
        let launchDelay = result[$tfTime].toFloat64() - curTime
        if launchDelay >= sharedGameConfig().logs.scheduleDelayWarningT:
            warn "Task ", result.toJson(), " is ", launchDelay, "s late"


proc processTask(task: Bson): Future[void] {.async.} =
    assert(not disableSchedule)
    var command = task[$tfCommand]
    #logSchedule "Processing task '", command, "'"

    var span = 0.float
    let t0 = epochTime()
    if command in taskHandlers:
        if shouldLogSchedule():
            if writePersonalTasksLog or $tfProfile notin task:
                logSchedule "Processing task ", task.taskLogDescr()

        span = await taskHandlers[command](task)

        if shouldLogSchedule():
            if writePersonalTasksLog or $tfProfile notin task:
                logSchedule "Finished processing task ", task.taskLogDescr(), " in ", formatFloat(epochTime() - t0, format = ffDecimal, precision = 3), "s"

        assert(span >= 0)
    else:
        logSchedule "Warning: unknown schedule task '", command, "'"

    if span > 0:
        logSchedule "Rescheduling task ", command, " to +", span.int, " seconds"
        # If task implementation used own epochtime() value, we want to schedule it a bit later, not earlier.
        # For that reason we call epochtime() again, not using our currentTime value.
        if not await task.rescheduleAfterProcessing(epochtime() + span):
            logSchedule "Rescheduling task failed: ", task.taskLogDescr()

    elif command in regularTasks:
        logSchedule "Rescheduling task ", command, " to 0"
        if not await task.rescheduleAfterProcessing(0):
            logSchedule "Rescheduling task failed: ", task.taskLogDescr()

    else:
        logSchedule "Removing task ", command
        let removed = await scheduleDB().remove( bson.`%*`( { "_id": task["_id"], $tfTime: task[$tfTime], $tfRunTime: task[$tfRuntime] } ) )
        if not removed.ok or removed.n != 1:
            logSchedule "Removing task failed: ", task.taskLogDescr()



proc runScheduleProcessing*() {.async.} =
    if disableSchedule: return

    const delays = [1, 500, 1_000, 2_000]
    var delayIndex = delays.len - 1

    for task in regularTasks:
        await scheduleRegularTask(task)

    while true:
        let task = await grabNextTask()
        if not task.isNil:
            delayIndex = 0
            await task.processTask()
        else:
            delayIndex = min(delayIndex + 1, delays.len - 1)
        await sleepAsync(delays[delayIndex])
