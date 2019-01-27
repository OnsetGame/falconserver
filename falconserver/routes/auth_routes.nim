import json, strutils, asyncdispatch, httpcore, strtabs, oids, times, logging
import nuuid

import falconserver.nester
import falconserver / common / [ checks, config, db, message, notifications,
                                 response, cheats, game_balance, bson_helper, staging, orm,
                                 stats, get_balance_config ]
import falconserver / auth / [ profile, profile_types, profile_random, profile_migration, session,
                               profile_helpers ]

import falconserver / quest / [ quest, quest_manager, quest_types ]
import falconserver.map.building.builditem
import falconserver / map / [ collect, map ]
import falconserver.tutorial.tutorial_server
import falconserver.boosters.boosters
import falconserver.free_rounds.free_rounds

import nimongo / [ mongo, bson ]
import tables
import decision_maker

proc getMongoTime(): float =
    # TODO: Complete this
    epochTime()

let dbTimeDiff = epochTime() - getMongoTime()

proc findProfileByFBId*(id: string): Future[Profile] {.inline.} =
    findProfile($prfFBToken, id.toBson())

proc linkFacebookProfile(deviceProfile: Profile, facebookId: string, linkType: LinkFacebookType = lftNone): Future[(LinkFacebookResults, LinkFacebookRestartApp)] {.async.} =
    var facebookProfile = await findProfileByFBId(facebookId)
    var appNeedsRestart = false
    var linkResult = larHasBeenLinked

    if facebookProfile.isNil:
        deviceProfile.fbToken = facebookId
        await deviceProfile.commit()
    else:
        if facebookProfile.id == deviceProfile.id:
            linkResult = larHasBeenAlreadyLinked
        else:
            case linkType:
            of lftNone:
                linkResult = larCollision
            of lftDevice:
                deviceProfile.fbToken = facebookId
                linkResult = larHasBeenLinked
                await deviceProfile.commit()
                await facebookProfile.removeProfile()
            of lftFacebook:
                facebookProfile.androidPushToken = deviceProfile.androidPushToken
                linkResult = larHasBeenLinked
                appNeedsRestart = true
                await facebookProfile.commit()
                await deviceProfile.removeProfile()

    result = (linkResult, appNeedsRestart)

proc setInitialSlotOnMap(p: Profile, bi: BuildingId)=
    let key = "initial_slot"
    let val = bi.int.toBson()
    p.setClientState(key, val)

let router = sharedRouter()

proc genPassword(): string =
    result = newString(10)
    for i in 0 ..< result.len:
        result[i] = char(random(ord('0') .. ord('z')))

proc setupInitialABTestParams(p: Profile) =
    let initialLevelData= p.getGameBalance().levelProgress[0]
    let initBucks = initialLevelData.getRewardAmount(prfBucks)
    let initParts = initialLevelData.getRewardAmount(prfParts)
    let initChips = initialLevelData.getRewardAmount(prfChips)

    p.chips = initChips
    p.bucks = initBucks
    p.parts = initParts

proc loginWithProfile(profile: Profile, justRegistered: bool, requestBody: JsonNode): Future[JsonNode] {.async.} =
    var profile = profile
    let resp = newJObject()
    result = resp
    let oldPrfVer = profile.version
    let newProfile = await validateProfile(profile)
    if newProfile.version > oldPrfVer:
        resp["migrated"] = %true
    profile = newProfile
    if profile.password.len == 0:
        profile.password = genPassword()
    let sessionId = genOid()
    profile["session"] = sessionId.toBson()

    if profile.statistics.registrationTime == 0.0:
        profile.statistics.registrationTime = epochTime()

    let gb = profile.getGameBalance()

    # fix for level cap in case of balance change
    if profile.level > gb.levelProgress.len:
        echo "Warning: reducing profile level ", profile.level, " to ", gb.levelProgress.len
        profile.level = gb.levelProgress.len
        profile.experience = gb.levelProgress[profile.level - 1].experience
    elif profile.level == gb.levelProgress.len and profile.experience > gb.levelProgress[profile.level - 1].experience:
        echo "Warning: reducing profile experience ", profile.level, " to ", gb.levelProgress[profile.level - 1].experience
        profile.experience = gb.levelProgress[profile.level - 1].experience

    var qman = newQuestManager(profile)
    if justRegistered or profile{$prfState,"initial_slot"}.isNil: ## first login or reset_progress cheat used
        let firstTarget = dreamTowerSlot
        profile.setInitialSlotOnMap(firstTarget)
    if not qman.isFirstTaskCompleted():
        resp["sceneToLoad"] = %($profile.getInitialSlot())
        for bq in profile[$prfQuests]:
            if bq[$qfId].toInt() == QUEST_GEN_START_ID:
                bq[$qfStatus] = QuestProgress.InProgress.int32.toBson()
                break
    qman.ensureLevelUpQuestExists()
    if "randomSeed" in requestBody:
        let randomSeed = requestBody["randomSeed"].getInt().int32
        echo "randomSeed = ", randomSeed
        profile.randomize(randomSeed)

    if justRegistered:
        profile.setupInitialABTestParams()

    qman.saveChangesToProfile()
    profile.timeZone = requestBody{"timeZone"}.getInt()
    var tInfo = (epochTime() - profile.timeZone.float).fromSeconds().getGMTime()
    #info "Client local hour = ", tInfo.hour, ",  diff with tz0 = ", profile.timeZone, " seconds"

    if verifyCheats(profile):
        resp["isBro"] = %true

    resp["pid"] = % $profile.id
    resp["trt"] = profile.getClientConfig()

    if justRegistered:
        let abTestDescription = profile.abTestDescription
        if abTestDescription.len != 0:
            resp["ab"] = %abTestDescription

    resp["pw"]          = % profile.password
    resp["sessionId"]   = % $sessionId
    resp["serverTime"]  = %(epochTime() - dbTimeDiff)
    resp["quests"]      = newQuestManager(profile).questsForClient()
    resp["name"]        = newJString(profile.name)
    resp["title"]       = newJString(profile.title)
    resp["bucks"]       = newJInt(profile.bucks)
    resp["chips"]       = newJInt(profile.chips)
    resp["parts"]       = newJInt(profile.parts)
    resp["tourPoints"]  = newJInt(profile.tourPoints)
    resp["pvpPoints"]   = newJInt(profile.pvpPoints)
    resp["xp"]          = newJInt(profile.experience)
    resp["txp"]         = %gb.levelProgress[profile.level - 1].experience
    resp["lvl"]         = newJInt(profile.level)
    resp["vipPoints"]   = newJInt(profile.vipPoints)
    resp["vip"]         = %{"points": newJInt(profile.vipPoints), "level": newJInt(profile.vipLevel)}
    resp["exchangeNum"] = profile[$prfExchangeNum].toJson()
    resp["avatar"]      = newJInt(profile.portrait)
    resp["gb"]          = gb.toJson()
    resp["state"]       = profile.getClientState()
    resp["tutorial"]    = profile.tutorialStateForClient()
    resp["questConfig"] = qman.questsConfigForClient()
    resp["cronTime"]    = %profile.nextExchangeDiscountTime

    resp["gdpr"]        = %profile.gdpr
    if not profile.gdpr:
        let initialLevelData = profile.getGameBalance().levelProgress[0]
        let initChips = initialLevelData.getRewardAmount(prfChips)
        resp["gdprReward"]  = %initChips

    let allowedBets = gb.betLevelsForClient(profile.level)
    resp["allBets"] = %gb.bets
    resp["maxBet"] = %(allowedBets.len - 1)

    resp["gifts"] = json.`%*`({
        "bucksForInvite": sharedGameBalance().gifts.bucksForInvite,
        "chipsPerDailyGift": sharedGameBalance().gifts.chipsPerDailyGift})

proc bodyJson(r: Request): JsonNode =
    try:
        result = parseJson(r.body)
    except:
        result = newJObject()

proc protoVersion(request: Request): int =
    let clientProtoVersion = request.headers["Falcon-Proto-Version"]
    if clientProtoVersion.len > 0:
        result = parseInt(clientProtoVersion)

router.routes:
    post "/auth/login":
        let clientVersion = request.clientVersion()

        if isMaintenanceInProgress(clientVersion, request):
            respJson Http200, maintenanceInProgress()
            return

        if not isClientVersionAllowable(clientVersion, request):
            respJson Http200, oldClientVersion()
            return

        var clientProtocolVersion = request.protoVersion
        var versionOk = isServerCompatibleWithClientProtocolVersion(clientProtocolVersion)

        if versionOk:
            var profile: Profile
            if profile.isNil:
                let profileId = string(request.headers.getOrDefault("Falcon-Prof-Id"))
                let password = string(request.headers.getOrDefault("Falcon-Pwd"))
                if profileId.len > 0 and password.len > 0:
                    profile = await findProfileById(parseOid(profileId))
                    if profile.isNil or profile.password != password:
                        warn "Wrong password \"", password, "\" for profile ", profileId
                        profile = nil

            let justRegistered = profile.isNil
            if profile.isNil:
                await reportNewUser()
                profile = newProfile(profilesDB())
                await profile.commit() # Commit here to get a proper profile ID
            else:
                if profile.isBro and profile.fbToken.len > 0:
                     let profileCheating = await sharedDB()[MongoCollectionCheaters].find(bson.`%*`({$prfFbToken: profile.fbToken})).oneOrNone()
                     if profileCheating.isNil:
                        echo "Saving cheating grant for profile for FB ", profile.fbToken
                        discard await sharedDB()[MongoCollectionCheaters].insert(bson.`%*`({$prfFbToken: profile.fbToken}))
                await tryReportActiveUser(profile)

            profile.sessionPlatform = string(request.headers.getOrDefault("Falcon-Platform"))
            if profile.sessionPlatform.len == 0:
                profile.sessionPlatform = "UNKNOWN"

            await profile.loadGameBalance()

            let resp = await loginWithProfile(profile, justRegistered, request.bodyJson)
            await profile.cleanupNotifications(profile.statistics.lastRequestTime)
            await profile.notifyLongTimeNoSeeAfterLogin()
            await profile.commit()

            resp["collectConfig"] = profile.collectConfig()
            resp["boosterRates"] = profile.gconf.ratesResp(profile.boosters)
            resp["boosters"] = profile.boosters.stateResp()

            #info "loginOrRegister done, profileID = ", profile.id, ", fbID = ", facebookId, ", sessId = ", profile["session"]

            await resp.updateWithFreeRounds(profile.id)
            respJson Http200, resp
        elif clientProtocolVersion > protocolVersion and not isStage:
            respJson Http200, json.`%*`({"apiUrl" : stageApiUrl})
        else:
            respJson cast[HttpCode](426), json.`%*`({"status" : "Wrong client protocol", "serverVersion": protocolVersion})
