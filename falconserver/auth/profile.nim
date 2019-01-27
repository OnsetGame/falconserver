import json, oids, times, sets, asyncdispatch
import nimongo / [ mongo, bson ]

import falconserver / common / [ bson_helper, game_balance, db, orm, currency ]
import falconserver / auth / [ profile_types, profile_stats ]
import falconserver.map.building.builditem
import falconserver / quest / [ quests_config ]
import falconserver.slot.near_misses
import gameplay_config
export gameplay_config

export profile_stats, profile_types, orm


CachedObj FortuneWheelState:
    lastFreeTime: float64("t")
    countSinceFree: int("c")
    history: Bson("h")
    freeSpinsLeft: int("fs")


TransparentObj Profile:
    id: Oid($prfId, "id")
    password: string($prfPassword, "password")
    abTestConfigName: string($prfABTestConfig, "abTestConfigName")
    abTestDescription: string

    name: string($prfName, "name")
    nameChanged: int($prfNameChanged, $prfNameChanged)
    title: string($prfTitle, "name")
    timeZone: int($prfTimeZone)

    bucks: int64($prfBucks, $prfBucks)
    chips: int64($prfChips, $prfChips)
    parts: int64($prfParts, $prfParts)
    exchangeNum: Bson($prfExchangeNum, "exchangeNum")   # struct
    cheats: Bson($prfCheats, "cheats")  # ???

    tourPoints: int64($prfTourPoints, "tourPoints")
    pvpPoints: int64($prfPvpPoints, "pvpPoints")

    experience: int($prfExperience, "experience")
    level: int($prfLevel, "level")
    vipPoints: int64($prfVipPoints, "vipPoints")
    vipLevel: int64($prfVipLevel, "vipLevel")

    frame: int($prfFrame, "frame")
    portrait: int($prfPortrait, "portrait")

    messages: Bson($prfMessages, "messages")   # array
    achieves: Bson($prfAchieves, "achieves")   # ???

    statisticsB: Bson($prfStatistics, "statistics")  # struct
    prevRequestTime: float

    state: Bson($prfState)

    quests: Bson($prfQuests, "quests")
    nextExchangeDiscountTime: float64($prfNextExchangeDiscountTime)
    questsGenId: int($prfQuestsGenId, "questsGenId")
    tutorialState: Bson($prfTutorialState, $prfTutorialState)
    slotQuests: Bson($prfSlotQuests)

    fbToken: string($prfFBToken, "fbToken")
    version: int($prfVersion, "version")
    isBro: bool($prfIsBro, $prfIsBro)

    fortuneWheelB: Bson($prfFortuneWheel)

    boughtSpecialOffer: bool($prfSpecialOffer, $prfSpecialOffer)

    boostersData: Bson($prfBoosters)

    randomState0: int64("randomState0")
    randomState1: int64("randomState1")

    gconf: GameplayConfig

    androidPushToken: string($prfAndroidPushToken)
    iosPushToken: string($prfIosPushToken)
    sessionPlatform: string($prfSessionPlatform)

    gdpr: bool("gdpr")


proc statistics*(p: Profile): ProfileStats =
    result.new()
    if p.statisticsB.isNil:
        p.statisticsB = newBsonDocument()
    else:
        p.changedFields.incl($prfStatistics)
    result.init(p.collection, p.statisticsB)

proc `statistics=`*(p: Profile, s: ProfileStats) =
    p.statisticsB = s.mongoSetDict()
    p.changedFields.incl($prfStatistics)

proc fortuneWheelState*(p: Profile): FortuneWheelState =
    result.new()
    if p.fortuneWheelB.isNil:
        p.fortuneWheelB = newBsonDocument()
    else:
        p.changedFields.incl($prfFortuneWheel)
    result.init(p.collection, p.fortuneWheelB)

proc `fortuneWheelState=`*(p: Profile, s: FortuneWheelState) =
    p.fortuneWheelB = s.mongoSetDict()
    p.changedFields.incl($prfFortuneWheel)

proc wheelStateToBson*(s:FortuneWheelState): Bson =
    if s.history.isNil:
        s.history = bson.`%*`([])
    bson.`%*`({"t": s.lastFreeTime, "c": s.countSinceFree, "h": s.history, "fs": s.freeSpinsLeft})

proc newProfile*(c: Collection[AsyncMongo], b: Bson): Profile =
    result.new()
    result.gconf = GameplayConfig.new
    result.init(c, b)

proc findProfile*(id: Oid): Future[Profile] {.async.} =
    let b = await profilesDB().find(bson.`%*`({"_id": id})).oneOrNone()
    if not b.isNil:
        result = newProfile(profilesDB(), b)

proc removeProfile*(p: Profile) {.async.} =
    await profilesDB().removeWithCheck(bson.`%*`({"_id": p.id}))

const
    INITIAL_BUCKS*             =  0'i64 #50'i64
    INITIAL_CHIPS*             =  0'i64 #100000'i64
    INITIAL_LEVEL*             =  1'i64
    INITIAL_PVP_POINTS*        =  0'i64
    INITIAL_TOURNAMENT_POINTS* =  0'i64
    INITIAL_VIP_LEVEL*         = -1'i64
    INITIAL_VIP_POINTS*        =  0'i64
    INITIAL_XP*                =  0'i64
    INITIAL_PARTS*             =  0'i64 #600'i64
    PROFILE_VERSION*           =  14'i64

proc newProfile*(c: Collection[AsyncMongo]): Profile {.gcsafe.} =
    let initialLevelData = sharedGameBalance().levelProgress[0]
    let initBucks = initialLevelData.getRewardAmount(prfBucks)
    let initChips = initialLevelData.getRewardAmount(prfChips)
    let initParts = initialLevelData.getRewardAmount(prfParts)
    ## Empty profile constructor
    result = newProfile(c, bson.`%*`({
        $prfName:       null(),
        $prfNameChanged: 0,
        $prfTitle:      null(),

        $prfBucks:      initBucks,
        $prfChips:      initChips,
        $prfParts:      initParts,

        $prfExchangeNum: bson.`%*`({
            $prfChips: 0,
            $prfParts: 0
            }),

        $prfCheats:     newBsonDocument(),

        $prfTourPoints: INITIAL_TOURNAMENT_POINTS,
        $prfPvpPoints:  INITIAL_PVP_POINTS,

        $prfExperience: INITIAL_XP,
        $prfLevel:      INITIAL_LEVEL,
        $prfVipPoints:  INITIAL_VIP_POINTS,
        $prfVipLevel:   INITIAL_VIP_LEVEL,

        $prfFrame:      pfFrame0.int,
        $prfPortrait:   ppNotSet.int,

        $prfMessages:   newBsonArray(),
        $prfAchieves:   newBsonArray(),

        $prfState:   newBsonDocument(),

        $prfQuests:     newBsonArray(),
        $prfNextExchangeDiscountTime: 0.0'f64,
        $prfQuestsGenId:  QUEST_GEN_START_ID,

        $prfTutorial:      null(),
        $prfIntroSlot:     dreamTowerSlot.int,
        $prfTutorialState: binuser(""),

        $prfFBToken:    "",
        $prfVersion:    PROFILE_VERSION,
        $prfIsBro:      false,
        $prfSpecialOffer: false,
    }))

proc toJsonProfile*(p: Profile, full: bool = false): JsonNode =
    ## Return JSON representation of profile.
    ## It is used to pass to client, so do not need to contain
    ## any "secret" information
    result = json.`%*`({
        $prfName :      %p.name,
        $prfTitle:      %p.title,

        $prfBucks:      %p.bucks,
        $prfChips:      %p.chips,
        $prfParts:      %p.parts,
        $prfExchangeNum: %p[$prfExchangeNum].toJson(),

        $prfTourPoints: %p[$prfTourPoints].toInt64(),
        $prfPvpPoints:  %p[$prfPvpPoints].toInt64(),

        $prfExperience: %p.experience,
        $prfLevel:      %p.level,
        $prfVipPoints:  %p[$prfVipPoints].toInt64(),
        $prfVipLevel:   %p[$prfVipLevel].toInt(),

        $prfFrame:      %p[$prfFrame].toInt(),
        $prfPortrait:   %p[$prfPortrait].toInt(),

        $prfMessages:    p[$prfMessages].toJson(),
        $prfAchieves:    p[$prfAchieves].toJson(),
        $prfState:       p[$prfState][$steClient].toJson(),
        $prfQuests:      p[$prfQuests].toJson(),
        $prfNextExchangeDiscountTime: p.nextExchangeDiscountTime,

        $prfTutorial:    p[$prfTutorial].toJson(),
        $prfIntroSlot:  %p[$prfIntroSlot].toInt(),

        $prfFBToken:    %p[$prfFBToken].toString(),
        $prfVersion:    %p[$prfVersion].toInt()
    })

    # For `trusted` users
    if full:
        result[$prfDevices] = p[$prfDevices].toJson()
        result[$prfCheats]  = p[$prfCheats].toJson()

proc loggedInFacebook*(p: Profile): bool =
    ## Checks if tokens for social auth are stored
    ## in user's profile.
    if p{$prfFBToken}.isNil():
        return false
    else:
        return p[$prfFBToken].len() > 0

proc getWallet*(p: Profile): JsonNode =
    result = newJObject()
    result["chips"] = %p.chips
    result["bucks"] = %p.bucks
    result["parts"] = %p.parts
    result["tourPoints"] = %p.tourPoints

proc getClientState*(p:Profile): JsonNode =
    result = p[$prfState].toJson()

proc setClientState*[T](p: Profile, key: string, val: T) =
    p{$prfState,key} = val
    p.state = p.state  # to mark changes

proc deleteClientState*(p: Profile, key: string) =
    p{$prfState}.del key
    p.state = p.state  # to mark changes


proc incSpinOnSlot*(p: Profile, slotId: string)=
    var spinsStats = p.statistics.spinsOnSlots
    if spinsStats.isNil:
        spinsStats = newBsonDocument()

    var slotsStats = spinsStats{slotId}
    if slotsStats.isNil:
        slotsStats = 1.toBson()
    else:
        slotsStats = (slotsStats.toInt64() + 1'i64).toBson()
    spinsStats[slotId] = slotsStats
    p.statistics.spinsOnSlots = spinsStats


proc totalSpinsOnSlot*(p: Profile, slotId: string): int64 =
    var spinsStats = p.statistics.spinsOnSlots
    if not spinsStats.isNil and not spinsStats{slotId}.isNil:
        result = spinsStats[slotId].toInt64()


proc commitWithExtraQuery*(p: Profile, extraQuery: Bson): Future[StatusReply] {.async, deprecated.} =
    var query = extraQuery
    let qset = query["$set"]
    if "s" notin qset and "s.rt" notin qset:
        qset["s.rt"] = bson.`%*`(p.statistics.lastRequestTime)
    elif "s" in qset and "rt" notin qset["s"]:
        qset["s"]["rt"] = bson.`%*`(p.statistics.lastRequestTime)
    if p.randomState0 != 0  or  p.randomState1 != 0:
        qset["randomState0"] = bson.`%*`(p.randomState0)
        qset["randomState1"] = bson.`%*`(p.randomState1)
    result = await profilesDB().update(B("_id", p["_id"]), query, false, false)

proc tryWithdraw*(p: Profile, c: Currency, a: int64): bool=
    case c:
    of Currency.Chips:
        if p.chips >= a:
            p.chips = p.chips - a
            result = true

    of Currency.Bucks:
        if p.bucks >= a:
            p.bucks = p.bucks - a
            result = true

    of Currency.Parts:
        if p.parts >= a:
            p.parts = p.parts - a
            result = true

    of Currency.TournamentPoint:
        if p.tourPoints >= a:
            p.tourPoints = p.tourPoints - a
            result = true
    else:
        result = false
