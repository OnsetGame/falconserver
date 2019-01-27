import json, tables
import nimongo.bson

import gameplay_config_decl
export gameplay_config_decl

import falconserver.quest.quests_config
export quests_config


proc getGameBalance*(gconf: GameplayConfig): GameBalance =
    if gconf.gameBalance.isNil:
        gconf.gameBalance = sharedGameBalance()
    gconf.gameBalance

proc getStoryConfig*(gconf: GameplayConfig): seq[QuestConfig] =
    if gconf.storyConfig.isNil:
        gconf.storyConfig = getDefaultQuestConfig()

    result = newSeq[QuestConfig](gconf.storyConfig.configs.len)
    
    var i = 0
    for value in gconf.storyConfig.configs.values():
        result[i] = value
        i.inc

proc getDailyConfig*(gconf: GameplayConfig): DailyGeneratorConfig =
    if gconf.dailyConfig.isNil:
        gconf.dailyConfig = sharedDailyGeneratorConfig()
    gconf.dailyConfig

proc getClientConfig*(gconf: GameplayConfig): JsonNode =
    if gconf.clientConfig.isNil:
        gconf.clientConfig = newJObject()
    gconf.clientConfig

proc predefinedSpin*(gconf: GameplayConfig, gameSlotID: string, step: int): Bson =
    if gconf.predefinedSpinsData.isNil:
        getPredefinedSpin(gameSlotID, step, sharedPredefinedSpinsData())
    else:
        getPredefinedSpin(gameSlotID, step, gconf.predefinedSpinsData)

proc nearMissConfig*(gconf: GameplayConfig): NearMissConfig =
    if gconf.nearMissesConfig.isNil:
        gconf.nearMissesConfig = sharedNearMissData()
    gconf.nearMissesConfig
