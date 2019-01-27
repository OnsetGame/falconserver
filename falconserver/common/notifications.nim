import json, logging, oids, sequtils, strutils, tables, times, asyncdispatch
import os except DeviceId

import nimongo / [ bson, mongo ]

import falconserver / [ schedule ]
import falconserver / auth / [ profile_types, profile ]
import falconserver / common / [ db, bson_helper, stats, config, staging ]

const minT = 60.0
const hourT = 60 * minT
const dayT = 24 * hourT


let instantNotifications = isStage
let speedupNotifications = getEnv("FALCON_SPEEDUP_NOTIFICATIONS").len > 0
let speedupNoSeeNotifications = getEnv("FALCON_SPEEDUP_NOTIFICATIONS").len > 0

var disableNotifications* = getEnv("FALCON_DISABLE_NOTIFICATIONS").len > 0
if disableNotifications:
    echo "Notifications disabled."


const nfList = "list"
const nfSent = "sent"


proc notificationsDB(): Collection[AsyncMongo] =
    result = sharedDB()["notifications"]

type NotificationId* = enum
    nidUnknown = 0
    nidBuildComplete = 1
    nidUpgradeComplete = 2
    nidRestarauntFull = 3
    nidGasStationFull = 4

    nidLongTimeNoSee1D = 6
    nidLongTimeNoSee3D = 7
    nidLongTimeNoSee7D = 8
    nidLongTimeNoSee30D = 9

    nidTournamentFinished = 12
    nidFortuneWhellFreeSpinAvailable = 14
    nidDailyGiftReceived = 16
    nidInviteGiftReceived = 17

    nidLongTimeNoSee2D = 21
    nidLongTimeNoSee14D = 22
    nidLongTimeNoSee4D = 23
    nidLongTimeNoSee5D = 24
    nidLongTimeNoSee6D = 25

    nidLongTimeNoSee30H_Wheel = 26

    nidBoostLeft12H = 27
    nidBoostLeft1H = 28


type NotificationResponse* = tuple [
    text: string,
    nextTime: float,
    id: NotificationId,
    deepLink: string
]


var notificationHandlers = newTable[string, proc(p: Profile, args: Bson): Future[NotificationResponse]]()

proc registerNotificationHandler(tag: string, handler: proc(p: Profile, args: Bson): Future[NotificationResponse]) =
    if tag in notificationHandlers:
        echo "Warning: notification handler '", tag, "' is already registered"
    echo "Registering notification handler '", tag, "'"
    notificationHandlers[tag] = handler


proc cancelNotification(tag: string, profileID: Oid, args: Bson) {.async.} =
    if disableNotifications: return
    args["tag"] = tag.toBson()
    discard await notificationsDB().update( bson.`%*`({ "_id": profileID }),
                                            bson.`%*`({"$pull": { nfList: args }}),
                                            multi = false, upsert = true)
    # logNotifications "cancelled notification: ", (await notificationsDB().find(bson.`%*`({ "_id": profileID })).oneOrNone()).toJson()
    if shouldLogNotifications():
        let checkB = await notificationsDB().find(bson.`%*`({ "_id": profileID })).oneOrNone()
        logNotifications "cancelled notification: ", checkB.toJson()


proc scheduleNotification(tag: string, nid: NotificationId, time: float, profileID: Oid, args: Bson) {.async.} =
    if disableNotifications: return
    await cancelNotification(tag, profileID, args)
    args["tag"] = tag.toBson()
    args["t"] = time.toBson()
    if nid != nidUnknown:
        args["n"] = ord(nid).toBson()
    discard await notificationsDB().update( bson.`%*`({ "_id": profileID }),
                                            bson.`%*`({"$push": { nfList: args }}),
                                            multi = false, upsert = true)
    await rescheduleTask("notification", bson.`%*`({ "p": profileID }), time)
    #logNotifications "scheduled notification: ", (await notificationsDB().find(bson.`%*`({ "_id": profileID })).oneOrNone()).toJson()
    if shouldLogNotifications():
        let checkB = await notificationsDB().find(bson.`%*`({ "_id": profileID })).oneOrNone()
        logNotifications "scheduled notification: ", checkB.toJson()


proc getSentTime(data: Bson, limitPerDay: int): seq[float] =
    let sentB = data[nfSent]
    var sentT: seq[float]
    if sentB.isNil:
        sentT = @[]
    else:
        sentB.bsonToSeq(sentT)

    if sentT.len > limitPerDay:
        sentT = sentT[sentT.len - limitPerDay..^1]
    else:
        while sentT.len < limitPerDay:
            sentT.insert 0
    result = sentT


proc getAllowedNotificationTime(p: Profile, curT: float, sentT: seq[float], cfg: NotificationsConfig): float =
    if instantNotifications:
        return curT

    let localT = fromSeconds(curT - p.timeZone.float).getGMTime()
    var localH: int = localT.hour
    if localH >= cfg.sleepHour:
        localH -= 24
    #echo "localH = ", localH, ",  localT.minute = ", localT.minute, ",  localT.second = ", localT.second
    if localH < cfg.wakeHour:
        return curT  +  ((cfg.wakeHour - 1 - localH) * 60*60  +  (59 - localT.minute) * 60  +  (60 - localT.second)).float

    let nextDayT = sentT[0]  +  (if speedupNotifications: 5*minT  else: 24*hourT)
    if curT < nextDayT:
        #echo "[", epochtime(), "] - 24h limit"
        return nextDayT

    let nextSendingT = sentT[^1]  +  (if speedupNotifications: 1*minT  else: cfg.minSendingInterval.float)
    if curT < nextSendingT:
        #echo "[", epochtime(), "] - 1h limit"
        return nextSendingT

    let inactivityT = p.statistics.lastRequestTime  +  (if speedupNotifications:  30.0  else:  cfg.logoutInactivityTime.float)
    if curT < inactivityT:
        #echo "last request time limit"
        return inactivityT

    return curT


proc notificationPriority(data: Bson, cfg: NotificationsConfig): int =
    var nid = if "n" notin data:  nidUnknown.int  else:  data["n"].int
    result = find(cfg.priorities, nid)
    if result < 0:
        result = max(cfg.priorities) + 1


proc pickNotificationToSend(data: Bson, curT: float, cfg: NotificationsConfig): Bson =
    let listB = data[nfList]
    if listB.isNil:
        echo "no messages"
        return

    for item in listB:
        let itemT = item["t"].float
        if itemT <= curT:
            if result.isNil:
                result = item
            elif notificationPriority(item, cfg) < notificationPriority(result, cfg):
                result = item
            elif notificationPriority(item, cfg) == notificationPriority(result, cfg) and itemT < result["t"].float:
                result = item


proc nextNotificationTime(data: Bson, curT: float): float =
    let listB = data[nfList]
    if not listB.isNil:
        for i in listB:
            let t = i["t"].float
            if t > curT:
                if t < result or result == 0:
                    result = t


proc removeAllNotifications*(p: Profile): Future[void] {.async.} =
    discard await notificationsDB().remove(bson.`%*`({"_id": p.id}))


proc findDistanceToNearestNotification(data: Bson, curT: float, sentT: seq[float], p: Profile): Future[float] {.async.} =
    let nextT = nextNotificationTime(data, curT)
    if nextT == 0:
        logNotifications "No notifications for ", p.id, " left to send, removing DB record"
        await p.removeAllNotifications()
        return 0
    else:
        logNotifications "Next notification for ", p.id, ", will be in ", nextT - curT, " sec"
        return getAllowedNotificationTime(p, nextT, sentT, sharedGameConfig().notifications) - curT


proc cleanupNotifications*(p: Profile, untilT: float): Future[void] {.async.} =
    if disableNotifications: return
    logNotifications "cleanupNotifications for ", p.id, " until T ", untilT
    let data = await notificationsDB().find(bson.`%*`({"_id": p.id})).oneOrNone()
    if data.isNil:
        return

    discard await notificationsDB().update( bson.`%*`({ "_id": p.id }),
                                            bson.`%*`({
                                                "$pull": { nfList: { "t" : { "$lt": untilT } } },
                                                "$unset": { nfSent: "" }
                                            }),
                                            multi = false, upsert = false )

    let nearestDT = await findDistanceToNearestNotification(data, untilT, @[0.0, 0.0], p)
    if nearestDT > 0:
        await rescheduleTask("notification", bson.`%*`({ "p": p.id }), untilT + nearestDT)

proc sendAppToUserNotification*(p: Profile, message: string, id: NotificationId, deepLink: string): Future[int] {.async.} =
    ## Sends push notification to every platform player uses (facebook, android).
    ## Returns the number of platfroms that notification was successfully posted to.

    let nRef = $ord(id)
    if result != 0:
        await reportPushNotificationSent(nRef)


proc onSendNotification*(args: Bson): Future[float] {.async.} =
    if disableNotifications: return 0.0
    let p = await findProfile(args["p"])
    if p.isNil:
        return 0

    let data = await notificationsDB().find(bson.`%*`({"_id": p.id})).oneOrNone()
    if data.isNil:
        return 0

    let cfg = sharedGameConfig().notifications

    let curT = epochtime()
    var sentT = getSentTime(data, cfg.limitPerDay)

    let allowedSendT = getAllowedNotificationTime(p, curT, sentT, cfg)
    if allowedSendT > curT:
        logNotifications "allowedSentT = ", allowedSendT, ",  curT = ", curT
        return allowedSendT - curT

    let notification = pickNotificationToSend(data, curT, cfg)
    if notification.isNil:
        let distanceToNearest = await findDistanceToNearestNotification(data, curT, sentT, p)
        logNotifications "distanceToNearest = ", distanceToNearest
        return distanceToNearest

    var response: NotificationResponse

    let tag = notification["tag"]
    if tag in notificationHandlers:
        response = await notificationHandlers[tag](p, notification)
    else:
        echo "Warning: Unknown notification '", tag, "'"

    logNotifications "Sending to ", p.id, " notification text = '", response.text, "', nextTime = ", response.nextTime

    if response.text.len == 0:
        if response.nextTime == 0:
            echo "Warning: No notification content for '", tag, "'"
    else:
        discard await p.sendAppToUserNotification(response.text, response.id, response.deepLink)
        sentT = sentT[1..^1]
        sentT.add(curT)

    discard await notificationsDB().update( bson.`%*`({ "_id": p.id }),
                                            bson.`%*`({
                                                "$pull": { nfList: notification },
                                                "$set": { nfSent: sentT },
                                            }),
                                            multi = false, upsert = false )

    if response.nextTime > 0:
        notification["t"] = response.nextTime.toBson()
        discard await notificationsDB().update( bson.`%*`({ "_id": p.id }),
                                                bson.`%*`({
                                                    "$push": { nfList: notification },
                                                }),
                                                multi = false, upsert = false )

    result = getAllowedNotificationTime(p, curT + 1, sentT, cfg) - curT
    logNotifications "onSendNotification (", p.id, ") result = ", result


registerScheduleTask("notification", onSendNotification)


#

proc notifyQuestIsComplete*(p: Profile, name: string, isMain: bool, t: float): Future[void] {.async.} =
    if isMain:
        await scheduleNotification("quest complete", nidBuildComplete, t, p.id, bson.`%*`({"name": name}))
    else:
        await scheduleNotification("quest complete", nidUpgradeComplete, t, p.id, bson.`%*`({"name": name}))

proc forkNotifyQuestIsComplete*(p: Profile, name: string, isMain: bool, t: float) =
    asyncCheck notifyQuestIsComplete(p, name, isMain, t)

proc cancelNotifyQuestIsComplete*(p: Profile, name: string): Future[void] {.async.} =
    await cancelNotification("quest complete", p.id, bson.`%*`({"name": name}))

# proc forkCancelNotifyQuestIsComplete*(p: Profile, name: string) =
#     asyncCheck cancelNotifyQuestIsComplete(p, name)

proc onQuestIsComplete(p: Profile, args: Bson): Future[NotificationResponse] {.async.} =
    if "n" in args:
        result.id = args["n"].int.NotificationId
    else:
        let name = args["name"].toString()
        if name.contains("_decor_") or name.contains("_upgrade_"):
            result.id = nidUpgradeComplete
        else:
            result.id = nidBuildComplete

    if result.id == nidUpgradeComplete:
        result.text = "Your city is now even better👏  Check out your newest upgrades."
    else:
        result.text = "Hey! Your building is finished🏠  Check it out now!"

    result.deepLink = "/window/QuestWindow"

registerNotificationHandler("quest complete", onQuestIsComplete)


#

proc notifyResourcesAreFull*(p: Profile, name: string, t: float): Future[void] {.async.} =
    if name.startsWith("gasStation"):
        await scheduleNotification("resources full", nidGasStationFull, t, p.id, bson.`%*`({"name": name}))
    else:
        await scheduleNotification("resources full", nidRestarauntFull, t, p.id, bson.`%*`({"name": name}))

proc forkNotifyResourcesAreFull*(p: Profile, name: string, t: float) =
    asyncCheck notifyResourcesAreFull(p, name, t)

proc onResourcesAreFull(p: Profile, args: Bson): Future[NotificationResponse] {.async.} =
    let name = args["name"].toString()
    if name.startsWith("gasStation"):
        result.text = "Your Gas Station is full of cash🤑  It is time to spend some and expand your city!"
        result.id = nidGasStationFull
    elif name.startsWith("restaurant"):
        result.text = "Your Restaurant is full! Time to empty that chip storage. Spin! Spin! Spin! 👯"
        result.id = nidRestarauntFull
    else:
        result.text = ""

registerNotificationHandler("resources full", onResourcesAreFull)


#

const longTimesShort = @[1 * minT,  2 * minT,  3 * minT,  4 * minT,  5 * minT,  6 * minT,  7 * minT,  8 * minT,  9 * minT,  10 * minT ]
const longTimesLong = @[24 * hourT,  30 * hourT,  48 * hourT,  72 * hourT,  96 * hourT,  120 * hourT,  144 * hourT,  7 * dayT,  14 * dayT,  30 * dayT]
var longTimes = if speedupNoSeeNotifications: longTimesShort else: longTimesLong

static:
    assert longTimesShort.len == longTimesLong.len

const longTimeMessages: seq[string] = @[
    "👋  Visit your city to spin and win! Yeeaaaha!",
    "A free spin on the Wheel of Fortune is here 🏃",
    "Swing by and see what you've missed ✌",
    "Have you built anything new recently? 🚶 🏃",
    "Busy days? Visit Reel Valley when you have a chance!",
    "Valleyers begin to miss you. Are you there 👋",
    "Just sending you a notification. Hello.",
    "Hey boss! The city doesn't know what to do without you 🤔",
    "Have you unlocked our newest slots? They are freaking amazing 👏",
    "You have come to far to let Reel Valley become a ghost town 👻"
]

static:
    assert longTimeMessages.len == longTimesLong.len

const longTimeCodes: seq[NotificationId] = @[
    nidLongTimeNoSee1D,
    nidLongTimeNoSee30H_Wheel,
    nidLongTimeNoSee2D,
    nidLongTimeNoSee3D,
    nidLongTimeNoSee4D,
    nidLongTimeNoSee5D,
    nidLongTimeNoSee6D,
    nidLongTimeNoSee7D,
    nidLongTimeNoSee14D,
    nidLongTimeNoSee30D
]

static:
    assert longTimeCodes.len == longTimesLong.len

proc notifyLongTimeNoSeeAfterLogin*(p: Profile): Future[void] {.async.} =
    await scheduleNotification("long time no see", nidLongTimeNoSee1D, epochtime() + longTimes[0], p.id, bson.`%*`({}))

proc onLongTimeNoSee(p: Profile, args: Bson): Future[NotificationResponse] {.async.} =
    let t = epochtime() - p.statistics.lastRequestTime
    for i in countdown(longTimeCodes.len - 1, 0):
        if t >= longTimes[i]:
            result.text = longTimeMessages[i]
            if i < longTimeCodes.len - 1:
                result.nextTime = p.statistics.lastRequestTime + longTimes[i + 1]
            result.id = longTimeCodes[i]
            if result.id == nidLongTimeNoSee30H_Wheel:
                result.deepLink = "/window/WheelWindow"
            return
    result.text = ""
    result.nextTime = p.statistics.lastRequestTime + longTimes[0]

registerNotificationHandler("long time no see", onLongTimeNoSee)


#

proc notifyTournamentFinished*(profileID: Oid, participationID: Oid): Future[void] {.async.} =
    await scheduleNotification("tournament finished", nidTournamentFinished, epochtime(), profileID, bson.`%*`({"participation": participationID}))

proc cancelNotifyTournamentFinished*(profileID: Oid, participationID: Oid): Future[void] {.async.} =
    await cancelNotification("tournament finished", profileID, bson.`%*`({"participation": participationID}))

proc onTournamentFinished(p: Profile, args: Bson): Future[NotificationResponse] {.async.} =
    result.text = "The results are in! See how you stack up against the rest 🤑"
    result.id = nidTournamentFinished
    result.deepLink = "/window/TournamentsWindow"

registerNotificationHandler("tournament finished", onTournamentFinished)


#

proc notifyNextFreeFortuneWheelSpin*(profileID: Oid, t: float): Future[void] {.async.} =
    await scheduleNotification("free fortune wheel", nidFortuneWhellFreeSpinAvailable, t, profileID, bson.`%*`({}))

proc onNextFreeFortuneWheelSpin(p: Profile, args: Bson): Future[NotificationResponse] {.async.} =
    result.text = "A free spin on Wheel of Fortune is available. Go for it! Good luck ✌"
    result.id = nidFortuneWhellFreeSpinAvailable
    result.deepLink = "/window/WheelWindow"

registerNotificationHandler("free fortune wheel", onNextFreeFortuneWheelSpin)


#

proc notifyGiftReceived*(profileID: Oid, typeName: string): Future[void] {.async.} =
    if typeName == "daily":
        await scheduleNotification("gift received", nidDailyGiftReceived, epochTime(), profileID, bson.`%*`({"type": typeName}))
    elif typeName == "invite":
        await scheduleNotification("gift received", nidInviteGiftReceived, epochTime(), profileID, bson.`%*`({"type": typeName}))

proc onGiftReceived(p: Profile, args: Bson): Future[NotificationResponse] {.async.} =
    let typeName = args["type"].toString()
    if typeName == "daily":
        result.text = "Cha-ching! You’ve received a Gift from a Friend! Go get it now 🎁"
        result.id = nidDailyGiftReceived
        result.deepLink = "/social/Gifts"
    elif typeName == "invite":
        result.text = "Hey! Thanks for inviting a Friend! Here's your Bonus 💸"
        result.id = nidInviteGiftReceived
        result.deepLink = "/social/Gifts"

registerNotificationHandler("gift received", onGiftReceived)


#

proc notifyBoosterTimeLeft*(profileID: Oid, name: string, boosterEndT: float): Future[void] {.async.} =
    let booster12Ht = boosterEndT - 12 * 60 * 60
    if booster12Ht > epochTime():
        await scheduleNotification("booster 12h", nidBoostLeft12H, booster12Ht, profileID, bson.`%*`({"name": name}))
    else:
        await cancelNotification("booster 12h", profileID, bson.`%*`({"name": name}))

    let booster1Ht = boosterEndT - 12 * 60 * 60
    if booster1Ht > epochTime():
        await scheduleNotification("booster 1h", nidBoostLeft1H, booster1Ht, profileID, bson.`%*`({"name": name}))
    else:
        await cancelNotification("booster 1h", profileID, bson.`%*`({"name": name}))

proc onBoosterTimeLeft(p: Profile, args: Bson): Future[NotificationResponse] {.async.} =
    result.id = args["n"].int.NotificationId
    if result.id == nidBoostLeft12H:
        result.text = "Your Booster will expire in 12 hours. Just saying 😉"
    elif result.id == nidBoostLeft1H:
        result.text = "Your Booster will expire in 1 hour. Ready to reset? 🤔"

registerNotificationHandler("booster 12h", onBoosterTimeLeft)
registerNotificationHandler("booster 1h", onBoosterTimeLeft)
