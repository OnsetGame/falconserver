import json, strutils, strutils, tables, algorithm
import falconserver.auth.profile_types
import falconserver / quest / [ quest_types ]
import falconserver / common / [ currency, checks ]
import shafa / game / [feature_types, vip_types, booster_types, reward_types]

## ------------------------------------| GAME BALANCE(GB) |----------------------------
type LevelData* = ref object
    level*: int
    experience*: int
    rewards*: seq[Reward]

type ExchangeRate* = ref object
    bucks*: int
    chips*: int
    parts*: int

type TutorialReward* = ref object
    step*: string
    rewards*: seq[Reward]

type BuildingLevel* = ref object
    quest*: string
    income*: int
    capacity*: int

type BuildingConfig* = ref object
    buildingIdStr*: string
    currency*: Currency
    levels*: seq[BuildingLevel]

type FortuneWheelGain* = ref object
    item*: string
    count*: int

type FortuneWheelData* = ref object
    gains*: seq[FortuneWheelGain]
    defaultProbs*: seq[float]
    firstTimeProbs*: seq[float]
    spinCost*: int
    freeSpinTimeout*: float

type GiftsData* = ref object
    bucksForInvite*: int
    chipsPerDailyGift*: int

type BoostersData* = ref object
    experienceRate*: float
    incomeRate*: float
    tournamentPointsRate*: float

type GameBalance* = ref object
    levelProgress*: seq[LevelData]
    bets*:seq[int64]
    betsFromLevel*:seq[int]
    spinExp*: int
    spinExpBet*: int
    questSpeedUpPrice*: int
    exchangeRates*: seq[ExchangeRate]
    exchangeMultiplayers*: Table[int, float]
    resourceZones*{.deprecated.}: seq[string]
    buildingsConfig*: seq[BuildingConfig]
    taskBets*: Table[DailyDifficultyType, bool]
    fortuneWheel*: FortuneWheelData
    gifts*: GiftsData
    boosters*: BoostersData
    zoneFeatures*: Table[string, FeatureType]
    exchangeDiscountTime*: float
    fullChipsIncomeTime*: float
    fullBucksIncomeTime*: float
    offerRenewableHoursTime*: float
    vipConfig*: VipConfig
    slotSortOrder*: seq[string]
    tournamentRewards*: JsonNode

const commonBalanceData* = staticRead("../resources/balance/balance.json")
var commonBalanceJson {.threadvar.}: JsonNode
proc getCommonBalanceJson*(): JsonNode {.gcsafe.} = 
    if commonBalanceJson.isNil:
        commonBalanceJson = parseJson(commonBalanceData)
    result = commonBalanceJson


proc updateConfig*(current, default: JsonNode) =
    if current == default:
        return

    assert(current.kind == JObject)
    assert(default.kind == JObject)

    for k, v in default:
        if k notin current:
            current[k] = v
            continue

        if current[k].kind == JObject and default[k].kind == JObject:
            updateConfig(current[k], default[k])


proc sharedGameBalance*(): GameBalance

## ---------------------------- SERIALIZATION AND DESERIALIZATION --------------------------
proc serializeLevelData*(ld: LevelData): JsonNode =
    result = newJObject()
    result["lvl"] = %ld.level
    result["exp"] = %ld.experience
    result["rews"] = newJArray()
    for rew in ld.rewards:
        result["rews"].add(rew.toJson())

proc deserializeLevelData*(json: JsonNode): LevelData=
    result.new()
    result.level = json["lvl"].getInt()
    result.experience = json["exp"].getInt()
    result.rewards = @[]

    for jr in json["rews"]:
        result.rewards.add(jr.getReward())

proc serializeExchangeRate*(er: ExchangeRate): JsonNode=
    result = newJObject()
    result["b"] = %er.bucks
    result["c"] = %er.chips
    result["p"] = %er.parts

proc deserializeExchangeRate*(json: JsonNode): ExchangeRate=
    result.new()
    result.bucks = json["b"].getInt()
    result.parts = json["p"].getInt()
    result.chips = json["c"].getInt()

proc deserializeTutorialReward*(json: JsonNode): TutorialReward=
    result.new()
    result.step = json["step"].getStr()
    result.rewards = @[]
    for r in json["rewards"]:
        result.rewards.add(r.getReward())

proc deserializeVipSystem*(json: JsonNode): VipConfig =
    result.new()
    result.fromJson(json)

proc serializeTutorialReward*(tr: TutorialReward): JsonNode=
    result = newJObject()
    result["step"] = %tr.step
    result["rewards"] = newJArray()
    for r in tr.rewards:
        result["rewards"].add(r.toJson())

# proc rewardsCount(ld: LevelData, prfT: ProfileFields): int64 =
#     for r in ld.rewards:
#         if $r.kind == $prfT:
#             result = r.count

# proc rewardsChips*(ld: LevelData): int64 =
#     result = ld.rewardsCount(prfChips)

# proc rewardsParts*(ld: LevelData): int64 =
#     result = ld.rewardsCount(prfParts)

# proc rewardsBucks*(ld: LevelData): int64 =
#     result = ld.rewardsCount(prfBucks)

proc `$`(lvl: LevelData): string=
    result = "LevelData (level: " & $lvl.level & ", experience: " & $lvl.experience & " rewards count: " & $lvl.rewards.len & ")"

## ------------------------------------| GB PARSER |----------------------------
proc rewardsFromConfig*(jn: JsonNode): seq[Reward] =
    result = @[]
    for key, value in jn:
        # Backward compatibility
        var key = key
        case key:
            of "chips":
                key = $RewardKind.chips
            of "bucks":
                key = $RewardKind.bucks
            else:
                discard

        if key == "freerounds":
            for slot, val in value:
                let amount = val.getBiggestInt()
                if amount > 0:
                    result.add(createReward(RewardKind.freeRounds, amount, slot))
        else:
            try:
                let amount = value.getBiggestInt()
                if amount > 0:
                    result.add(createReward(parseEnum[RewardKind](key), amount))
            except ValueError: discard


proc parseLevelData(xp_data, rewards_data: JsonNode): seq[LevelData]=
    result = @[]

    for k, xp in xp_data:
        let lvlData = new(LevelData)
        lvlData.level = xp["level"].getInt()
        lvlData.experience = xp["xp_to_gain_next_level"].getInt()
        result.add(lvlData)

    for k, rewards in rewards_data:
        let lvl = rewards["level"].getInt()
        let lvlData = result[lvl - 1]
        lvlData.rewards = rewards.rewardsFromConfig()

proc parseBetLevels(gb: GameBalance, betLevels_data: JsonNode)=
    gb.bets = @[]
    gb.betsFromLevel = @[]

    for bl in betLevels_data:
        gb.bets.add(bl["bet_opened"].getBiggestInt().int64)
        gb.betsFromLevel.add(bl["level"].getInt())

proc parseExpFromSpin*(gb: GameBalance, jsonExp: JsonNode)=
    gb.spinExpBet = jsonExp[0]["chips"].getInt()
    gb.spinExp = jsonExp[0]["xp"].getInt()

proc parseExchangeRates*(jsonRates: JsonNode): seq[ExchangeRate]=
    result = @[]
    for rate in jsonRates:
        let r = new(ExchangeRate)
        r.bucks = if "bucks" in rate: rate["bucks"].getInt() else: 0
        r.chips = if "chips" in rate: rate["chips"].getInt() else: 0
        r.parts = if "beams" in rate: rate["beams"].getInt() else: 0

        result.add(r)

proc parseExchangeMultiplayers(jsonMult: JsonNode): Table[int, float]=
    result = initTable[int, float]()
    for jmult in jsonMult:
        try:
            let mult = jmult["multiplier"].getInt()
            let chance = jmult["probability"].getFloat()
            result[mult] = chance
        except: discard

proc parseBuildingConfig(configs: JsonNode): BuildingConfig=
    result.new()
    result.levels = @[]
    for config in configs:

        var biLvl = new(BuildingLevel)
        biLvl.income = config["income"].getInt()
        biLvl.quest = config["quest"].getStr()
        biLvl.capacity = config["capacity"].getInt()

        result.levels.add(biLvl)

proc parseFortuneWheel(config: JsonNode): FortuneWheelData =
    result.new()
    result.gains = @[]
    result.defaultProbs = @[]
    result.firstTimeProbs = @[]
    result.spinCost = config["spinCost"].getInt()
    result.freeSpinTimeout = config["freeSpinTimeout"].getFloat()
    for i in config["items"]:
        let gain = FortuneWheelGain.new()
        gain.item = i["item"].getStr()
        gain.count = i["number"].getInt()
        result.gains.add(gain)
        result.firstTimeProbs.add(i["firstTimeProb"].getFloat())
        result.defaultProbs.add(i["defaultProb"].getFloat())


proc parseGifts(config: JsonNode): GiftsData =
    result.new()
    result.bucksForInvite = config["bucksForInvite"].getInt()
    result.chipsPerDailyGift = config["chipsPerDailyGift"].getInt()


proc parseBoosters(config: JsonNode): BoostersData =
    result.new()
    result.experienceRate = config["exp"].getFloat()
    result.incomeRate = config["inc"].getFloat()
    result.tournamentPointsRate = config["tp"].getFloat()


proc parseZoneFeatures(gb: GameBalance, jn: JsonNode) =
    gb.zoneFeatures = initTable[string, FeatureType]()
    for k, v in jn:
        gb.zoneFeatures[k] = parseEnum[FeatureType](v.getStr(), noFeature)

    gb.resourceZones = @[]
    for k, v in gb.zoneFeatures:
        if v in [IncomeChips, IncomeBucks]:
            gb.resourceZones.add(k)

proc parseSlotOrder(jn:JsonNode):seq[string] =
    result = newSeq[string]()
    for i in 0..jn.len:
        for sn,pos in jn:
            if pos.getInt() == i:
               result.add(sn)

proc parseBalance*(jsonbalance: JsonNode): GameBalance =
    jsonbalance.updateConfig(getCommonBalanceJson())

    result.new()
    result.levelProgress = parseLevelData(jsonBalance["xp_points"], jsonBalance["levelup_bonuses"])
    result.parseBetLevels(jsonBalance["max_bet"])
    result.parseExpFromSpin(jsonBalance["xp_for_spins"])
    result.exchangeRates = parseExchangeRates(jsonBalance["exchange_course"])
    result.exchangeMultiplayers = parseExchangeMultiplayers(jsonbalance["exchange_multipliers"])
    result.parseZoneFeatures(jsonbalance["zones"])
    result.questSpeedUpPrice = jsonbalance{"QuestSpeedupPrice"}.getInt(1)
    result.vipConfig = jsonbalance["vip_system"].deserializeVipSystem()
    result.tournamentRewards = jsonbalance{"tournamentRewards"}

    block buildingsConfigParsing: #sharedBuildingsConfig
        result.buildingsConfig = @[]

        for zone in result.resourceZones:
            if zone in jsonBalance:
                let biConfig = parseBuildingConfig(jsonBalance[zone])
                biConfig.currency = Currency.Unknown
                for rawZone in jsonBalance["resourcezones"]:
                    if rawZone["name"].getStr() == zone:
                        biConfig.currency = parseEnum[Currency](rawZone["currency"].getStr())
                        break
                biConfig.buildingIdStr = zone
                result.buildingsConfig.add(biConfig)

    result.taskBets = initTable[DailyDifficultyType, bool]()
    for d in low(DailyDifficultyType) .. high(DailyDifficultyType):
        result.taskBets[d] = jsonbalance["taskBets"][$d].getBool()

    if "timeouts" in jsonBalance:
        let timeoutsJ = jsonBalance{"timeouts"}
        result.exchangeDiscountTime     = timeoutsJ{"Exchange"}.getFloat()
        result.fullBucksIncomeTime      = timeoutsJ{"incomeBucksHoursLimit"}.getFloat()
        result.fullChipsIncomeTime      = timeoutsJ{"incomeChipsHoursLimit"}.getFloat()
        result.offerRenewableHoursTime  = timeoutsJ{"offerRenewableHoursTime"}.getFloat()

    if "slotSortOrder" in jsonBalance:
        result.slotSortOrder = jsonBalance["slotSortOrder"].parseSlotOrder


    result.fortuneWheel = parseFortuneWheel(jsonbalance["fortuneWheel"])
    result.gifts = parseGifts(jsonBalance["gifts"])
    result.boosters = parseBoosters(jsonBalance["boosters"])

proc betLevels*(gb: GameBalance, plevel: int): seq[int64]=
    result = @[]
    var indx = 0
    while indx < gb.betsFromLevel.len:
        if plevel >= gb.betsFromLevel[indx]:
            result.add(gb.bets[indx])
        inc indx

proc betLevelsForClient*(gb: GameBalance, plevel: int): JsonNode =
    result = json.`%*`(betLevels(gb, plevel))

serverOnly:
    proc expFromBet*(gb: GameBalance, bet:int64): int =
        result = (bet div gb.spinExpBet).int * gb.spinExp

    proc toJson*(gb: GameBalance): JsonNode =
        result = newJObject()

        result["levelData"] = newJArray()
        for lp in gb.levelProgress:
            result["levelData"].add(lp.serializeLevelData())

        result["bets"] = newJArray()
        for b in gb.bets:
            result["bets"].add(%b)

        result["betsFromLevel"] = newJArray()
        for bl in gb.betsFromLevel:
            result["betsFromLevel"].add(%bl)

        result["exchange"] = newJArray()
        for er in gb.exchangeRates:
            result["exchange"].add(er.serializeExchangeRate())

        if gb.resourceZones.len != 0:
            result["resourceZones"] = newJArray()
            for rz in gb.resourceZones:
                result["resourceZones"].add(%rz)

        result["taskBets"] = newJObject()
        for k, v in gb.taskBets:
            result["taskBets"][$k] = %v

        result["questSpeedUpPrice"] = %gb.questSpeedUpPrice

        result["zoneFeatures"] = newJObject()
        for k, v in gb.zoneFeatures:
            result["zoneFeatures"][k] = %v

        var wf = newJObject()
        wf["defProbs"] = newJArray()
        for df in gb.fortuneWheel.defaultProbs:
            wf["defProbs"].add(%df)

        wf["firstProbs"] = newJArray()
        for df in gb.fortuneWheel.firstTimeProbs:
            wf["firstProbs"].add(%df)

        var gains = newJArray()
        for g in gb.fortuneWheel.gains:
            var jg = newJObject()
            jg["count"] = %g.count
            jg["item"] = %g.item
            gains.add(jg)
        wf["gains"] = gains

        result["wheelOfFortune"] = wf

        result["offerRenewableHoursTime"] = %gb.offerRenewableHoursTime

        if gb.slotSortOrder.len != 0:
            result["slotSortOrder"] = %gb.slotSortOrder


clientOnly:
    # dynamical update of GameBalance, server send to client GameBalance represenation in json
    # and then we can update client's version by this proc
    proc updateGameBalance*(gb: GameBalance, jData: JsonNode) =
        if "levelData" in jData:
            gb.levelProgress = @[]
            for jld in jData["levelData"]:
                gb.levelProgress.add(jld.deserializeLevelData())

        if "bets" in jData:
            gb.bets = @[]
            for jb in jData["bets"]:
                gb.bets.add(jb.getBiggestInt().int64)

        if "betsFromLevel" in jData:
            gb.betsFromLevel = @[]
            for jbl in jData["betsFromLevel"]:
                gb.betsFromLevel.add(jbl.getInt())

        if "exchange" in jData:
            gb.exchangeRates = @[]
            for je in jData["exchange"]:
                gb.exchangeRates.add(je.deserializeExchangeRate())

        if "resourceZones" in jData:
            gb.resourceZones = @[]
            for jrz in jData["resourceZones"]:
                gb.resourceZones.add(jrz.getStr())

        if "taskBets" in jData:
            gb.taskBets = initTable[DailyDifficultyType, bool]()
            for d in low(DailyDifficultyType) .. high(DailyDifficultyType):
                gb.taskBets[d] = jData["taskBets"][$d].getBool()

        if "questSpeedUpPrice" in jData:
            gb.questSpeedUpPrice = jData["questSpeedUpPrice"].getInt()

        if "zoneFeatures" in jData:
            gb.zoneFeatures = initTable[string, FeatureType]()
            for k, v in jData["zoneFeatures"]:
                gb.zoneFeatures[k] = parseEnum[FeatureType](v.getStr(), noFeature)

        if "wheelOfFortune" in jData:
            gb.fortuneWheel = new(FortuneWheelData)
            gb.fortuneWheel.gains = @[]

            for jg in jData["wheelOfFortune"]["gains"]:
                var gain = new(FortuneWheelGain)
                gain.item = jg["item"].getStr()
                gain.count = jg["count"].getInt()
                gb.fortuneWheel.gains.add(gain)

            gb.fortuneWheel.defaultProbs = @[]
            for df in jData["wheelOfFortune"]["defProbs"]:
                gb.fortuneWheel.defaultProbs.add(df.getFloat())

            gb.fortuneWheel.firstTimeProbs = @[]
            for df in jData["wheelOfFortune"]["firstProbs"]:
                gb.fortuneWheel.firstTimeProbs.add(df.getFloat())

        if "offerRenewableHoursTime" in jData:
            gb.offerRenewableHoursTime = jData["offerRenewableHoursTime"].getFloat()

        if "slotSortOrder" in jData:
            var newOrder = newSeq[string]()
            for jSlotName in jData["slotSortOrder"]:
                newOrder.add(jSlotName.getStr)

            gb.slotSortOrder = newOrder

proc totalExpForLevel*(gb: GameBalance, level: int): int =
    for i in 0 .. < level:
        result += gb.levelProgress[i].experience

var sharedGameBalanceObj {.threadvar.}: GameBalance
proc sharedGameBalance*(): GameBalance {.gcsafe.} =
    if sharedGameBalanceObj.isNil:
        sharedGameBalanceObj = parseBalance(getCommonBalanceJson())
    result = sharedGameBalanceObj

serverOnly:
    proc getRewardAmount*(ld: LevelData, kind: ProfileFields): int64 =
        for rew in ld.rewards:
            if $rew.kind == $kind:
                return rew.amount

proc closestBet*(bets: seq[int64], chips: int64, divi: int): int64 =
    let tb = chips div divi
    var allowedBets = bets
    allowedBets.sort do(a, b: int64) -> int:
        result = cmp(abs(a-tb), abs(b-tb))
    result = allowedBets[0]

import currency

proc exchangeRates*(gb: GameBalance, exchangeNumber: int, cTo: Currency): tuple[bucks: int64, change: int64] =
    ## Get current exhange rates
    let exchRates = gb.exchangeRates
    let currExchRate = exchRates[min(exchangeNumber, exchRates.len() - 1)]
    if cTo == Currency.Chips:
        return (bucks:currExchRate.bucks.int64, change: currExchRate.chips.int64)
    elif cTo == Currency.Parts:
        return (bucks:currExchRate.bucks.int64, change: currExchRate.parts.int64)

clientOnly:
    proc exchangeRates*(exchangeNumber: int, cTo: Currency): tuple[bucks: int64, change: int64] =
        exchangeRates(sharedGameBalance(), exchangeNumber, cTo)


serverOnly:
    import nimongo.bson

    const predefinedSpinsData = staticRead("../resources/balance/predefined_spins.json")

    var gPredefinedSpinsData: JsonNode

    proc sharedPredefinedSpinsData*(): JsonNode =
        if gPredefinedSpinsData.isNil:
            gPredefinedSpinsData = parseJson(predefinedSpinsData)
        gPredefinedSpinsData

    proc getPredefinedSpin*(gameSlotID: string, step: int, predefinedSpins: JsonNode): Bson =
        let machineSpins = predefinedSpins{gameSlotID}
        if machineSpins.isNil:
            return nil
        if step >= machineSpins.len:
            return nil
        result = newBsonArray()
        for v in machineSpins[step]:
            result.add(v.getInt().toBson())
