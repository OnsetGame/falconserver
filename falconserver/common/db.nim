import os except DeviceId
import nimongo.mongo
import nimongo.bson
import asyncdispatch
import logging
import falconserver.auth.profile_types


var gDB: Database[AsyncMongo]


proc initDBWithURI*(uri: string) =
    assert(gDB.isNil)
    gDB = waitFor newAsyncMongoDatabase(uri, maxConnections = 4)
    if not gDB.isNil:
        echo "Successfully connected to Mongo."
        # discard printStats()
    else:
        raise newException(Exception, "Could not connect to Mongo. Please check if Mongo is started or its connection parameters.")


proc printStats*() {.async.} =
    let s = await gDB[MongoCollectionProfiles].stats()
    echo "Mongo stats: ", s


proc sharedDB*(): Database[AsyncMongo] =
    assert(not gDB.isNil)
    result = gDB


proc profilesDB*(): Collection[AsyncMongo] = sharedDB()[MongoCollectionProfiles]


proc bsonToSeq*[T](b: Bson, s: var seq[T]) =
    s.setLen(0)
    for v in b:
        let val: T = v
        s.add(val)

proc checkMongoReply*(s: StatusReply) =
    if not s.ok:
        raise newException(Exception, "DB Error: " & s.err)

    elif "writeErrors" in s.bson:
        error "Mongo write error ", s.bson
        raise newException(Exception, "MongoDB write error")

proc checkMongoReply*(s: Future[StatusReply]) {.async.} =
    checkMongoReply(await s)


proc removeWithCheck*(c: Collection[AsyncMongo], selector: Bson, limit: int = 0, ordered: bool = true, writeConcern: Bson = nil) {.async.} =
    let res = await c.remove(selector, limit, ordered, writeConcern)
    res.checkMongoReply()
