import falconserver.auth.profile
import falconserver.auth.profile_types
import falconserver.map.building.builditem
import falconserver.map.collect
import falconserver.quest.quests_config
import falconserver / common / [ bson_helper, notifications, game_balance, currency, get_balance_config ]
import nimongo.bson
import strutils, json, times, tables
import shafa.game.feature_types

type MapState = tuple[key: string, val: Bson]
type StateFromQuest = proc(qc: QuestConfig, p: Profile): MapState


proc toBson*(b: BuildItem): Bson=
    result = newBsonDocument()
    result["i"] = b.id.int.toBson()
    result["n"] = b.name.toBson()
    result["l"] = b.level.toBson()
    result["t"] = b.lastCollectionTime.toBson()

proc toBuildItem*(b: Bson): BuildItem=
    let id = b["i"].toInt32().BuildingId

    result = newBuildItem(id)
    if "n" in b:
        result.name = b["n"].toString()

    result.level = b["l"].toInt32()
    result.lastCollectionTime = b["t"].toFloat64().float

proc slotsBuilded*(p: Profile): seq[BuildingId]=
    result = @[]
    let clientStates = p[$prfState]
    if "slots" in clientStates:
        for bid in clientStates["slots"]:
            var bi = parseEnum[BuildingId](bid.toString(), noBuilding)
            if bi != noBuilding:
                result.add(bi)

proc getInitialSlot*(p: Profile): BuildingId=
    let clientStates = p[$prfState]
    if not clientStates.isNil:
        let bInitial_slot = clientStates["initial_slot"]
        if not bInitial_slot.isNil:
            return bInitial_slot.toInt32().BuildingId
    result = anySlot

proc setInitialSlotOnMap*(p: Profile, bi: BuildingId)=
    let key = "initial_slot"
    let val = bi.int.toBson()
    p.setClientState(key, val)

proc buildSlot*():StateFromQuest=
    result = proc(qc: QuestConfig, p: Profile): MapState=
        var slotsState = p[$prfState]["slots"]
        if slotsState.isNil:
            slotsState = newBsonArray()

        let target = try: parseEnum[BuildingId](qc.target)
                     except: noBuilding
        if target != noBuilding:
            discard slotsState.add(($target).toBson())
        else:
            raise newException(Exception, "buildSlot unknown slot quest : " & qc.name & " with target " & qc.target)

        result.key = "slots"
        result.val = slotsState

proc getSlotUnlock(p: Profile, name: string): StateFromQuest =
    for conf in getQuestConfigsForFeature(p.gconf.getStoryConfig(), FeatureType.Slot):
        if conf.name == name:
            return buildSlot()

    if name == "stadium_restore":
        return proc(qc: QuestConfig, p:Profile): MapState =
            result.key = "tournaments"
            result.val = true.toBson()

    if name == "bank_restore":
        return proc(qc: QuestConfig, p:Profile): MapState =
            result.key = "exchange"
            result.val = true.toBson()


proc updateMapStateOnQuestComplete*(p: Profile, qc: QuestConfig) =
    var currency = qc.rewards.questIncomeCurrency()
    if currency != Currency.Unknown:
        let fullTime = p.resourceIncomeFullTime(currency)
        let ct = epochTime()
        var lct = p.lastCollectionTime(currency)
        if lct <= 1.0: # firstIncomeQuest
            lct = epochTime()

        if ct - lct < fullTime * 0.5:
            lct = ct - fullTime * 0.5

        p.setClientState(collectTimeKey(currency), lct.toBson())
        let capTime = fullTime - (ct - lct)
        p.sheduleCollectNotification(currency, lct + capTime)

    let stateForClient = p.getSlotUnlock(qc.name)
    if not stateForClient.isNil:
        let (key, val) = stateForClient(qc, p)
        p.setClientState(key, val)
