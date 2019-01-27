import oids, json
import falconserver / auth / [ profile, profile_types ]
import shafa / slot / slot_data_types
import falconserver / common / [ db, orm ]
import nimongo / [ bson, mongo ]


proc freeRoundsDB*(): Collection[AsyncMongo] =
    result = sharedDB()["free_rounds"]


type FreeRoundsFields = enum
    frfRounds = "r"
    frfRoundsCount = "rc"
    ftfSpin = "s"
    ftfReward = "re"


TransparentObj FreeRounds:
    id: Oid($prfId, "id")
    slotsState: Bson($sdtSlotResult)
    rounds: Bson($frfRounds)


proc newFreeRounds(b: Bson): FreeRounds =
    result.new
    result.init(freeRoundsDB(), b)


proc newFreeRounds(id: Oid): FreeRounds =
    newFreeRounds(bson.`%*`({
        $prfId: id, 
        $sdtSlotResult: newBsonDocument(), 
        $frfRounds: newBsonDocument()
    }))


proc findFreeRounds*(id: Oid): Future[FreeRounds] {.async.} =
    try:
        let dbResult = await freeRoundsDB().find(bson.`%*`({$prfId: id})).one()
        result = newFreeRounds(dbResult)
    except:
        result = nil


proc getOrCreateFreeRounds*(id: Oid): Future[FreeRounds] {.async.} =
    result = await findFreeRounds(id)
    if result.isNil:
        result = newFreeRounds(id)


proc freeRoundsSpinIsValid*(profileId: Oid, gameSlotId: string, jData: JsonNode): Future[(JsonNode, FreeRounds)] {.async.} =
    let mode = jData{"mode"}{"kind"}.getInt()
    if mode != smkFreeRound.int:
        return

    let freeRounds = await profileId.findFreeRounds()
    if freeRounds.isNil:
        result[0] = %{"reason": %("Free rounds for user `" & $profileId & "` has not been found")}
        return

    let stats = freeRounds.rounds{gameSlotId}
    if stats.isNil:
        result[0] = %{"reason": %("Free rounds for user `" & $profileId & "` and slot `" & gameSlotId & "` has not been found")}
        return

    let limit = stats[$frfRoundsCount].toInt()
    let spin = stats[$ftfSpin].toInt()
    
    if limit == 0:
        result[0] = %{"reason": %("User `" & $profileId & "` on slot `" & gameSlotId & "` hasn't free rounds")}
        return

    result[1] = freeRounds


proc addFreeRounds*(freeRounds: FreeRounds, gameSlotId: string, count: int) =
    let stats = freeRounds.rounds{gameSlotId}
    if stats.isNil:
        freeRounds.rounds{gameSlotId} = bson.`%*`({$frfRoundsCount: count, $ftfSpin: 0, $ftfReward: 0})
    else:
        stats[$frfRoundsCount] = (stats[$frfRoundsCount].toInt() + count).toBson()


proc incFreeRoundSpins*(freeRounds: FreeRounds, gameSlotId: string) =
    freeRounds.rounds{gameSlotId, $ftfSpin} = (freeRounds.rounds{gameSlotId, $ftfSpin}.toInt() + 1).toBson()
    

proc incFreeRoundReward*(freeRounds: FreeRounds, gameSlotId: string, reward: int64) =
    freeRounds.rounds{gameSlotId, $ftfReward} = (freeRounds.rounds{gameSlotId, $ftfReward}.toInt64() + reward).toBson()


proc rounds*(freeRounds: FreeRounds, gameSlotId: string): int =
    freeRounds.rounds{gameSlotId, $ftfSpin}.toInt()


proc roundsCount*(freeRounds: FreeRounds, gameSlotId: string): int =
    freeRounds.rounds{gameSlotId, $frfRoundsCount}.toInt()


const FREE_ROUNDS_JSON_KEY* = "freeRounds"
proc toJson*(freeRounds: FreeRounds): JsonNode =
    result = newJObject()
    for key, value in freeRounds.rounds:
        let rounds = value[$frfRoundsCount].toInt()
        result[key] = json.`%*`({
            "rounds": rounds,
            "passed": value[$ftfSpin].toInt(),
            "reward": value[$ftfReward].toInt64()
        })


proc getFreeRoundReward*(freeRounds: FreeRounds, gameSlotId: string): Future[tuple[err: JsonNode, reward: int64]] {.async.} =
    if freeRounds.isNil:
        result[0] = %{"reason": %("Rewards for user `" & $freeRounds.id & "` and slot `" & gameSlotId & "` have not been found")}
        return

    let stats = freeRounds.rounds{gameSlotId}
    if stats.isNil:
        result[0] = %{"reason": %("Rewards for user `" & $freeRounds.id & "` and slot `" & gameSlotId & "` have not been found")}
        return
    
    let rounds = stats{$frfRoundsCount}.toInt()
    if rounds <= 0:
        result[0] = %{"reason": %("Rewards for user `" & $freeRounds.id & "` and slot `" & gameSlotId & "` have not been found")}
        return

    if rounds > stats{$ftfSpin}.toInt():
        result[0] = %{"reason": %("Free rounds for user `" & $freeRounds.id & "` and slot `" & gameSlotId & "` have not been completed jet")}
        return
    
    result[1] = stats{$ftfReward}.toInt64()
    
    stats{$frfRoundsCount} = 0.toBson()
    stats{$ftfSpin} = 0.toBson()
    stats{$ftfReward} = 0.toBson()

    let reqset = newBsonDocument()
    reqset[$frfRounds & "." & gameSlotId] = stats

    let resp = await freeRounds.collection.update(bson.`%*`({"_id": freeRounds.id}), bson.`%*`({"$set": reqset}), false, true)
    checkMongoReply(resp)


proc save*(freeRounds: FreeRounds) {.async.} =
    let resp = await freeRounds.collection.update(bson.`%*`({"_id": freeRounds.id}), freeRounds.bson, false, true)
    checkMongoReply(resp)


proc updateWithFreeRounds*(resp: JsonNode, freeRounds: FreeRounds) =
    let value = freeRounds.toJson()
    if value.len > 0:
        resp[FREE_ROUNDS_JSON_KEY] = value


proc updateWithFreeRounds*(resp: JsonNode, id: Oid) {.async.} =
    let freeRounds = await findFreeRounds(id)
    if not freeRounds.isNil:
        resp.updateWithFreeRounds(freeRounds)