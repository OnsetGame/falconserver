import falconserver / common / [ currency, game_balance, checks, get_balance_config, notifications ]
import falconserver / quest / [ quests_config, quest_types, quest ]
import falconserver / auth / profile
import shafa / game / reward_types
import falconserver.boosters.boosters
import strutils, json, times, tables, math

import boolseq

import building.builditem
export BuildingId
export Currency

proc incomeFromQuest(rews: seq[Reward], c: Currency): int=
    for r in rews:
        if r.kind == RewardKind.incomeChips and c == Currency.Chips:
            result += r.amount.int
        elif r.kind == RewardKind.incomeBucks and c == Currency.Bucks:
            result += r.amount.int

proc questIncomeCurrency*(r: seq[Reward]): Currency=
    if r.incomeFromQuest(Currency.Chips) > 0:
        result =  Currency.Chips
    elif r.incomeFromQuest(Currency.Bucks) > 0:
        result = Currency.Bucks

proc resourcePerHour(conf: seq[QuestConfig], complQuests: BoolSeq, currency: Currency): int=
    result = 0
    if complQuests.len == 0: return
    for qi in 0 ..< complQuests.len:
        if qi < conf.len and complQuests[qi]:
            result += incomeFromQuest(conf[qi].rewards, currency)

proc resourcePerHour*(p: Profile, currency: Currency): int =
    var storyConfig = p.getStoryConfig()
    var binStr = ""

    if not p.statistics.questsCompleted.isNil:
        binStr = p.statistics.questsCompleted.binstr()

    var bs = newBoolSeq(binStr)
    result = resourcePerHour(storyConfig, bs, currency)

proc resourceIncomeFullTimeHours*(p: Profile, currency: Currency): float =
    let gb = p.getGameBalance()
    result = if currency == Currency.Chips: gb.fullChipsIncomeTime else: gb.fullBucksIncomeTime

proc resourceIncomeFullTime*(p: Profile, currency: Currency): float =
    result = p.resourceIncomeFullTimeHours(currency) * 60.0 * 60.0


template collectTimeKey*(c: Currency): string = "lct_" & $c
template calculatedGainKey*(c: Currency): string = "cg_" & $c
template calculatedGainDurationKey*(c: Currency): string = "cgd_" & $c


proc lastCollectionTime*(p: Profile, c: Currency): float =
    let clientStates = p[$prfState]
    if not clientStates.isNil:
        let k = collectTimeKey(c)
        if k in clientStates:
            result = clientStates[k].toFloat64()
        else:
            result = 0.0

proc calculatedGain*(p: Profile, c: Currency): float =
    let clientStates = p[$prfState]
    if not clientStates.isNil:
        let k = calculatedGainKey(c)
        if k in clientStates:
            result = clientStates[k].toFloat64()
        else:
            result = 0

proc calculatedGainDuration*(p: Profile, c: Currency): float =
    let clientStates = p[$prfState]
    if not clientStates.isNil:
        let k = calculatedGainDurationKey(c)
        if k in clientStates:
            result = clientStates[k].toFloat64()
        else:
            result = 0.0


proc availableResourcesF*(p: Profile, lastCollectTime: float, currency: Currency): float =
    let fullFillDur = p.resourceIncomeFullTimeHours(currency) * 60.0 * 60.0
    let actualFillDur = clamp(epochTime() - lastCollectTime, 0, fullFillDur)
    let calculatedDur = clamp(p.calculatedGainDuration(currency), 0, actualFillDur)
    let remainingFillDur = actualFillDur - calculatedDur
    let boosteredDur = clamp(p.boosters.activeUntilT($btIncome) - (lastCollectTime + calculatedDur), 0, remainingFillDur)
    let nonBoosteredDur = remainingFillDur - boosteredDur

    result = p.calculatedGain(currency) + (p.resourcePerHour(currency).float / 60.0 / 60.0 * (boosteredDur * p.getGameBalance().boosters.incomeRate + nonBoosteredDur))

proc availableResources*(p: Profile, lastCollectTime: float, currency: Currency): int =
    result = round(p.availableResourcesF(lastCollectTime, currency)).int


proc sheduleCollectNotification*(p: Profile, currency: Currency, time: float)=
    var biKind = if currency == Currency.Chips: "restaurant" else: "gasStation"
    p.forkNotifyResourcesAreFull(biKind, time)


proc collectResource*(p: Profile, currency: Currency) =
    let lastCollectionTime = p.lastCollectionTime(currency)
    # We mustn't raise an exception here as the server gets crashed when only chips income is available.
    if lastCollectionTime <= 1.0:
        return

    let ar = p.availableResources(lastCollectionTime, currency)
    if ar > 0:
        if currency == Currency.Chips:
            p.chips = p.chips + ar
        elif currency == Currency.Bucks:
            p.bucks = p.bucks + ar

        let collectionTime = epochTime()
        p.setClientState(collectTimeKey(currency), collectionTime.toBson())
        p.deleteClientState(calculatedGainKey(currency))
        p.deleteClientState(calculatedGainDurationKey(currency))
        p.sheduleCollectNotification(currency, collectionTime + p.resourceIncomeFullTime(currency))


proc saveReadyIncomeGain*(p: Profile, currency: Currency) =
    let key = collectTimeKey(currency)
    let lastCollectionTime = p.lastCollectionTime(currency)
    # We mustn't raise an exception here as the server gets crashed when only chips income is available.
    if lastCollectionTime <= 1.0:
        return

    let readyIncomeGain = p.availableResourcesF(lastCollectionTime, currency)
    let readyIncomeGainDur = epochTime() - lastCollectionTime
    p.setClientState(calculatedGainKey(currency), readyIncomeGain.toBson())
    p.setClientState(calculatedGainDurationKey(currency), readyIncomeGainDur.toBson())


# for old clients
proc collectResources*(p: Profile, fromRes: string) {.deprecated.} =
    var currency: Currency
    if "restaurant" in fromRes:
        currency = Currency.Chips
    elif "gasStation" in fromRes:
        currency = Currency.Bucks

    p.collectResource(currency)


proc collectConfig*(p: Profile): JsonNode=
    result = newJArray()

    for curr in [Currency.Chips, Currency.Bucks]:
        var conf = newJObject()
        conf["kind"] = %curr
        conf["lct"] = %p.lastCollectionTime(curr)
        conf["rph"] = %p.resourcePerHour(curr)
        conf["ful"] = %p.resourceIncomeFullTimeHours(curr)
        if p.calculatedGainDuration(curr) > 0:
            conf["cgd"] = %p.calculatedGainDuration(curr)
            conf["cg"] = %p.calculatedGain(curr)
        result.add(conf)
