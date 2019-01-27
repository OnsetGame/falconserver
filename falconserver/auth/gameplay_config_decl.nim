import json
export json

import falconserver.common.game_balance
export game_balance

import falconserver.quest.quest_config_decl
export quest_config_decl

import falconserver.slot.near_misses
export near_misses


type GameplayConfig* = ref object of RootObj
    gameBalance*: GameBalance
    storyConfig*: StoryQuestConfig
    dailyConfig*: DailyGeneratorConfig
    offersConfig*: JsonNode
    clientConfig*: JsonNode
    predefinedSpinsData*: JsonNode
    nearMissesConfig*: NearMissConfig
