import profile
export profile

import shafa / game / vip_types
export vip_types

import falconserver / auth / profile_helpers
import falconserver / fortune_wheel / fortune_wheel
import falconserver / boosters / boosters

import falconserver / quest / quest_manager

import math
import asyncdispatch
import sequtils


proc chipsPurchaseBonus*(p: Profile): float =
    let cfg = p.gconf.getGameBalance().vipConfig
    cfg.levels[max(p.vipLevel.int, 0)].chipsBonus


proc bucksPurchaseBonus*(p: Profile): float =
    let cfg = p.gconf.getGameBalance().vipConfig
    cfg.levels[max(p.vipLevel.int, 0)].bucksBonus

proc exchangeBonus*(p: Profile): float =
    let cfg = p.gconf.getGameBalance().vipConfig
    cfg.levels[max(p.vipLevel.int, 0)].exchangeBonus


proc exchangeGain*(p: Profile, value: int64): int64 =
    result = value + round(value.float * p.exchangeBonus()).int64


proc giftBonus*(p: Profile): float =
    let cfg = p.gconf.getGameBalance().vipConfig
    cfg.levels[max(p.vipLevel.int, 0)].giftsBonus


proc giftGain*(p: Profile, value: int): int =
    result = value + round(value.float * p.giftBonus()).int


proc wheelSpinsReward*(config: VipConfig, fromLevel, toLevel: int): int =
    result = 0
    for i in fromLevel + 1 .. toLevel:
        let reward = config.levels[i].getReward(RewardKind.wheel)
        if not reward.isNil:
            result += reward.amount.int


proc gainVipLevelRewards*(profile: Profile, fromLevel, toLevel: int, res: JsonNode) {.async.} =
    let vipConfig = profile.gconf.getGameBalance().vipConfig
    var rewards = newSeq[Reward]()

    for lvl in fromLevel .. toLevel:
        rewards.add(vipConfig.levels[lvl].rewards)

    var qm: QuestManager
    rewards.keepIf(proc(x: Reward): bool =
        if x.kind == RewardKind.vipaccess:
            if qm.isNil:
                qm = profile.newQuestManager()
            let zoneReward = x.ZoneReward
            qm.gainVipAccess(zoneReward.zone)
            result = false
        else:
            result = true
    )
    
    await profile.acceptRewards(rewards, res)


proc vipLevelForPoints*(profile: Profile, points: int64, flomLevel: int64 = 0): int =
    let vipConfig = profile.gconf.getGameBalance().vipConfig
    result = vipConfig.levels[vipConfig.levels.high].level

    for i in flomLevel .. vipConfig.levels.high:
        let lvl = vipConfig.levels[i.int]
        if lvl.pointsRequired > profile.vipPoints:
            result = lvl.level - 1
            break


proc gainVipPoints*(profile: Profile, vipPoints: int64, res: JsonNode) {.async.} =
    let vipConfig = profile.gconf.getGameBalance().vipConfig

    let currentVipLevel = vipConfig.levels[max(profile.vipLevel.int, 0)]

    profile.vipPoints = profile.vipPoints + vipPoints
    profile.vipLevel = profile.vipLevelForPoints(profile.vipPoints, max(profile.vipLevel, 0))
    
    res["vip"] = %{"points": %profile.vipPoints, "level": %profile.vipLevel}
    await profile.gainVipLevelRewards(currentVipLevel.level + 1, profile.vipLevel.int, res)


proc gainVipPointsForPurchase*(profile: Profile, usdPrice: float, res: JsonNode) {.async.} =
    let points = profile.gconf.getGameBalance().vipConfig.vipPointsForPrice(usdPrice)
    await profile.gainVipPoints(points, res)
