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

import falconserver.auth.profile_types

import asyncdispatch


import falconserver.auth.profile
import falconserver.common.db
import falconserver.common.bson_helper
import falconserver.schedule

proc statsDB(): Collection[AsyncMongo] =
    result = sharedDB()["statistics"]


proc dateString(date: float): string =
    result = date.fromSeconds().getLocalTime().format("dd-MM-yyyy")

proc currentDateString(): string =
    result = epochtime().dateString()


proc statsIncrease(incB: Bson): Future[void] {.async.} =
    var dateStr = currentDateString()
    await checkMongoReply statsDB().update(bson.`%*`({"date": dateStr}),
                            bson.`%*`({"$setOnInsert": {"date": dateStr}, "$inc": incB}),
                            multi = false, upsert = true)


proc statsIncrease(tag: string, amount: int64 = 1): Future[void] {.async.} =
    if amount != 0:
        await statsIncrease(bson.`%*`({tag: amount}))


proc reportNewUser*(): Future[void] {.async.} =
    await statsIncrease("newUsers")


proc tryReportActiveUser*(p: Profile): Future[void] {.async.} =
    var prevRequestTime = p.prevRequestTime
    if prevRequestTime == 0:
        prevRequestTime = p.statistics.lastRequestTime
    if prevRequestTime.dateString() != currentDateString():
        await statsIncrease("activeUsers")


proc reportSlotSpin*(slotName: string, bet: int64, payout: int64): Future[void] {.async.} =
    await statsIncrease(bson.`%*`({slotName & ".spins": 1, slotName & ".bets": bet, slotName & ".payout": payout}))


proc reportSlotPayout*(slotName: string, payout: int64): Future[void] {.async.} =
    await statsIncrease(slotName & ".payout", payout)


proc reportTournamentCreated*(amount: int, fast: bool): Future[void] {.async.} =
    await statsIncrease(if fast: "fastTournamentsCreated" else: "tournamentsCreated", amount)


proc reportPushNotificationSent*(id: string): Future[void] {.async.} =
    await statsIncrease("pushNotifications." & id)
