import asyncdispatch, tables, strutils, json, logging

import falconserver.slot.machine_base
import falconserver.slot.near_misses
import falconserver.common.bson_helper
import falconserver.common.db
import falconserver.common.ab_constants
import falconserver.common.game_balance
import falconserver.quest.quests_config
import falconserver.auth.profile

import nimongo / [ bson, mongo ]

proc create(zsm: Bson, slotName: string): SlotMachine =
    let initializer = slotMachineInitializers.getOrDefault(slotName)
    if not initializer.isNil:
        result = initializer(zsm.toJson())
    else:
        raise newException(Exception, "Slot machine " & slotName & " not registered")

proc loadZsm(db: Database[AsyncMongo], slotName, zsmName: string): Future[SlotMachine] {.async.} =
    var zsm = await db["zsm"].find(bson.`%*`({"name": zsmName})).oneOrNone()
    if not zsm.isNil and "gb" in zsm:
        result = zsm["gb"].create(slotName)

var slotMachineCache = newTable[string, SlotMachine]()

var rootConfigs: TableRef[string, JsonNode]
var gameBalances: TableRef[string, GameBalance]
var dailyConfigs: TableRef[string, DailyGeneratorConfig]
var storyConfigs: TableRef[string, StoryQuestConfig]
var clientConfigs: TableRef[string, JsonNode]
var predefinedSpins: TableRef[string, JsonNode]
var nearMissConfigs: TableRef[string, NearMissConfig]
var offersConfigs: TableRef[string, JsonNode]

proc init[T](t: var TableRef[string, T]) =
    t = newTable[string, T]()

proc initAllTables() =
    rootConfigs.init()
    gameBalances.init()
    dailyConfigs.init()
    storyConfigs.init()
    predefinedSpins.init()
    nearMissConfigs.init()
    clientConfigs.init()
    offersConfigs.init()
    slotMachineCache.init()
    warn "Reset game_balance cache!"

initAllTables()

proc loadBallance*(db: Database[AsyncMongo], collection, gbName: string): Future[JsonNode] {.async.} =
    var gb = await db[collection].find(bson.`%*`({"name": gbName})).oneOrNone()
    if not gb.isNil and "gb" in gb:
        result = gb["gb"].toJson()

proc getBalanceConfig[T](cache: TableRef[string, T], key, dbkey: string, deserializer: proc(j:JsonNode): T, defaultVal: T): Future[T] {.async.} =
    result = cache.getOrDefault(key)
    if result.isNil:
        if key.len != 0:
            let data = await sharedDb().loadBallance(dbkey, key)
            if not data.isNil: result = deserializer(data)
        if result.isNil: result = defaultVal
        cache[key] = result

proc getBalanceConfig[T](cache: TableRef[string, T], key, dbkey: string, gb: GameBalance, deserializer: proc(gb: GameBalance, j:JsonNode): T, defaultVal: T): Future[T] {.async.} =
    result = cache.getOrDefault(key)
    if result.isNil:
        if key.len != 0:
            let data = await sharedDb().loadBallance(dbkey, key)
            if not data.isNil: result = deserializer(gb, data)
        if result.isNil: result = defaultVal
        cache[key] = result

proc getRootConfig(prf: Profile): Future[JsonNode] {.async.} =
    proc deser(x: JsonNode): JsonNode = x
    result = await getBalanceConfig(rootConfigs, prf.abTestConfigName, "gb_config", deser, nil)

proc getSlotMachineByGameID*(prf: Profile, slotName: string): Future[SlotMachine] {.async.} =
    let rootConfig = await prf.getRootConfig()

    let zsms = rootConfig{"zsm"}
    let zsmName = zsms{slotName}.getStr()
    let cacheKey = slotName & ":" & zsmName
    result = slotMachineCache.getOrDefault(cacheKey)

    if result.isNil:
        if zsmName.len == 0 or zsmName == slotName.abDefaultSlotZsmName:
            result = getSlotMachineByGameID(slotName)
        else:
            result = await sharedDB().loadZsm(slotName, zsmName)
            if result.isNil:
                warn "ZSM Not found ", zsmName
                result = getSlotMachineByGameID(slotName)
                if result.isNil:
                    raise newException(Exception, "Slot machine not registered: " & slotName)

        slotMachineCache[cacheKey] = result

proc getMachineIdByGameId*(prf: Profile, gameID: string): Future[string] {.async.} =
    let m = await prf.getSlotMachineByGameID(gameId)
    result = m.getSlotID()

proc getGameBalance*(prf: Profile): GameBalance =
    prf.gconf.getGameBalance()

proc getStoryConfig*(prf: Profile): seq[QuestConfig] =
    prf.gconf.getStoryConfig()

proc getDailyConfig*(prf: Profile): DailyGeneratorConfig =
    prf.gconf.getDailyConfig()

proc getClientConfig*(prf: Profile): JsonNode =
    prf.gconf.getClientConfig()

proc predefinedSpin*(prf: Profile, gameSlotID: string, step: int): Bson =
    prf.gconf.predefinedSpin(gameSlotID, step)

proc nearMissConfig*(prf: Profile): NearMissConfig =
    prf.gconf.nearMissConfig()

proc loadGameBalance*(prf: Profile) {.async.} =
    let deser = proc(j: JsonNode): JsonNode = j

    let rootConfig = await prf.getRootConfig()
    prf.gconf = GameplayConfig.new
    prf.gconf.gameBalance = await getBalanceConfig(gameBalances, rootConfig{"balance"}.getStr("default"), "gb_common", parseBalance, sharedGameBalance())
    proc parseStory(conf: JsonNode): StoryQuestConfig = newStoryQuestConfig(parseStoryConfig(conf))
    prf.gconf.storyConfig = await getBalanceConfig(storyConfigs, rootConfig{"storyQuest"}.getStr("default"), "gb_story", parseStory, getDefaultQuestConfig)
    prf.gconf.dailyConfig = await getBalanceConfig(dailyConfigs, rootConfig{"dailyQuest"}.getStr("default"), "gb_daily", prf.gconf.gameBalance, parseDailyConfig, sharedDailyGeneratorConfig())
    prf.gconf.predefinedSpinsData = await getBalanceConfig(predefinedSpins, rootConfig{"predefinedSpins"}.getStr("default"), "gb_spins", deser, sharedPredefinedSpinsData())
    prf.gconf.nearMissesConfig = await getBalanceConfig(nearMissConfigs, rootConfig{"nearMisses"}.getStr("default"), "gb_nearmisses", parseNearMisses, sharedNearMissData())
    prf.gconf.clientConfig = await getBalanceConfig(clientConfigs, rootConfig{"clientConfig"}.getStr("default"), "gb_client", deser, nil)

proc isBalanceConfigUpToDate(): Future[bool] {.async.} =
    var lastUpdEpoch {.global.} = 0.0
    var lastUpd = await sharedDB()["gb_lastUpdate"].find(bson.`%*`({"gb": "gb_check"})).oneOrNone()
    if not lastUpd.isNil and "last_update" in lastUpd:
        var dbLastEpoch = lastUpd["last_update"].toFloat64()
        if abs(dbLastEpoch - lastUpdEpoch) > 0.01:
            lastUpdEpoch = dbLastEpoch
            return false
    return true

proc watchBalanceConfigUpdates*() {.async.} =
    while true:
        let uptodate = await isBalanceConfigUpToDate()
        if not uptodate:
            initAllTables()
        await sleepAsync(20 * 1000) # 20 seconds
