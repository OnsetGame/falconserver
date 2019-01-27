when defined(client):
    {.error.}

import tables
export tables


import falconserver.map.building.builditem
export builditem

import falconserver / common / currency
export currency

import shafa / game / [ feature_types, narrative_types, reward_types ]
export feature_types, narrative_types

import quest_decl
export quest_decl

type QuestConfig* = ref object of RootObj
    quest*: Quest
    rewards*: seq[Reward]
    depsStr*: seq[string]
    name*: string
    deps*:seq[QuestConfig]
    opens*: seq[QuestConfig]
    price*: int
    currency*: Currency
    target*: string
    time*: float
    autoComplete*: bool
    lockedByLevel*: int
    lockedByVipLevel*: int
    zoneImageTiledProp*: string
    decoreImageTiledProp*: string
    isMainQuest*: bool
    enabled*: bool
    vipOnly*: bool
    unlockFeature*: FeatureType
    narrative*: NarrativeData
    bubbleHead*: string

const notLockedByLevel* = -1


type StoryQuestConfig* = ref object
    configs: OrderedTable[int, QuestConfig]

template configs*(s: StoryQuestConfig): OrderedTable[int, QuestConfig] =  s.configs
template `configs=`*(s: StoryQuestConfig, v: OrderedTable[int, QuestConfig]) = s.configs = v


type
    StageConfig* = ref object
        difficulty*: DailyDifficultyType
        taskType*: string # may be empty

    DailyOnLevel* = seq[QuestTask]

    DailyGeneratorConfig* = ref object of RootObj
        stagesCyclicFrom*: int
        slotStages*:  Table[BuildingId, seq[StageConfig]]
        rewards*: Table[DailyDifficultyType, seq[Reward]]
        skipCost*: Table[DailyDifficultyType, int]
        tasks*:   Table[DailyDifficultyType, seq[DailyOnLevel]]
