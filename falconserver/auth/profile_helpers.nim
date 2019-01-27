import json, math, strutils
import asyncdispatch

import falconserver.auth.profile
export profile

import falconserver / common / [ get_balance_config, game_balance ]
import falconserver / quest / [ quest, quest_task ]
import falconserver.map.building.builditem
import falconserver.boosters.boosters
import falconserver.free_rounds.free_rounds
import falconserver.fortune_wheel.fortune_wheel
import shafa / game / reward_types


proc getLevelData*(p: Profile): JsonNode =
    let lvl = p.level
    result = newJObject()
    result["level"] = %p.level
    result["xpCur"] = %p.experience
    result["xpTot"] = %p.getGameBalance().levelProgress[lvl - 1].experience

proc acceptFreeRoundsRewards(profile: Profile, ar: seq[Reward], resp: JsonNode) {.async.} =
    when defined(tests):
        return

    var freeRounds: FreeRounds

    for r in ar:
        if r.kind == RewardKind.freerounds:
            let reward = r.ZoneReward
            if freeRounds.isNil:
                freeRounds = await getOrCreateFreeRounds(profile.id)
            freeRounds.addFreeRounds(reward.zone, reward.amount.int)

    if not freeRounds.isNil:
        resp.updateWithFreeRounds(freeRounds)
        await freeRounds.save()

proc acceptReward(p: Profile, r: Reward, resp: JsonNode): Future[void] {.async.}

proc acceptRewards*(p: Profile, ar: seq[Reward], resp: JsonNode): Future[void] {.async.} =
    for r in ar:
        await p.acceptReward(r, resp)
    await p.acceptFreeRoundsRewards(ar, resp)

proc acceptReward(p: Profile, r: Reward, resp: JsonNode): Future[void] {.async.} =
    let gb = p.getGameBalance()

    # if r.kind >= qrBoosterExp and r.kind <= qrBoosterAll:
    if r.isBooster():
        let t = r.amount.float
        case r.kind:
            of RewardKind.boosterExp:
                await p.boosters.add($btExperience, t, isFree = true)
            of RewardKind.boosterIncome:
                await p.boosters.add($btIncome, t, isFree = true)
            of RewardKind.boosterTourPoints:
                await p.boosters.add($btTournamentPoints, t, isFree = true)
            of RewardKind.boosterAll:
                await p.boosters.add($btExperience, t, isFree = true)
                await p.boosters.add($btIncome, t, isFree = true)
                await p.boosters.add($btTournamentPoints, t, isFree = true)
            else:
                discard
        return

    # if r.kind == qrExp:
    if r.kind == RewardKind.exp:
        var gain: int = r.amount.int
        if p.boosters.affectsExperience():
           gain = round(gain.float * p.getGameBalance().boosters.experienceRate).int

        var levelExp = gb.levelProgress[p.level - 1].experience
        var exp = p.experience + gain
        while exp >= levelExp:
            if p.level < gb.levelProgress.len:
                exp -= levelExp
                p.level = p.level + 1
                levelExp = gb.levelProgress[p.level - 1].experience
            else:
                exp = min(exp, levelExp)
                break
        p.experience = exp
        return

    if r.kind == RewardKind.wheel:
        p.addWheelFreeSpins(r.amount.int)
        return

    if r.isCurrencyReward():
        p[$r.kind] = (p[$r.kind].toInt64() + r.amount).toBson()
        return


proc createLevelUpQuest*(p: Profile): Quest=
    let gb = p.getGameBalance()
    let lvl = p.level
    if lvl < gb.levelProgress.len:
        let lvlData = gb.levelProgress[lvl - 1]
        let lvlRewardsData = gb.levelProgress[lvl]
        let task = createTask(qttLevelUp, @[lvlData.experience], noBuilding)

        result = createQuest(qttLevelUp.int, @[task])
        result.data[$qfStatus] = QuestProgress.InProgress.int32.toBson()
        result.kind = QuestKind.LevelUp

