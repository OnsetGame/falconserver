import json, logging, oids, sequtils, strutils, tables, times, osproc, cgi, asyncdispatch
import os except DeviceId
import httpcore except HttpMethod

import nuuid

import nimongo / [ bson, mongo]

import falconserver / [ schedule, nester ]
import falconserver / auth / [ profile, profile_random, profile_types, session, profile_helpers ]
import falconserver / quest / [ quest, generator, quest_manager, quest_types ]
import falconserver / map / [ collect, map, building/builditem ]
import falconserver / slot / [ slot_routes, slot_data_types, slot_context ]

import falconserver / common / [ checks, cheats, currency, currency_exchange, bson_helper, response, game_balance,
                                 orm, message, db, staging, stats, get_balance_config, config,
                                 response_wrapper ]

import falconserver / tournament / [ tournaments, tournament_routes ]
import falconserver / free_rounds / [ free_rounds, free_rounds_routes ]

import falconserver.tutorial.tutorial_server

import falconserver.common.notifications_routes
import falconserver.admin.admin_routes

import falconserver.fortune_wheel.fortune_wheel_routes

import falconserver / routes / [ auth_routes, push_token_update_routes ]
import falconserver.boosters.boosters_routes

const
    serverVersion = staticExec("git rev-parse HEAD")

var frontendURL = "https://game.onsetgame.com"
if isStage:
    frontendURL = "https://stage.onsetgame.com"

let startTime = epochTime()


proc checkSsid(request: Request): Future[Session] {.async.} =
    result = await getSession(request)
    if result.isNil:
        raise newException(Exception, "401")

template logReq() =
    echo "REQ:", request.body

template verifyStage() =
    if not isStage:
        resp Http404, "Not found"

proc urlWithParams(url: string, params: StringTableRef): string =
    result = url
    var i = 0
    for k, v in params:
        result &= (if i == 0: "?" else: "&")
        result &= encodeUrl(k)
        result &= "="
        result &= encodeUrl(v)
        inc i

let router = sharedRouter()

router.routes:
    get "/":
        redirect(frontendURL)

    post "/facebook-secure-url/":
        request.params["nocache"] = $epochTime()
        if request.params.hasKey("signed_request"):
            # Hide signed_request. Don't know why, it just feels more secure.
            request.params["signed_request"] = ""
        if request.params.hasKey("state"):
            let s = decodeUrl(request.params["state"])
            try:
                for kv in s.split("&"):
                    let kvc = kv.split("=")
                    if kvc.len == 2:
                        request.params[kvc[0]] = kvc[1]
                request.params["state"] = ""
            except:
                discard

        let url = urlWithParams(frontendURL, request.params)
        resp Http200, """<html><head><meta http-equiv="refresh" content="0; url=""" & url & "\"/></head></html>"

    get "/facebookpurchase":
        echo "__________FACEBOOK_PURCHASE: ", request.params["hub.verify_token"], " ", request.params["hub.mode"], " ", request.params["hub.challenge"]
        if request.params["hub.verify_token"] == "MY_TOKEN" and request.params["hub.mode"] == "subscribe":
            resp Http200, request.params["hub.challenge"]
        else:
            resp Http404, "Not found"

    post "/facebookpurchase":
        var body = parseJson(request.body)
        echo "__________FACEBOOK_PURCHASE_BODY: ", body

    post "/tutorial/step/{stepName}":
        let clRequest = await checkRequest(request)
        if clRequest.status != StatusCode.OK:
            respJson Http200, json.`%*`({"status": clRequest.status.int, "reason": clRequest.reason})
        else:
            let session = clRequest.session
            let stepName = @"stepName"
            var resp = newJObject()

            let tutorialId = try: parseEnum[TutorialState](stepName) except: tsInvalidStep
            if tutorialId > tsInvalidStep:
                session.profile[$prfTutorialState] = session.profile.completeTutorialState(tutorialId)
                resp["tutorial"] = session.profile.tutorialStateForClient()

                await session.profile.commit()
            else:
                resp["status"] = %StatusCode.InvalidRequest.int

            await wrapRespJson(clRequest.session.profile, resp, clRequest.clientVersion)
            respJson Http200, resp

    sessionPost "/collect/resources":
        var resp = newJObject()
        let fromstr = clRequest.body["from"].getStr()
        var currency = parseEnum[Currency](fromstr, Currency.Unknown)
        var currencies = newSeq[Currency]()
        if currency == Currency.Unknown:
            if fromstr == "all":
                currencies.add(Currency.Chips)
                currencies.add(Currency.Bucks)
        else:
            currencies.add(currency)

        for cur in currencies:
            session.profile.collectResource(cur)

        await session.profile.commit()

        resp["state"] = session.profile.getClientState()
        resp["wallet"] = session.profile.getWallet()
        resp["cronTime"] = %session.profile.nextExchangeDiscountTime
        resp["collectConfig"] = session.profile.collectConfig()

        await wrapRespJson(clRequest.session.profile, resp, clRequest.clientVersion)
        respJson Http200, resp

    sessionPost "/quests/{command}":
        let qman = newQuestManager(session.profile)
        let command = @"command"
        var (resp, statusCode) = await qman.proceedCommand(command, clRequest.body)

        if statusCode == StatusCode.OK:
            await session.profile.commit()

            var sceneId = ""
            if "sceneId" in clRequest.body:
                sceneId = clRequest.body["sceneId"].getStr()
                # echo "sceneId ", sceneId
                if sceneId != "Map":
                    let sc = await profile.getDefaultSlotContext(sceneId)
                    if not sc.state.isNil:
                        let qid = clRequest.body["questIndex"].getInt()
                        var bc = sc.getBets()
                        resp["betsConf"] = bc.toJson()

                    #echo "setup quests betConf ", resp

        resp["quests"] = qman.questsForClient()
        resp["lvlData"] = session.profile.getLevelData()
        resp["wallet"] = session.profile.getWallet()
        resp["state"] = session.profile.getClientState()
        resp["status"] = %statusCode.int
        resp["cronTime"] = %session.profile.nextExchangeDiscountTime
        resp["exchangeNum"] = %session.profile[$prfExchangeNum].toJson()
        resp["collectConfig"] = session.profile.collectConfig()

        await wrapRespJson(clRequest.session.profile, resp, clRequest.clientVersion)
        respJson Http200, resp

    sessionPost "/purchases/{targetLogic}":
        var resp = newJObject()

        if resp.isNil():
            respJson Http200, json.`%*`({"status": "Response is empty"})

        await clRequest.session.profile.commit()

        await wrapRespJson(clRequest.session.profile, resp, clRequest.clientVersion)
        respJson Http200, resp

    get "/purchases/fbproduct/{productId}":
        let id = @"productId"
        var resp = newJObject()

        respJson Http200, resp

    sessionPost "/store/get":
        var resp = newJObject()
        resp["status"] = %StatusCode.OK.int

        await wrapRespJson(clRequest.session.profile, resp, clRequest.clientVersion)
        respJson Http200, resp

    sessionPost "/profile/update":
        let questManager = newQuestManager(profile)
        questManager.onProfileChanged(profile)

        var resp = newJObject()

        # check for not completed level up
        let rews = questManager.getRewardsAndRemoveIfCompleted(qttLevelUp.int)
        questManager.saveChangesToProfile()
        if rews.len != 0:
            await profile.acceptRewards(rews, resp)
            let nextLvl = createLevelUpQuest(profile)
            if not nextLvl.isNil:
                profile[$prfQuests].add(nextLvl.toBson())
                questManager.onProfileChanged(profile)

        if "avatar" in requestBody:
            profile.portrait = requestBody["avatar"].getInt()

        if "name" in requestBody:
            let name = requestBody["name"].getStr()
            if profile[$prfNameChanged].isNil:
                profile[$prfNameChanged] = 0.toBson()

            # Check for test account
            const magicUsername = serverVersion.substr(0, 5).toLowerAscii()
            if name.len == magicUsername.len and name.toLowerAscii() == magicUsername:
                # The user needs to switch to another server. First change his
                # username back.
                if isStage:
                    # If we're on stage - switch to prod
                    resp["apiUrl"] = %prodApiUrl
                else:
                    # If we're on prod - switch to stage
                    resp["apiUrl"] = %stageApiUrl
            elif profile.name == name:
                discard
            else:
                profile.name = name
                profile.nameChanged = profile.nameChanged + 1

            resp["nameChanged"] = %profile.nameChanged

        resp["state"]       = profile.getClientState()
        resp["exchangeNum"] = profile[$prfExchangeNum].toJson()
        resp["tutorial"]    = profile.tutorialStateForClient()
        resp["quests"] = questManager.questsForClient()
        resp["cronTime"]    = %profile.nextExchangeDiscountTime
        resp["collectConfig"] = session.profile.collectConfig()

        let tournamentsFinished = await profile.findProfileTournamentsFinished()
        if tournamentsFinished > 0:
            resp["tournamentsFinished"] = %tournamentsFinished

        await profile.commit()
        resp["wallet"] = profile.getWallet()
        resp["boosters"] = profile.boosters.stateResp()

        await wrapRespJson(clRequest.session.profile, resp, clRequest.clientVersion)
        respJson Http200, resp

    post "/profile/exchange":
        # logReq
        let clRequest = await checkRequest(request)
        if clRequest.status != StatusCode.OK:
            respJson Http200, json.`%*`({"status": clRequest.status.int, "reason": clRequest.reason})
        else:
            let session = clRequest.session
            var cTo: Currency
            let clientResponse = newJObject()
            var status: int = 0

            if not clRequest.body["Falcon-Exchange-Currency-To"].isNil:
                cTo = clRequest.body["Falcon-Exchange-Currency-To"].getInt().Currency
            else:
                status = 1

            if status == 1: # Bad input
                clientResponse["status"] = %status
                respJson Http200, clientResponse
            else:
                let exchangeNums = session.profile[$prfExchangeNum]

                var exchangeKey = ""
                if cTo == Currency.Chips:
                    exchangeKey = $prfChips

                    if exchangeKey.len == 0: # incorrect currency to exchange
                        clientResponse["status"] = %3
                        respJson Http200, clientResponse
                    else:
                        let curT = epochTime()
                        if curT > session.profile.nextExchangeDiscountTime:
                            session.profile{$prfExchangeNum, $prfChips} = 0.toBson()
                            session.profile{$prfExchangeNum, $prfParts} = 0.toBson()
                            session.profile.nextExchangeDiscountTime = curT + session.profile.getGameBalance().exchangeDiscountTime

                        var exchNum = exchangeNums[exchangeKey].toInt()
                        let rates = exchangeRates(session.profile.getGameBalance(), exchNum, cTo)

                        if rates.bucks > session.profile.bucks: # Not enough bucks for exchange
                            clientResponse["status"] = %2
                            respJson Http200, clientResponse
                        else:
                            let exchangeResult = exchange(session.profile, exchNum, cTo)
                            inc exchNum

                            session.profile{$prfExchangeNum, exchangeKey} = exchNum.toBson()

                            clientResponse["status"] = %0
                            clientResponse[$Currency.Chips] = %session.profile.chips
                            clientResponse[$Currency.Bucks] = %session.profile.bucks
                            clientResponse[$Currency.Parts] = %session.profile.parts
                            clientResponse["exchangeNum"] = %session.profile[$prfExchangeNum].toJson()
                            clientResponse["critical"] = %exchangeResult.critical
                            clientResponse["cronTime"] = %session.profile.nextExchangeDiscountTime
                            await session.profile.commit()

                            await wrapRespJson(clRequest.session.profile, clientResponse, clRequest.clientVersion)
                            respJson Http200, clientResponse
                else:
                    clientResponse["status"] = %StatusCode.InvalidRequest.int
                    respJson Http200, clientResponse

    postEx "/ping", 2:
        let clRequest = await checkRequest(request)
        if clRequest.status != StatusCode.OK:
            respJson Http200, json.`%*`({"status": clRequest.status.int, "reason": clRequest.reason})
        else:
            var resp = newJObject()
            await wrapRespJson(clRequest.session.profile, resp, clRequest.clientVersion)
            respJson Http200, resp

    post "/profile/storage/{command}":
        logReq
        let clRequest = await checkRequest(request)
        if clRequest.status != StatusCode.OK:
            respJson Http200, json.`%*`({"status": clRequest.status.int, "reason": clRequest.reason})
        else:
            let session = clRequest.session
            var resp = newJObject()

            const prfSaveName = "save_name"
            let addString = clRequest.body{"save_name"}.getStr()

            case @"command":
            of "save":
                var bsProfile = session.profile.bson
                bsProfile[prfSaveName] = addString.toBson()

                for k in ["_id", $prfPassword, $prfFBToken]:
                    bsProfile.del(k)

                echo await sharedDB()[MongoCollectionSavedProfiles].update(
                    bson.`%*`({prfSaveName: addString}),
                    bsProfile,
                    false, true
                )

                resp{"status"}  = %"OK"

            of "restore":
                var savedProfile = await sharedDB()[MongoCollectionSavedProfiles].find(bson.`%*`({prfSaveName: addString})).oneOrNone()
                if not savedProfile.isNil:
                    savedProfile.del("_id")
                    savedProfile[$prfPassword] = session.profile.bson[$prfPassword]
                    savedProfile[$prfId] = session.profile.bson[$prfId]

                    let r = await profilesDB().update(B("_id", session.profile["_id"]), savedProfile, false, false)

                    # discard await session.profile.commitWithExtraQuery(B("$set", savedProfile))

                    resp{"status"} = %"OK"
                else:
                    resp{"status"}  = %"FALSE"

            of "getSaved":
                var savedProfileList = await sharedDB()[MongoCollectionSavedProfiles].find(bson.`%*`({})).all()
                var prList = newJArray()
                for sp in savedProfileList:
                    if prfSaveName in sp:
                        prList.add(sp[prfSaveName].toJson())

                resp{"saved_profiles"} = prList
                resp{"status"}  = %"OK"

            else:
                resp{"status"}  = %"FALSE"

            await wrapRespJson(clRequest.session.profile, resp, clRequest.clientVersion)
            respJson Http200, resp

    post "/message/{command}":
        # logReq
        let clRequest = await checkRequest(request)
        if clRequest.status != StatusCode.OK:
            respJson Http200, json.`%*`({"status": clRequest.status.int, "reason": clRequest.reason})
        else:
            let session = clRequest.session
            let jData = clRequest.body
            let command = @"command"
            let resp = await processMessage(command, jData, session.profile)

            if not jData{"target"}.isNil:
                let qman = newQuestManager(session.profile)
                for q in qman.initialQuests():
                    session.profile[$prfQuests].add(q.toBson())
                    session.profile[$prfQuests] = session.profile[$prfQuests]
                qman.updateFromProfile()
                qman.saveChangesToProfile()

                resp["quests"] = qman.questsForClient()

            await session.profile.commit()

            await wrapRespJson(clRequest.session.profile, resp, clRequest.clientVersion)
            respJson Http200, resp

    post "/user/gdpr":
        let clRequest = await checkRequest(request)
        if clRequest.status != StatusCode.OK:
            respJson Http200, json.`%*`({"status": clRequest.status.int, "reason": clRequest.reason})
        else:
            let jData = clRequest.body
            let profile = clRequest.session.profile

            let resp = %{"status": %StatusCode.OK.int}
            let gdpr = jData{"status"}.getBool()
            if profile.gdpr == gdpr:
                await wrapRespJson(clRequest.session.profile, resp, clRequest.clientVersion)
                respJson Http200, resp
                return

            profile.gdpr = gdpr
            if gdpr:
                let initialLevelData = profile.getGameBalance().levelProgress[0]
                let initChips = initialLevelData.getRewardAmount(prfChips)
                profile.chips = profile.chips + initChips
            await profile.commit()

            await wrapRespJson(clRequest.session.profile, resp, clRequest.clientVersion)
            respJson Http200, resp

    post "/cheats/{command}$":
        let command = @"command"
        let session = await checkSsid(request)
        let profile = session.profile

        if not verifyCheats(profile):
            var resp = newJObject()
            respJson Http200, resp

        elif command == "deleteProfile":
            await resetProgress(profile)
            discard await sharedDB()[MongoCollectionProfiles].remove(bson.`%*`({"_id": profile["_id"]}))
            respJson Http200, json.`%*`({"status": "Profile removed"})

        elif command == "slot":
            let
                jSpin = try: parseJson(request.body)
                        except: nil

            if jSpin == nil:
                respJson Http200, json.`%*`({"status": "Bad input"})
            else:
                var gameSlotID = $jSpin["machine"].getStr()

                let (err, sc) = await getSlotContext(profile, gameSlotID, jSpin)
                if not err.isNil:
                    if "status" in err:
                        err["reason"] = err["status"]
                    err["result"] = %false
                    err["status"] = %StatusCode.Ok.int
                    respJson Http200, err
                    return

                var cheatForNextSpin: JsonNode
                if "custom" in jSpin["value"].getStr():
                    cheatForNextSpin = jSpin[$sdtCheatSpin]
                else:
                    cheatForNextSpin = getCheatForMachine(profile, jSpin["value"].getStr(), jSpin["machine"].getStr())

                let cheatExist = not cheatForNextSpin.isNil
                if cheatExist:
                    var nextSpin = newBsonArray()
                    for v in cheatForNextSpin:
                        nextSpin.add(v.num.toBson())
                    sc.state[$sdtCheatSpin] = nextSpin
                    sc.state[$sdtCheatName] = jSpin["value"].getStr().toBson()

                await sc.saveStateAndProfile(sc.state)
                respJson Http200, json.`%*`({"success": cheatExist})

        else:
            var jData = try: parseJson(request.body) except: nil
            var resp = await proceedCheatsCommand(command, profile, jData)

            if not resp.isNil:
                if command != "reset_progress":  # we do straight bson dump to DB inside handler
                    await profile.commit()

                resp["status"] = %StatusCode.OK.int

            elif resp.isNil:
                resp = newJObject()
                resp["status"] = %StatusCode.InvalidRequest.int

            else: # cheats update command
                resp["status"] = %StatusCode.OK.int
            respJson Http200, resp

    getEx "/info", 2:
        if shouldLogRequests(2):
            echo "Memory stats: total: ", getTotalMem(), ", occupied: ", getOccupiedMem()
        # error "Not an error, /info requested. Memory stats: total: ", getTotalMem(), ", occupied: ", getOccupiedMem() # Hack to make logger flush.
        GC_fullCollect()

        let j = %{
            "version": %serverVersion,
            "protocolVersion": %protocolVersion,
            "uptime": %(epochTime() - startTime)
        }
        # error "Not an error. Info requested." # Hack to make logger flush.
        resp Http200, j.pretty()


    post "/admin/{command}":
        logReq
        echo "admin command: ", @"command"
        let clRequest = await checkRequest(request)
        if clRequest.status != StatusCode.OK:
            respJson Http200, json.`%*`({"status": clRequest.status.int, "reason": clRequest.reason})
        else:
            let r = await handleAdminCommand(@"command", sharedDB(), clRequest.body)
            respJson Http200, r

    get "/testcrash":
        verifyStage()
        var i : ptr int
        i[] = 5

    get "/testassert":
        verifyStage()
        var i = 5
        assert(i == 0)

    get "/testexception":
        verifyStage()
        raise newException(Exception, "Test exception")

proc getPort(): Port =
    let p = getEnv("FALCON_PORT")
    if p.len != 0:
        result = Port(parseInt(p))
    else:
        result = Port(5001)

## Running web server
import random
randomize()
setLogFilter(lvlDebug)
addHandler(newConsoleLogger())

var mongoUri = getEnv("FALCON_MONGO_URI")
if mongoUri.len == 0:
    mongoUri = "mongodb://localhost/falcon"

initDBWithURI(mongoUri)

asyncCheck runConfigUpdate()
asyncCheck router.serve(getPort())
asyncCheck runScheduleProcessing()
asyncCheck watchBalanceConfigUpdates()

runForever()
