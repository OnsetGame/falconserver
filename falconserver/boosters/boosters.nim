import json, oids, times, sets, asyncdispatch
import nimongo / [ mongo, bson ]

import falconserver / common / [ bson_helper, db, game_balance, notifications ]
import falconserver / auth / [ profile_types, profile_stats, profile ]
import shafa / game / booster_types

export BoosterTypes


type Boosters* = ref object of RootObj
    profile: Profile
    data: Bson


proc boosters*(p: Profile): Boosters =
    result = Boosters.new
    result.profile = p
    result.data = p.boostersData


proc getData(b: Boosters, name: string): Bson =
    if not b.data.isNil and name in b.data:
        result = b.data[name]


proc getOrCreateData(b: Boosters, name: string): Bson =
    if b.data.isNil:
        b.data = newBsonDocument()

    if name in b.data:
        result = b.data[name]
    else:
        result = newBsonDocument()
        b.data[name] = result


proc add*(b: Boosters, name: string, t: float, isFree: bool = false): Future[void] {.async.} =
    var data = b.getOrCreateData(name)

    if $bfActiveUntil in data and epochTime() < data[$bfActiveUntil].toFloat64():
        let endTime = data[$bfActiveUntil].toFloat64() + t
        data[$bfActiveUntil] = endTime.toBson()
        await b.profile.id.notifyBoosterTimeLeft(name, endTime)
        # echo "DDD adding time to booster ", name, " -> ", b.data
    elif $bfCharged in data:
        data[$bfCharged] = (data[$bfCharged].toFloat64() + t).toBson()
        # echo "DDD adding charge to booster ", name, " -> ", b.data
    else:
        data[$bfCharged] = t.toBson()
        # echo "DDD setting charge to booster ", name, " -> ", b.data

    if $bfCharged in data and isFree:
        data[$bfFree] = true.toBson()

    b.profile.boostersData = b.data  # to mark changes
    # echo "DDD result = ", b.profile.boostersData


proc start*(b: Boosters, name: string): Future[bool] {.async.} =
    # echo "DDD starting booster ", name
    let data = b.getData(name)

    if data.isNil or $bfCharged notin data or ($bfActiveUntil in data and epochTime() < data[$bfActiveUntil].toFloat64()):
        # echo "DDD invalid booster start -> ", b.profile.boostersData
        return false

    if $bfActiveUntil in data:
        data.del($bfActiveUntil)

    let endTime = epochTime() + data[$bfCharged].toFloat64()
    data[$bfActiveUntil] = endTime.toBson()
    data.del $bfCharged
    b.profile.boostersData = b.data  # to mark changes
    await b.profile.id.notifyBoosterTimeLeft(name, endTime)
    result = true


proc stateResp*(b: Boosters): JsonNode =
    if b.data.isNil:
        result = json.`%*`({})
    else:
        result = b.data.toJson()


proc ratesResp*(gconf: GameplayConfig, b: Boosters): JsonNode =
    result = newJObject()
    result[$btTournamentPoints] = %gconf.getGameBalance().boosters.tournamentPointsRate
    result[$btExperience] = %gconf.getGameBalance().boosters.experienceRate
    result[$btIncome] = %gconf.getGameBalance().boosters.incomeRate


proc activeUntilT*(b: Boosters, name: string): float =
    let data = b.getData(name)
    if data.isNil or $bfActiveUntil notin data:
        result = 0
    else:
        result = data[$bfActiveUntil].toFloat64()


proc isActive*(b: Boosters, name: string): bool =
    result = epochTime() <= b.activeUntilT(name)


proc affectsTournaments*(b: Boosters): bool =
    b.isActive $btTournamentPoints


proc affectsExperience*(b: Boosters): bool =
    b.isActive $btExperience

# proc expRate*(b: Boosters): float =
#     if b.isActive($btExperience):
#         result = 1.5
#     else:
#         result = 1.0
