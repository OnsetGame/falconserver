import falconserver / admin / [admin_profile, admin_permissions, slot_zsm_test]
import falconserver.auth.profile_types

import falconserver / common / [response, bson_helper, db, config, game_balance, ab_constants]
import falconserver / quest / quests_config
import falconserver / map / building / builditem
import falconserver / slot / [machine_balloon_server, machine_candy_server, machine_classic_server,
                              machine_mermaid_server, machine_ufo_server, machine_witch_server,
                              machine_candy2_server, machine_groovy_server, machine_card_server ]

import falconserver.tournament.tournaments
import falconserver.slot.near_misses

import nimongo.bson
import nimongo.mongo

import json, asyncdispatch, tables, strutils, sequtils
import oids
import sha1
import times
import logging
import os

type
    AdminLoginCode {.pure.} = enum
        fail
        registration
        login

    RouteHandler = proc(db: Database[AsyncMongo], jData: JsonNode): Future[JsonNode]

var adminRoutes = initTable[string, RouteHandler]()
const dbMaxResult = 500


let DEFAULT_ZSMS = [
    dreamTowerDefaultZsm, candyDefaultZsm, ballonsDefaultZsm,
    mermaidDefaultZsm, witchDefaultZsm, ufoDefaultZsm, groovyDefaultZsm,
    candy2DefaultZsm, cardDefaultZsm

].map(proc(x: string): JsonNode = x.parseJson())

proc login(db: Database[AsyncMongo], jData: JsonNode): Future[tuple[code: AdminLoginCode, profile: Bson, nextSalt: string]] {.async.} =
    let
        salt = jData["salt"].getStr()

    var loginCode = AdminLoginCode.fail
    var profile: Bson
    var nextSalt = ""

    profile = await db[MongoCollectionAdmins].find(bson.`%*`({$apfMail: mail})).one()
    let secret = profile[$apfSecret].toString()
    if secret.len > 0:
        let dbSalt = profile[$apfRequestId].toString()
        let dbPwd = sha1.compute(secret & profile[$apfRequestId].toString()).toHex()
        if dbPwd == salt:
            loginCode = AdminLoginCode.login
        else:
            loginCode = AdminLoginCode.fail
    else:
        profile[$apfSecret] = salt.toBson()
        loginCode = AdminLoginCode.registration

    if loginCode == AdminLoginCode.registration or loginCode == AdminLoginCode.login:
        nextSalt = $genOid()
        profile[$apfRequestId] = nextSalt.toBson()
        discard await db[MongoCollectionAdmins].update(
            bson.`%*`({$apfMail: mail}),
            bson.`%*`({"$set": profile}),
            false, true
        )

    result = (code: loginCode, profile: profile, nextSalt: nextSalt)

proc getSaltHandler(db: Database[AsyncMongo], jData: JsonNode): Future[JsonNode] {.async.}=
    let mail = jData["mail"].getStr()

    result = newJObject()
    var newUser = false
    var profile: Bson
    try:
        profile = await db[MongoCollectionAdmins].find(bson.`%*`({$apfMail: mail})).one()
        result["salt"] = %profile[$apfSalt].toString()
        result["requestId"] = %profile[$apfRequestId].toString()
    except:
        var salt = $genOid()
        result["salt"] = %salt
        profile = newAdminProfile(mail, "")
        profile[$apfSalt] = salt.toBson()
        newUser = true

    if newUser:
        discard await db[MongoCollectionAdmins].update(
            bson.`%*`({$apfMail: mail}),
            bson.`%*`({"$set": profile}),
            false, true
        )

proc loginHandler(db: Database[AsyncMongo], jData: JsonNode): Future[JsonNode] {.async.}=
    result = newJObject()

    let (loginCode, profile, nextSalt) = await login(db, jData)
    result["loginResult"] = % $loginCode
    result["status"] = %StatusCode.Ok.int

    if nextSalt.len > 0:
        result["requestId"] = %nextSalt

    if loginCode != AdminLoginCode.fail:
        result["broLevel"] = %profile[$apfAccountLevel].toInt()

proc exeptBotsQuery(que: Bson = nil): Bson=
    var findQuery = newBsonDocument()
    findQuery["$and"] = newBsonArray()

    var skiptTournamentsBots = newBsonDocument()
    skiptTournamentsBots["isBot"] = bson.`%*`({"$exists":false})
    findQuery["$and"].add(skiptTournamentsBots)

    var skipLoadBots1 = newBsonDocument()
    skipLoadBots1["randomState0"] = bson.`%*`({"$exists":false})
    findQuery["$and"].add(skipLoadBots1)

    var skipLoadBots2 = newBsonDocument()
    skipLoadBots2["randomState1"] = bson.`%*`({"$exists":false})
    findQuery["$and"].add(skipLoadBots2)
    if not que.isNil:
        findQuery["$and"].add(que)
    result = findQuery

proc dbViewHandler(db: Database[AsyncMongo], jData: JsonNode): Future[JsonNode] {.async.}=
    result = newJObject()
    let loginResult = await login(db, jData)
    if loginResult.code == AdminLoginCode.login and loginResult.profile.checkPermission(apDbView):
        let docsFrom = jData["from"].getInt().int32
        let docsTo   = jData["to"].getInt().int32

        let allDocs = await db[MongoCollectionProfiles].find(exeptBotsQuery()).skip(docsFrom).limit(docsTo).all()
        let totalProfiles = await db[MongoCollectionProfiles].count()
        var jDocs = newJArray()

        for doc in allDocs:
            jDocs.add(doc.toJson())

        result["profilesCount"] = %totalProfiles
        result["status"] = %StatusCode.Ok.int
        result["requestId"]   = %loginResult.nextSalt
        result["db"] = jDocs
    else:
        result["status"] = %StatusCode.LogginFailure.int

proc dbSearchHandler(db: Database[AsyncMongo], jData: JsonNode): Future[JsonNode] {.async.}=
    result = newJObject()
    let loginResult = await login(db, jData)
    if loginResult.code == AdminLoginCode.login and loginResult.profile.checkPermission(apDbView):
        try:
            var profID: Oid
            var hasId: bool
            if jData["searchQuery"].hasKey("_id"):
                profID = parseOid(jData["searchQuery"]["_id"].getStr())
                jData["searchQuery"].delete("_id")
                hasId = true

            var findQuery = exeptBotsQuery(jData["searchQuery"].toBson())
            if hasId:
                findQuery["_id"] = profID.toBson()
            let searchCursor = db[MongoCollectionProfiles].find(findQuery)
            var searchResult = await searchCursor.limit(dbMaxResult).all()
            var searchCount = await searchCursor.count()

            if searchResult.len == 0:
                result["errmsg"] = %"Fot found!"
            else:
                var users = newJArray()
                for bu in searchResult:
                    users.add(bu.toJson())
                result["db"] = users
                result["count"] = %searchCount
                result["status"] = %StatusCode.Ok.int
        except:
            result["status"] = %StatusCode.InvalidRequest.int
            result["errmsg"] = %getCurrentExceptionMsg()

        result["requestId"] = %loginResult.nextSalt
    else:
        result["status"] = %StatusCode.LogginFailure.int

# top permissions level
proc dbSearchBros(db: Database[AsyncMongo], jData: JsonNode): Future[JsonNode] {.async.}=
    result = newJObject()
    let loginResult = await login(db, jData)
    if loginResult.code == AdminLoginCode.login and loginResult.profile.checkPermission(apGrantPermissions):
        let allBros = await db[MongoCollectionAdmins].find(bson.`%*`({})).limit(dbMaxResult).all()

        var brosJn = newBsonArray()
        for bro in allBros:
            var clientBro = newBsonDocument()
            clientBro["mail"] = bro[$apfMail]
            clientBro["level"] = bro[$apfAccountLevel]
            brosJn.add(clientBro)

        result["status"] = %StatusCode.Ok.int
        result["requestId"] = %loginResult.nextSalt
        result["allBros"] = %brosJn.toJson()
    else:
        result["status"] = %StatusCode.LogginFailure.int

# top permissions level
proc approvePermissions(db: Database[AsyncMongo], jData: JsonNode): Future[JsonNode] {.async.}=
    result = newJObject()
    let loginResult = await login(db, jData)
    let broMail = jData["newBro"].getStr()
    let curBro = jData["mail"].getStr()
    if loginResult.code == AdminLoginCode.login and loginResult.profile.checkPermission(apGrantPermissions):
        if curBro != broMail:
            let broLevel = jData["broLevel"].getInt().AdminAccountLevel
            let broProfile = await db[MongoCollectionAdmins].find(bson.`%*`({$apfMail: broMail})).one()
            broProfile[$apfAccountLevel] = (broLevel.int).toBson()

            discard await db[MongoCollectionAdmins].update(
                bson.`%*`({$apfMail: broMail}),
                bson.`%*`({"$set": bson.`%*`({$apfAccountLevel: broProfile[$apfAccountLevel]}) }),
                false, true
                )

            result["status"] = %StatusCode.Ok.int
        else:
            result["status"] = %StatusCode.InvalidRequest.int
        result["requestId"] = %loginResult.nextSalt
    else:
        result["status"] = %StatusCode.LogginFailure.int

# top permissions level
proc removeBroHandler(db: Database[AsyncMongo], jData: JsonNode): Future[JsonNode] {.async.}=
    result = newJObject()
    let loginResult = await login(db, jData)
    let broMail = jData["remove"].getStr()
    let curBro = jData["mail"].getStr()
    if loginResult.code == AdminLoginCode.login and loginResult.profile.checkPermission(apGrantPermissions):
        if curBro != broMail:
            discard await db[MongoCollectionAdmins].remove(
                bson.`%*`({$apfMail: broMail})
            )

            result["status"] = %StatusCode.Ok.int
        else:
            result["status"] = %StatusCode.InvalidRequest.int
        result["requestId"] = %loginResult.nextSalt
    else:
        result["status"] = %StatusCode.LogginFailure.int

proc applyDifferenceHandler(db: Database[AsyncMongo], jData: JsonNode): Future[JsonNode] {.async.}=
    result = newJObject()
    let loginResult = await login(db, jData)
    let difference = jData["diff"]
    if loginResult.code == AdminLoginCode.login and loginResult.profile.checkPermission(apGrantPermissions):

        for proffId, queryProf in difference:
            let prof = parseOid(proffId)
            let profile = await db[MongoCollectionProfiles].find(bson.`%*`({"_id": prof.toBson()})).one()

            if $prfQuests in queryProf:
                queryProf.delete($prfQuests)

            if $prfTutorial in queryProf:
                queryProf.delete($prfTutorial)

            let query = queryProf.toBson()
            debug "queryBson: ", query

            discard await db[MongoCollectionProfiles].update(
                bson.`%*`({"_id": prof.toBson()}),
                bson.`%*`({"$set": query }),
                false, true
                )

        result["status"] = %StatusCode.Ok.int
        result["requestId"] = %loginResult.nextSalt
    else:
        result["status"] = %StatusCode.LogginFailure.int


proc applyProfile(db: Database[AsyncMongo], jData: JsonNode): Future[JsonNode] {.async.}=
    result = newJObject()
    result["status"] = %StatusCode.Failed.int
    let loginResult = await login(db, jData)
    if loginResult.code == AdminLoginCode.login and loginResult.profile.checkPermission(apDbModify):
        let newProfile = jData["newProf"]
        for proffId, queryProf in newProfile:
            let prof = parseOid(proffId)
            let profile = await db[MongoCollectionProfiles].find(bson.`%*`({"_id": prof.toBson()})).oneOrNone()
            if not profile.isNil:
                let query = parseJson(queryProf.getStr()).toBson()
                let r = await db[MongoCollectionProfiles].update(
                    bson.`%*`({"_id": profile["_id"]}),
                    query,
                    false, true
                    )

                if r.ok:
                    result["status"] = %StatusCode.Ok.int
        result["requestId"] = %loginResult.nextSalt
    else:
        result["status"] = %StatusCode.LogginFailure.int

proc mongoStatsHandler(db: Database[AsyncMongo], jData: JsonNode): Future[JsonNode] {.async.}=
    result = newJObject()
    let loginResult = await login(db, jData)
    if loginResult.code == AdminLoginCode.login and loginResult.profile.checkPermission(apGrantPermissions):
        let stats = await db[MongoCollectionProfiles].stats()

        result["stats"] = stats.toJson()
        result["status"] = %StatusCode.Ok.int
        result["requestId"] = %loginResult.nextSalt
    else:
        result["status"] = %StatusCode.LogginFailure.int

proc getFindQueries(db: Database[AsyncMongo], jData: JsonNode): Future[JsonNode] {.async.} =
    result = newJObject()
    let loginResult = await login(db, jData)
    if loginResult.code == AdminLoginCode.login and loginResult.profile.checkPermission(apDbView):
        let queries = await db[FindQueriesCollection].find(bson.`%*`({})).limit(dbMaxResult).all()
        let count =  await db[FindQueriesCollection].count()
        debug "queries count ", count
        var jQueries = newJArray()
        for bq in queries:
            jQueries.add(bq.toJson())
        result["queries"] = jQueries
        result["status"] = %StatusCode.Ok.int
        result["requestId"] = %loginResult.nextSalt
    else:
        result["status"] = %StatusCode.LogginFailure.int

proc addFindQuery(db: Database[AsyncMongo], jData: JsonNode): Future[JsonNode] {.async.} =
    result = newJObject()
    let loginResult = await login(db, jData)
    if loginResult.code == AdminLoginCode.login and loginResult.profile.checkPermission(apGrantPermissions):
        let searchQuery = jData["searchQuery"].toBson()
        let queryName = jData["queryName"].getStr()

        let bQuery = newBsonDocument()
        bQuery["n"] = queryName.toBson()
        bQuery["q"] = ($searchQuery).toBson()

        let r = await db[FindQueriesCollection].update(
                bson.`%*`({"n":queryName}),
                bson.`%*`({"$set": bQuery}),
                false, true
            )
        debug "try to addFindQuery ", bQuery, " with r ", r
        result["status"] = %StatusCode.Ok.int
        result["requestId"] = %loginResult.nextSalt

    else:
        result["status"] = %StatusCode.LogginFailure.int

proc removeFindQuery(db: Database[AsyncMongo], jData: JsonNode): Future[JsonNode] {.async.} =
    result = newJObject()
    let loginResult = await login(db, jData)
    if loginResult.code == AdminLoginCode.login and loginResult.profile.checkPermission(apGrantPermissions):
        let queryName = jData["queryName"].getStr()
        asyncCheck db[FindQueriesCollection].remove(
                bson.`%*`({"n":queryName})
            )
        result["status"] = %StatusCode.Ok.int
        result["requestId"] = %loginResult.nextSalt
    else:
        result["status"] = %StatusCode.LogginFailure.int

proc sendMessage(db: Database[AsyncMongo], jData: JsonNode): Future[JsonNode] {.async.} =
    result = newJObject()
    let loginResult = await login(db, jData)
    if loginResult.code == AdminLoginCode.login and loginResult.profile.checkPermission(apGrantPermissions):
        if "msg" notin jData:
            result["status"] = %StatusCode.InvalidRequest.int
            result["requestId"] = %loginResult.nextSalt
            return

        let msg = jData["msg"].toBson()
        var findQuery = newBsonDocument()

        if "query" in jData:
            findQuery = exeptBotsQuery(jData["query"].toBson())
        else:
            findQuery["$or"] = newBsonArray()
            for prof in jData["profs"]:
                var profid = bson.`%*`({"_id": parseOid(prof.getStr()).toBson()})
                findQuery["$or"].add(profid)
        debug "findQuery ", findQuery
        debug "msg ", msg
        checkMongoReply await db[MongoCollectionProfiles].update(
                findQuery,
                bson.`%*`({"$push":{$prfMessages: msg}}),
                true, false
            )

        result["status"] = %StatusCode.Ok.int
        result["requestId"] = %loginResult.nextSalt
    else:
        result["status"] = %StatusCode.LogginFailure.int


proc pullConfig(db: Database[AsyncMongo], jData: JsonNode): Future[JsonNode] {.async.} =
    result = newJObject()
    let loginResult = await login(db, jData)
    if loginResult.code == AdminLoginCode.login and loginResult.profile.checkPermission(apDbView):
        result["config"] = configForPull()
        result["scheme"] = configScheme()
        result["status"] = %StatusCode.Ok.int
        result["requestId"] = %loginResult.nextSalt
    else:
        result["status"] = %StatusCode.LogginFailure.int


proc pushConfig(db: Database[AsyncMongo], jData: JsonNode): Future[JsonNode] {.async.} =
    result = newJObject()
    let loginResult = await login(db, jData)
    if loginResult.code == AdminLoginCode.login and loginResult.profile.checkPermission(apDbView):
        result["requestId"] = %loginResult.nextSalt

        let newConfigB = configForPush(jData["config"])
        let errorText = tryReplaceGameConfig(newConfigB)
        if errorText.len == 0:
            var replaceReq: Bson
            if sharedGameConfig().dbID.isNil:
                replaceReq = bson.`%*`({"version": sharedGameConfig().version})
            else:
                replaceReq = bson.`%*`({"_id": sharedGameConfig().dbID})

            var reply = await db["config"].update(replaceReq, newConfigB, multi = false, upsert = true)
            debug reply.bson.toJson()
            result["status"] = %StatusCode.Ok.int
        else:
            result["status"] = %StatusCode.InvalidRequest.int
            result["error"] = %errorText
    else:
        result["status"] = %StatusCode.LogginFailure.int


proc createTournament(db: Database[AsyncMongo], jData: JsonNode): Future[JsonNode] {.async.} =
    result = newJObject()
    let loginResult = await login(db, jData)
    if loginResult.code == AdminLoginCode.login and loginResult.profile.checkPermission(apDbView):
        result["requestId"] = %loginResult.nextSalt
        let errorText = await createTournamentWithConfig(jData["config"])
        if errorText.len > 0:
             result["status"] = %StatusCode.InvalidRequest.int
             result["error"] = %errorText
        else:
             result["status"] = %StatusCode.Ok.int
    else:
        result["status"] = %StatusCode.LogginFailure.int


proc getGbConfigs(db: Database[AsyncMongo], jData: JsonNode): Future[JsonNode] {.async.} =
    result = newJObject()
    let loginResult = await login(db, jData)
    if loginResult.code == AdminLoginCode.login and loginResult.profile.checkPermission(apDbView):
        for dbkey in ["gb_common", "gb_story", "gb_daily", "gb_config", "zsm", "gb_spins", "gb_client", "gb_nearmisses", "gb_offers"]:
            var bconfigs = await db[dbkey].find(newBsonDocument()).all()
            var configs = newJArray()
            debug "configs at ", dbkey, " configs len ", bconfigs.len()

            for bc in bconfigs:
                try:
                    var jc = bc.toJson()
                    configs.add(jc)
                except:
                    warn "skip invalid config ", bc

            if dbkey == "gb_common":
                var def = newJObject()
                def["name"] = %"Default"
                def["gb"] = parseJson(commonBalanceData)
                def["d"] = %true
                configs.add(def)

            elif dbkey == "gb_story":
                var def = newJObject()
                def["name"] = %"Default"
                def["gb"] = parseJson(storyConfig)
                def["d"] = %true
                configs.add(def)

            elif dbkey == "gb_daily":
                var def = newJObject()
                def["name"] = %"Default"
                def["gb"] = parseJson(dailyConfig)
                def["d"] = %true
                configs.add(def)

            elif dbkey == "gb_spins":
                var def = newJObject()
                def["name"] = %"Default"
                def["gb"] = sharedPredefinedSpinsData()
                def["d"] = %true
                configs.add(def)

            elif dbkey == "gb_nearmisses":
                var def = newJObject()
                def["name"] = %"Default"
                def["gb"] = parseJson(nearMissData)
                def["d"] = %true
                configs.add(def)

            elif dbKey == "zsm":
                for zsm in DEFAULT_ZSMS:
                    var def = newJObject()
                    def["name"] = %zsm["slot"].getStr().abDefaultSlotZsmName
                    def["gb"] = zsm
                    def["d"] = %true
                    configs.add(def)

            elif dbkey == "gb_client":
                var def = newJObject()
                def["name"] = %"Default"
                def["gb"] = json.`%*`({"top_panel_variant": "default", "skip_task_button":"default", "quest_corner_hls":""})
                def["d"] = %true
                configs.add(def)

            elif dbkey == "gb_offers":
                var def = newJObject()
                def["name"] = %"Default"
                def["d"] = %true
                configs.add(def)

            elif dbkey == "gb_config":
                discard
                # debug "CONFIG >>>> ", bconfigs
            result[dbkey] = configs

        result["status"] = %StatusCode.Ok.int
        result["requestId"] = %loginResult.nextSalt
    else:
        result["status"] = %StatusCode.LogginFailure.int

proc gbChanged(): Future[void] {.async.}=
    let blu = bson.`%*`({"last_update": epochTime()})
    discard await sharedDb()["gb_lastUpdate"].update(
        bson.`%*`({"gb": "gb_check"}),
        bson.`%*`({"$set": blu}),
        false, true
    )

proc sameStructure(jn1, jn2: JsonNode): bool=
    result = jn1.kind == jn2.kind

    if not result:
        return

    if jn1.kind == JObject:
        for k, v in jn1:
            if k notin jn2:
                debug "validate key ", k, " ; ", v.kind
                return false

            elif v.kind != jn2[k].kind:
                debug "validate kind ", v.kind, " ; ", jn2[k].kind
                return false

        for k, v in jn2:
            if k notin jn1:
                debug "validate2 key ", k, " ; ", v.kind
                return false

            elif v.kind != jn1[k].kind:
                debug "validate2 kind ", v.kind, " ; ", jn1[k].kind
                return false

    elif jn1.kind == JArray:
        if jn1.len > 0 and jn2.len > 0:
            return jn1[0].kind == jn2[0].kind


proc putGbConfig(db: Database[AsyncMongo], jData: JsonNode): Future[JsonNode] {.async.} =
    result = newJObject()
    let loginResult = await login(db, jData)
    if loginResult.code == AdminLoginCode.login and loginResult.profile.checkPermission(apDbView):
        var cfgupd = jData["gb"]
        var cfkind = jData["kind"].getStr()
        let cfname = jData["name"].getStr()
        let prevname = jData{"prevname"}.getStr(cfname)

        var isConfigValid = true
        var defaultConfig: JsonNode
        if cfkind == "gb_common":
            defaultConfig = parseJson(commonBalanceData)
        elif cfkind == "gb_story":
            defaultConfig = parseJson(storyConfig)
        elif cfkind == "gb_daily":
            defaultConfig = parseJson(dailyConfig)
        elif cfkind == "gb_spins":
            defaultConfig = sharedPredefinedSpinsData()
        elif cfkind == "zsm":
            for zsm in DEFAULT_ZSMS:
                if cfgupd{"slot"} == zsm{"slot"}:
                    defaultConfig = zsm
                    break

        if not defaultConfig.isNil:
            isConfigValid = sameStructure(defaultConfig, cfgupd)

        if isConfigValid:
            var confDoc = newBsonDocument()

            confDoc["gb"] = cfgupd.toBson()
            confDoc["name"] = cfname.toBson()

            discard await db[cfkind].update(
                bson.`%*`({"name": prevname}),
                bson.`%*`({"$set": confDoc}),
                false, true
            )

            await gbChanged()

            result["status"] = %StatusCode.Ok.int
        else:
            result["status"] = %StatusCode.InvalidRequest.int

        result["requestId"] = %loginResult.nextSalt
    else:
        result["status"] = %StatusCode.LogginFailure.int

proc removeGbConfig(db: Database[AsyncMongo], jData: JsonNode): Future[JsonNode] {.async.} =
    result = newJObject()
    let loginResult = await login(db, jData)
    if loginResult.code == AdminLoginCode.login and loginResult.profile.checkPermission(apDbView):
        var cfkind = jData["kind"].getStr()
        let cfname = jData["name"].getStr()

        discard await db[cfkind].remove(bson.`%*`({"name": cfname}))
        await gbChanged()

        result["status"] = %StatusCode.Ok.int
        result["requestId"] = %loginResult.nextSalt
    else:
        result["status"] = %StatusCode.LogginFailure.int

proc testZsmConfig(db: Database[AsyncMongo], jData: JsonNode): Future[JsonNode] {.async.} =
    result = newJObject()
    let loginResult = await login(db, jData)
    if loginResult.code == AdminLoginCode.login and loginResult.profile.checkPermission(apDbView):
        result["status"] = %StatusCode.Ok.int
        result["requestId"] = %loginResult.nextSalt

        let cfname = jData["name"].getStr()
        let spins = jData{"spins"}.getInt(1_000_000)

        let zsm = (await db["zsm"].find(
            bson.`%*`({"name": cfname})
        ).one()).toJson()

        if "stat" notin zsm:
            result["stat"] = newJObject()
        else:
            result["stat"] = zsm["stat"]

        let (key, stat) = startTest(cfname, zsm["gb"], spins)
        result["stat"][key] = stat


proc getTestZsmConfigResult(db: Database[AsyncMongo], jData: JsonNode): Future[JsonNode] {.async.} =
    result = newJObject()
    let loginResult = await login(db, jData)
    if loginResult.code == AdminLoginCode.login and loginResult.profile.checkPermission(apDbView):
        result["status"] = %StatusCode.Ok.int
        result["requestId"] = %loginResult.nextSalt

        let cfname = jData["name"].getStr()
        let zsm = await db["zsm"].find(
            bson.`%*`({"name": cfname})
        ).oneOrNone()

        if zsm.isNil or "stat" notin zsm:
            result["stat"] = newJObject()
        else:
            result["stat"] = zsm["stat"].toJson()

proc handleAdminCommand*(cmd: string, db: Database[AsyncMongo], jData: JsonNode): Future[JsonNode] {.async.}=
    var resp: JsonNode
    try:
        resp = await adminRoutes[cmd](db, jData)
    except:
        resp = %"@<#%^$%>!"
    result = resp

adminRoutes["login"]      = loginHandler
adminRoutes["dbSearch"]   = dbSearchHandler
adminRoutes["dbView"]     = dbViewHandler
adminRoutes["getSalt"]    = getSaltHandler
adminRoutes["approvep"]   = approvePermissions
adminRoutes["allBros"]    = dbSearchBros
adminRoutes["removeBro"]  = removeBroHandler
adminRoutes["applyDiff"]  = applyDifferenceHandler
adminRoutes["getMongoStats"]   = mongoStatsHandler
adminRoutes["getFindQueries"]  = getFindQueries
adminRoutes["addFindQuery"]    = addFindQuery
adminRoutes["removeFindQuery"] = removeFindQuery
adminRoutes["applyProfile"]    = applyProfile
adminRoutes["sendMsg"]         = sendMessage

# tournaments / push configs
adminRoutes["pullConfig"] = pullConfig
adminRoutes["pushConfig"] = pushConfig
adminRoutes["createTournament"] = createTournament

# game balance, quests, zsm configs
adminRoutes["getBalanceConfigs"] = getGbConfigs
adminRoutes["putBalanceConfig"] = putGbConfig
adminRoutes["removeBalanceConfig"] = removeGbConfig
adminRoutes["testZsmConfig"] = testZsmConfig
adminRoutes["getTestZsmConfigResult"] = getTestZsmConfigResult
