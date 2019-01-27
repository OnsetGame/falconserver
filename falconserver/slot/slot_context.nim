import machine_base_types
import falconserver / slot / [ machine_base ]
import falconserver.tournament.tournaments
import falconserver / free_rounds / free_rounds
import falconserver.auth.profile
import falconserver / quest / [ quest_manager, quest, quest_task, quest_types ]
import falconserver / common / [ get_balance_config, game_balance, orm, db ]
import shafa / slot / slot_data_types
import json
import nimongo / bson

import asyncdispatch, tables, algorithm


type BetConfig* = tuple[bets: seq[int64], bet: int64, hardBet: int]


proc toJson*(bc: BetConfig): JsonNode =
    result = newJObject()
    result["allBets"] = %bc.bets
    result["servBet"] = %bc.bet
    result["hardBet"] = %bc.hardBet


type SlotContext* = ref object of RootObj
    machineId*: string
    gameId: string
    machine*: SlotMachine
    profile*: Profile
    state*: Bson


proc numberOfFreespins*(s: SlotContext): int =
    if not s.state.isNil:
        if $sdtFreespinCount in s.state:
            result = s.state[$sdtFreespinCount].toInt()

        elif "fs" in s.state: #balloon slot
            result = s.state["fs"].toInt()


proc numberOfRespins*(s: SlotContext): int =
    if not s.state.isNil:
        if $sdtRespinsCount in s.state:
            result = s.state[$sdtRespinsCount].toInt()


proc init*(s: SlotContext, profile: Profile, gameSlotID: string) {.async.} =
    s.profile = profile
    s.gameId = gameSlotID
    s.machineId = await profile.getMachineIdByGameId(gameSlotID)
    s.machine = await profile.getSlotMachineByGameID(gameSlotID)


method saveStateAndProfile*(s: SlotContext, nextState: Bson) {.base, async.} =
    s.state = nextState
    s.profile{$sdtSlotResult, s.machineId} = nextState
    await s.profile.commit()


method getPredefinedSpin*(s: SlotContext, profile: Profile, index: int): Bson {.base.} =
    result = profile.predefinedSpin(s.gameId, index)


proc ensureStateExists*(s: SlotContext, profile: Profile) {.async.} =
    if s.state.isNil:
        var initialState = s.machine.createInitialState(profile)
        initialState[$sdtPredefinedSpins] = 0.toBson()
        await s.saveStateAndProfile(initialState)


method getBets*(s: SlotContext, fromSpin = false): BetConfig {.base.} =
    result.bets = @[]

    let gb = s.profile.getGameBalance()
    var allowedBets = gb.betLevels(s.profile.level)
    result.bets = allowedBets

    var lastSlotBet: int64 = 0
    if not s.state.isNil:
        if $sdtBet in s.state:
            lastSlotBet = s.state[$sdtBet].toInt64()

        elif "bt" in s.state: # balloon slot
            lastSlotBet = s.state["bt"].toInt64()

    var numberOfRs = s.numberOfRespins()
    var numberOfFs = s.numberOfFreespins()
    if numberOfFs > 0:
        result.bet = lastSlotBet
        if s.gameId == "ufoSlot":
            result.bet = result.bet div 2

        result.hardBet = numberOfFs

    elif numberOfRs > 0:
        result.bet = lastSlotBet
        if s.gameId == "ufoSlot":
            result.bet = result.bet div 2

        result.hardBet = numberOfRs
    else:
        let qm = newQuestManager(s.profile)
        var aq = qm.getActiveSlotQuest(s.gameId)

        if not aq.isNil and gb.taskBets[aq.tasks[0].difficulty]:
            result.bet = result.bets[^1]
            if fromSpin:
                result.hardBet = 0
            else:
                result.hardBet = 1
        else:
            result.bet = closestBet(allowedBets, s.profile.chips, 30)

        result.bet = result.bet div s.machine.numberOfLines()


method updateResponse*(s: SlotContext, resp: JsonNode) {.base.} = discard


type TournamentSlotContext* = ref object of SlotContext
    tournament*: Tournament


method saveStateAndProfile*(s: TournamentSlotContext, nextState: Bson) {.async.} =
    s.state = nextState
    s.tournament.participation.slotState = nextState
    await s.tournament.participation.commit()
    await s.profile.commit()


method getBets*(s: TournamentSlotContext, fromSpin = false): BetConfig =
    if s.tournament.bet > 0:
        result.bets = @[]
        result.bets.add(s.tournament.bet)
        result.bet = s.tournament.bet div s.machine.numberOfLines()
        result.hardBet = 1
    else:
        return procCall s.SlotContext.getBets(fromSpin)


method getPredefinedSpin*(s: TournamentSlotContext, profile: Profile, index: int): Bson =
    discard


type FreeRoundsSlotContext* = ref object of SlotContext
    freeRounds*: FreeRounds


method saveStateAndProfile*(s: FreeRoundsSlotContext, nextState: Bson) {.async.} =
    s.state = nextState
    s.freeRounds{$sdtSlotResult, s.machineId} = nextState
    await s.freeRounds.save()
    await s.profile.commit()


method getBets*(s: FreeRoundsSlotContext, fromSpin = false): BetConfig =
    let bets = procCall s.SlotContext.getBets(fromSpin)
    let bet = bets.bets[0]
    result = (@[bet], bet, 0)


method getPredefinedSpin*(s: FreeRoundsSlotContext, profile: Profile, index: int): Bson =
    discard


method updateResponse*(cs: FreeRoundsSlotContext, resp: JsonNode) =
    let rounds = cs.freeRounds.toJson()

    let roundsCount = cs.freeRounds.roundsCount(cs.gameId)
    let isFinished = roundsCount > 0 and cs.freeRounds.rounds(cs.gameId) == roundsCount and cs.numberOfFreespins() == 0 and cs.numberOfRespins() == 0

    if isFinished:
        resp[FREE_ROUNDS_JSON_KEY & "Finished"] = %cs.gameId
    resp[FREE_ROUNDS_JSON_KEY] = rounds


proc getDefaultSlotContext*(profile: Profile, gameSlotID: string): Future[SlotContext] {.async.} =
    result = SlotContext.new()
    await result.init(profile, gameSlotID)
    result.state = profile{$sdtSlotResult, result.machineId}
    await result.ensureStateExists(profile)


proc getTournamentSlotContext*(profile: Profile, gameSlotID: string, tournament: Tournament): Future[TournamentSlotContext] {.async.} =
    result = TournamentSlotContext.new()
    await result.init(profile, gameSlotID)
    result.tournament = tournament
    result.state = tournament.participation.slotState
    await result.ensureStateExists(profile)


proc getFreeRoundsSlotContext*(profile: Profile, gameSlotID: string, freeRounds: FreeRounds, jData: JsonNode): Future[FreeRoundsSlotContext] {.async.} =
    result = FreeRoundsSlotContext.new()
    await result.init(profile, gameSlotID)
    result.freeRounds = freeRounds
    result.state = freeRounds{$sdtSlotResult, result.machineId}
    await result.ensureStateExists(profile)

    let bets = result.getBets()
    jData[$srtBet] = %(bets.bets[bets.hardBet] div jData{$srtLines}.getBiggestInt(1))


proc getSlotContext*(profile: Profile, gameSlotID: string, requestBody: JsonNode): Future[(JsonNode, SlotContext)] {.async.} =
    var sc: SlotContext

    if sc.isNil:
        let (err, tournament) = await tournamentSpinIsValid(profile["_id"], gameSlotID, requestBody)
        if not err.isNil:
            result[0] = err
            echo "tournamentSpin validation failure - ", err
            return
        if not tournament.isNil:
            sc = await profile.getTournamentSlotContext(gameSlotID, tournament)

    if sc.isNil:
        let (err, freeRounds) = await freeRoundsSpinIsValid(profile["_id"], gameSlotID, requestBody)
        if not err.isNil:
            result[0] = err
            echo "freeRoundsSpin validation failure - ", err
            return
        if not freeRounds.isNil:
            sc = await profile.getFreeRoundsSlotContext(gameSlotID, freeRounds, requestBody)

    if sc.isNil:
        sc = await profile.getDefaultSlotContext(gameSlotID)

    result[1] = sc
