when defined(client):
    {.error.}

import json, strutils, tables, math
import algorithm, logging

import falconserver.auth.profile_types

import falconserver.quest.quest
export quest

import falconserver.quest.quest_task
export quest_task

import falconserver.common.game_balance
export game_balance

const configPath = "../resources/quests/"

const storyConfig* = staticRead(configPath & "story.json")
var storyConfigJson* {.threadvar.}: JsonNode
proc getStoryConfigJson*(): JsonNode {.gcsafe.} = 
    if storyConfigJson.isNil:
        storyConfigJson = parseJson(storyConfig)
    result = storyConfigJson
const dailyConfig* = staticRead(configPath & "daily.json")
var dailyConfigJson* {.threadvar.}: JsonNode
proc getDailyConfigJson*(): JsonNode {.gcsafe.} = 
    if dailyConfigJson.isNil:
        dailyConfigJson = parseJson(dailyConfig)
    result = dailyConfigJson

import quest_config_decl
export quest_config_decl

import shafa / game / [ narrative_types, reward_types ]


##
proc newStoryQuestConfig*(v: OrderedTable[int, QuestConfig]): StoryQuestConfig =
  new(result)
  result.configs = v

var storyQuestConfig = new(StoryQuestConfig)
template getDefaultQuestConfig*(): StoryQuestConfig = storyQuestConfig
# template storyQuestConfigs*(): seq[QuestConfig] = storyQuestConfig.configs


proc getQuestConfigsForFeature*(sqc: seq[QuestConfig], f: FeatureType): seq[QuestConfig] =
    result = newSeq[QuestConfig]()
    for conf in sqc:
        if conf.unlockFeature == f:
            result.add(conf)


## ------------------------------------| STORY QUEST CONFIG |----------------------------

proc toJson*(qc: QuestConfig): JsonNode =
    result = newJObject()
    result["name"] = %qc.name
    result["price"] = %qc.price
    result["currency"] = %qc.currency
    result["time"] = %qc.time
    result["id"] = %qc.quest.id
    result["image_zone"] = %qc.zoneImageTiledProp
    result["image_decore"] = %qc.decoreImageTiledProp
    result["target"] = %qc.target
    result["ismain"] = %qc.isMainQuest

    result["lvl"] = %qc.lockedByLevel
    result["vip"] = %qc.lockedByVipLevel
    result["enabled"] = %qc.enabled
    result["unlock_feature"] = %qc.unlockFeature
    result["vip_only"] = %qc.vipOnly
    if not qc.narrative.isNil:
        result["narrative"] = qc.narrative.toJson()
    result["bubble_head"] = %qc.bubbleHead

    result["rews"] = newJArray()
    for r in qc.rewards:
        result["rews"].add(r.toJson())

    result["d"] = newJArray()
    for d in qc.deps:
        result["d"].add(%d.quest.id)


let questSample = parseJson("""
    {
      "id": 1,
      "target": "dreamTowerSlot",
      "name": "dreamTower_restore",
      "deps": [],
      "price": 25,
      "currency": "tp",
      "time_seconds": 1.0,
      "autoComplete": true,
      "rewards": {
        "cc": 5000,
        "cb": 20,
        "x": 10
      },
      "image_zone": "dreamTower",
      "image_decore": "",
      "ismain": true
    }
    """)


proc validateQ(jq: JsonNode): bool=
    for k, v in questSample:
        if k notin jq:
            return false

    result = true

proc parseTask(qc:QuestConfig, jtask: JsonNode): QuestTask =
    result = createTask(qttBuild, @[1], noBuilding)
    qc.price = jtask["price"].getInt()

    if jtask["currency"].getStr() == "parts":
        qc.currency = Currency.Parts
    elif jtask["currency"].getStr() == "tp":
        qc.currency = Currency.TournamentPoint

    qc.time = jtask["time_seconds"].getFloat()
    qc.autoComplete = jtask["autoComplete"].getBool()
    qc.target = jtask["target"].getStr()

proc parseDeps(qc: QuestConfig, jdeps: JsonNode) =
    var deps = newSeq[string]()
    var lockedByLevel = notLockedByLevel
    var lockedByVipLevel = notLockedByLevel

    for jd in jdeps:
        let str = jd.getStr()
        if str.startsWith("lvl_"):
            lockedByLevel = try: parseInt(str.split("_")[1]) except: notLockedByLevel
        elif str.startsWith("vip_"):
            lockedByVipLevel = try: parseInt(str.split("_")[1]) except: notLockedByLevel
        elif "viponly" == str:
            qc.vipOnly = true
        else:
            deps.add(str)

    qc.depsStr = deps
    qc.lockedByLevel = lockedByLevel
    qc.lockedByVipLevel = lockedByVipLevel

proc questByFrame*(frame: string): Quest {.deprecated.} = nil

proc `$`(qc: QuestConfig): string =
    qc.name

proc toQuestConfig(q: JsonNode): QuestConfig =
    if not q.validateQ():
        return

    let id = q["id"].getInt()
    let name = q["name"].getStr()

    let questConfig = new(QuestConfig)
    questConfig.opens = @[]
    questConfig.deps = @[]
    questConfig.name = name
    questConfig.rewards = q["rewards"].rewardsFromConfig()
    questConfig.parseDeps(q["deps"])
    questConfig.zoneImageTiledProp = q["image_zone"].getStr()
    questConfig.decoreImageTiledProp = q["image_decore"].getStr()
    questConfig.isMainQuest = q["ismain"].getBool()
    questConfig.enabled = q["enabled"].getBool()
    if q.hasKey("unlock_feature"):
        questConfig.unlockFeature = parseEnum[FeatureType](q["unlock_feature"].getStr(), noFeature)
    else:
        questConfig.unlockFeature = noFeature

    let task = questConfig.parseTask(q)
    let quest = createQuest(id, @[task])
    quest.kind = QuestKind.Story
    questConfig.quest = quest

    if "narrative" in q:
        questConfig.narrative = q["narrative"].toNarrativeData()

    if "narrative_head" in q:
        questConfig.bubbleHead = q["narrative_head"].getStr()
    if questConfig.bubbleHead.len == 0:
        questConfig.bubbleHead = $WillFerris & "_01"

    result = questConfig

proc parseStoryConfig*(conf: JsonNode): OrderedTable[int, QuestConfig] =
    conf.updateConfig(getStoryConfigJson())

    let len = nextPowerOfTwo(conf{"quests"}.len)
    var res = initOrderedTable[int, QuestConfig](len)
    var names = initTable[string, int](len)

    if "quests" in conf:
        let quests = conf["quests"]

        if conf["quests"].kind == JArray:
            for q in conf["quests"]:
                let questConfig = q.toQuestConfig()
                let id = questConfig.quest.id
                let name = questConfig.name

                if not questConfig.isNil():
                    res[id] = questConfig
                    names[name] = id
                else:
                    echo "quest not validated ", q
        elif conf["quests"].kind == JObject:
            for k, q in conf["quests"]:
                let questConfig = q.toQuestConfig()
                let id = questConfig.quest.id
                let name = questConfig.name

                if not questConfig.isNil():
                    res[id] = questConfig
                    names[name] = id
                else:
                    echo "quest not validated ", q

    let cmp = proc(f, s: tuple[id: int, config: QuestConfig]): int =
        result = f.id - s.id

    res.sort(cmp)

    for qc in res.values():
        for dep in qc.depsStr:
            if not names.hasKey(dep):
                error "ERROR: `", dep, "` quest has not been found"
                continue

            let oqc = res[names[dep]]
            oqc.opens.add(qc)
            qc.deps.add(oqc)
    
    result = res


storyQuestConfig.configs = parseStoryConfig(getStoryConfigJson())


## ------------------------------------| DAILY QUEST CONFIG |----------------------------

proc parseDailyRewards(dgc: DailyGeneratorConfig, jConf: JsonNode)=
    dgc.rewards = initTable[DailyDifficultyType, seq[Reward]]()

    for d in low(DailyDifficultyType) .. high(DailyDifficultyType):
        var rew = jConf[$d]["reward_beams"].getInt()
        dgc.rewards[d] = @[createReward(RewardKind.parts, rew)]

proc parseDailySkipCost(dgc: DailyGeneratorConfig, jConf: JsonNode)=
    dgc.skipCost = initTable[DailyDifficultyType, int]()

    for d in low(DailyDifficultyType) .. high(DailyDifficultyType):
        dgc.skipCost[d] = jConf[$d].getInt()

proc parseTasks(dgc: DailyGeneratorConfig, gb: GameBalance, jConf: JsonNode)=
    dgc.tasks = initTable[DailyDifficultyType, seq[DailyOnLevel]]()

    let levels = gb.levelProgress.len

    for d in low(DailyDifficultyType) .. high(DailyDifficultyType):
        dgc.tasks[d] = newSeq[DailyOnLevel](levels)
        for i in 0 ..< levels:
            dgc.tasks[d][i] = @[]

    for k, v in jConf:
        var spl = k.split("_")
        if spl.len == 3 and v.kind == JArray:
            try:
                let taskType = parseQuestTaskType(spl[0], id = 100_500)
                let target = parseEnum[BuildingId](spl[1])
                let difficulty = parseEnum[DailyDifficultyType](spl[2])
                var taskLevels = dgc.tasks[difficulty]

                var level = 0
                for jtp in v:
                    if level >= levels: break
                    let totalProg = jtp.getBiggestInt()
                    if totalProg > 0:
                        var questTask = createTask(taskType, @[totalProg], target, difficulty)
                        taskLevels[level].add(questTask)
                    inc level

                dgc.tasks[difficulty] = taskLevels

            except:
                continue

proc parseDailyConfig*(gb: GameBalance, jConf: JsonNode): DailyGeneratorConfig =
    jConf.updateConfig(getDailyConfigJson())

    result.new()
    result.slotStages = initTable[BuildingId, seq[StageConfig]]()

    for kSlot, vSlot in jConf["stages_config"]["slotStages"]:
        var stages: seq[StageConfig] = @[]
        for jStage in vSlot:
            var sconf = new(StageConfig)
            sconf.difficulty = parseEnum[DailyDifficultyType](jStage["difficulty"].getStr())
            sconf.taskType = jStage["tasktype"].getStr()
            stages.add(sconf)
        result.slotStages[parseEnum[BuildingId](kSlot)] = stages

    result.stagesCyclicFrom = jConf["stages_config"]["cycbegin"].getInt()
    result.parseDailyRewards(jConf["rewards"])
    result.parseDailySkipCost(jConf["skipCost"])
    result.parseTasks(gb, jConf)

proc stageConfig*(dgc: DailyGeneratorConfig, slot: BuildingId, stagelvl: int): StageConfig=
    if stagelvl < dgc.slotStages[slot].len:
        return dgc.slotStages[slot][stagelvl]
    else:
        let cycle = (dgc.slotStages[slot].len - 1) - dgc.stagesCyclicFrom
        return dgc.slotStages[slot][dgc.stagesCyclicFrom + stagelvl mod cycle]

proc allAvailableTasksForSlotStage*(dgc: DailyGeneratorConfig, target: BuildingId, stagelvl: int, plvl: int): seq[QuestTask] =
    result = @[]
    let stage = dgc.stageConfig(target, stagelvl)
    let allTasks = dgc.tasks[stage.difficulty]
    var taskType = -1000   # because -1 is for level up and >= 0 is for valid cases
    if stage.taskType.len > 0:
        taskType = parseQuestTaskType(stage.taskType, id = 100_500).int
    for task in allTasks[clamp(plvl - 1, 0, allTasks.len)]:
        if not task.isNil and (taskType < 0 or task.kind.int == taskType) and task.target == target:
            result.add(task)
    if result.len == 0:  # in case of emergency we don't take task type into account
        for task in allTasks[clamp(plvl - 1, 0, allTasks.len)]:
            if not task.isNil and task.target == target:
                result.add(task)


var dailyGeneratorConfigObj:DailyGeneratorConfig
proc sharedDailyGeneratorConfig*(): DailyGeneratorConfig =
    if dailyGeneratorConfigObj.isNil:
        dailyGeneratorConfigObj = parseDailyConfig(sharedGameBalance(), getDailyConfigJson())
    result = dailyGeneratorConfigObj
