import times
import sequtils
import nimongo.bson
import asyncdispatch
import math

import falconserver.common.db
import falconserver.common.orm
import falconserver.auth.profile_random
import falconserver.common.notifications
import falconserver.common.game_balance
import falconserver.common.get_balance_config

type WheelSpinCostType* {.pure.}= enum
    Timeout,
    FreeSpin,
    Currency

proc fortuneWheelCostType(p: Profile, s: FortuneWheelState): WheelSpinCostType =
    if epochTime() - s.lastFreeTime  >=  p.getGameBalance().fortuneWheel.freeSpinTimeout:
        result = WheelSpinCostType.Timeout
    elif s.freeSpinsLeft > 0:
        result = WheelSpinCostType.FreeSpin
    else:
        result = WheelSpinCostType.Currency

proc fortuneWheelSpinCost*(p: Profile, s: FortuneWheelState): int =
    let t = p.fortuneWheelCostType(s)
    case t
    of WheelSpinCostType.Currency:
        result = p.getGameBalance().fortuneWheel.spinCost
    else:
        result = 0


proc getWeightedRandom(p: Profile, probs: seq[float]): int =
    var roll = p.random(probs.sum())
    for i in 0 ..< probs.len:
        if roll <= probs[i]:
            return i
        else:
            roll -= probs[i]
    return probs.len  # should cause an error

proc spinFortuneWheel*(p: Profile): Future[int] {.async.} =
    var s = p.fortuneWheelState

    let costType = p.fortuneWheelCostType(s)
    case costType
    of WheelSpinCostType.Timeout:
        s.lastFreeTime = epochTime()
        await notifyNextFreeFortuneWheelSpin(p.id, s.lastFreeTime + p.getGameBalance().fortuneWheel.freeSpinTimeout)
    of WheelSpinCostType.FreeSpin:
        s.freeSpinsLeft = s.freeSpinsLeft - 1
    of WheelSpinCostType.Currency:
        let cost = p.fortuneWheelSpinCost(s)
        p.bucks = p.bucks - cost

    let fwData = p.getGameBalance().fortuneWheel
    result = p.getWeightedRandom(if s.history.isNil: fwData.firstTimeProbs  else: fwData.defaultProbs)
    var gain = fwData.gains[result]
    case gain.item:
        of "chips":
            p.chips = p.chips + gain.count
        of "bucks":
            p.bucks = p.bucks + gain.count
        of "beams", "parts", "energy":
            p.parts = p.parts + gain.count

    if s.history.isNil or s.history.kind != BsonKindArray:  # for some reason, some old accounts kind is Document
        s.history = bson.`%*`([{"item": gain.item, "count": gain.count}])
    elif s.history.len() < 3:
        discard s.history.add bson.`%*`({"item": gain.item, "count": gain.count})
    else:
        var newHistory = newBsonArray()
        for i in 1 ..< s.history.len():
            discard newHistory.add s.history[i]
        discard newHistory.add bson.`%*`({"item": gain.item, "count": gain.count})
        s.history = newHistory

    # temporary fix, as ORM doesn't handle well child objects
    p.fortuneWheelB = wheelStateToBson(s)
    await p.commit()

proc setNextFreeSpinTime*(p: Profile, seconds:int) =
    var s = p.fortuneWheelState
    s.lastFreeTime = epochTime() - p.getGameBalance().fortuneWheel.freeSpinTimeout + seconds.float64

    p.fortuneWheelB = wheelStateToBson(s)

proc addWheelFreeSpins*(p: Profile, amount:int) =
    var s = p.fortuneWheelState
    s.freeSpinsLeft = s.freeSpinsLeft + amount

    p.fortuneWheelB = wheelStateToBson(s)

