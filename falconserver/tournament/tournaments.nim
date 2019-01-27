import json
import logging
import oids
import random
import sequtils
import algorithm
import strutils
import tables
import times
import math

import nimongo.bson
import nimongo.mongo

import falconserver / auth / [ profile, profile_types ]
import falconserver / slot / [ machine_base, machine_base_server ]
import falconserver / common / [ object_id, game_balance, bson_helper, db, orm, stats, notifications, config ]
import shafa / slot / slot_data_types

import falconserver.map.map

import falconserver.boosters.boosters
import falconserver / free_rounds / free_rounds

import asyncdispatch
import falconserver.schedule
import falconserver.nester

import rewards


proc tournamentsDB(): Collection[AsyncMongo] =
    result = sharedDB()["tournaments"]

proc participationsDB(): Collection[AsyncMongo] =
    result = sharedDB()["tournamentplayers"]

type
    TournamentParticipantFields* = enum
        tpfId           = "_id"    ## Object ID
        tpfTournamentId = "tour"   ## Tournament ID
        tpfProfileId    = "prof"   ## Profile ID
        tpfProfileName  = "pname"  ## Profile name
        tpfIsBot        = "isBot"  ## Participation is for bot
        tpfBotID        = "botID"  ## Participating bot ID
        tpfScore        = "score"  ## Tournament score
        tpfScoreTime    = "scoret" ## Tournament score change timestamp
        tpfRewardPoints = "rewpt"  ## Reward - tournament points
        tpfRewardChips  = "rewch"  ## Reward - chips
        tpfRewardBucks  = "rewbk"  ## Reward - bucks
        tpfRewardFreeRounds = "rewFR"
        tpfFinalPlace   = "place"
        #tpfTotalPlayers = "players"
        tpfTitle        = "title"
        tpfPlayers      = "players"
        tpfStartDate    = "starts"
        tpfEndDate      = "ends"
        tpfSlot         = "slot"
        tpfEntryFee     = "fee"
        tpfBet          = "bet"
        tpfChipsPrizeFund  = "prizeCh"
        tpfBucksPrizeFund  = "prizeBk"
        tpfBoosted      = "boosted"
        tpfBoostRate    = "boostR"

CachedObj Participation:
    id: Oid($tpfId)
    tournamentId: Oid($tpfTournamentId)
    profileId: Oid($tpfProfileId)
    profileName: string($tpfProfileName)
    isBot: bool($tpfIsBot)
    botIdle: bool("botIdle")
    botID: Oid($tpfBotID)
    score: int($tpfScore)
    scoreTime: Time($tpfScoreTime)
    rewardPoints: int64($tpfRewardPoints)
    rewardChips: int64($tpfRewardChips)
    rewardBucks: int64($tpfRewardBucks)
    finalPlace: int($tpfFinalPlace)
    spinPayout: int64("spPay")
    slotState: Bson($sdtSlotResult)
    joinTime: Time("joinT")
    boosted: bool($tpfBoosted)
    boostRate: float($tpfBoostRate)

    tournamentTitle: string($tpfTitle)
    tournamentPlayers: int($tpfPlayers)
    tournamentStartDate: Time($tpfStartDate)
    tournamentEndDate: Time($tpfEndDate)
    tournamentSlotKey: string($tpfSlot)
    tournamentEntryFee: int($tpfEntryFee)
    tournamentBet: int($tpfBet)
    tournamentPrizeFundChips: int64($tpfChipsPrizeFund)
    tournamentPrizeFundBucks: int64($tpfBucksPrizeFund)

type
    ParticipationTable* = ref Table[string, Participation]


proc newParticipation(b: Bson): Participation =
    result.new
    result.init(participationsDB(), b)


proc findParticipation*(partId: Oid): Future[Participation] {.async.} =
    try:
        let dbResult = await participationsDB().find(bson.`%*`({$tpfId: partId})).one()
        result = newParticipation(dbResult)
    except:
        result = nil


proc findProfileTournamentsFinished*(profile: Profile): Future[int] {.async.} =
    result = await participationsDB().find(bson.`%*`({$tpfProfileId: profile.id, $tpfFinalPlace: {"$gt": 0}})).count()


proc findTournamentParticipants*(tournamentId: Oid): Future[seq[Participation]] {.async.} =
    result = newSeq[Participation]()
    let cursor = participationsDB().find(bson.`%*`({$tpfTournamentId: tournamentId}))
    cursor.limit(900)
    let dbResults = await cursor.all()
    for dbResult in dbResults:
        result.add(newParticipation(dbResult))


proc findTournamentBotParticipants*(tournamentId: Oid): Future[seq[Participation]] {.async.} =
    result = newSeq[Participation]()
    let cursor = participationsDB().find(bson.`%*`({$tpfTournamentId: tournamentId, $tpfIsBot: true}))
    cursor.limit(900)
    let dbResults = await cursor.all()
    for dbResult in dbResults:
        result.add(newParticipation(dbResult))


proc profileParticipates*(tournamentId: Oid, profileId: Oid): Future[bool] {.async.} =
    let dbResults = await participationsDB().find(bson.`%*`({$tpfTournamentId: tournamentId, $tpfProfileId: profileId})).all()
    result = dbResults.len > 0


type
    TournamentFields* = enum
        tfId              = "_id"
        tfTitle           = "title"
        tfSlot            = "slot"
        tfBet             = "bet"
        tfPlayers         = "players"
        tfStartDate       = "starts"
        tfEndDate         = "ends"
        tfLevel           = "level"
        tfEntryFee        = "fee"
        tfChipsPrizeFund  = "prize"
        tfBucksPrizeFund  = "prizeBk"
        tfClosed          = "closed"
        tfHidden          = "hidden"
        tfTutorialProfile = "tutorProf"

CachedObj Tournament:
    id: Oid($tfId)
    title: string($tfTitle)
    slotKey: string($tfSlot)
    bet: int($tfBet)
    playersCount: int($tfPlayers)
    startDate: Time($tfStartDate)
    endDate: Time($tfEndDate)
    level: int($tfLevel)
    entryFee: int($tfEntryFee)
    chipsPrizeFund: int64($tfChipsPrizeFund)
    bucksPrizeFund: int64($tfBucksPrizeFund)
    isClosed: bool($tfClosed)
    isHidden: bool($tfHidden)
    tutorialProfile: Oid($tfTutorialProfile)
    participation: Participation

type
    TournamentTable* = ref Table[string, Tournament]


proc isRunning*(t: Tournament): bool =
    let curTime = getTime()
    result = t.startDate <= curTime  and  not t.isClosed
    if $tfEndDate in t.bson:
        result = result  and  curTime < t.endDate

proc timePassed*(t: Tournament): float =
    getTime().toSeconds - t.startDate.toSeconds


proc timeLeft*(t: Tournament): float =
    t.endDate.toSeconds - getTime().toSeconds


proc newTournament(b: Bson): Tournament =
    result.new
    result.init(tournamentsDB(), b)


proc findTournament*(id: Oid): Future[Tournament] {.async.} =
    try:
        let dbResult = await tournamentsDB().find(bson.`%*`({$tfId: id})).one()
        result = newTournament(dbResult)
    except:
        result = nil


proc findAllTournaments*(): Future[TournamentTable] {.async.} =
    result = newTable[string, Tournament]()
    var dbResults = await tournamentsDB().find(bson.`%*`({$tfHidden: {"$ne": true}})).all()
    for dbResult in dbResults:
        let tournament = newTournament(dbResult)
        result[$tournament.id] = tournament


proc findProfileParticipations*(profile: Profile): Future[ParticipationTable] {.async.} =
    result = newTable[string, Participation]()
    let dbParticipations = await participationsDB().find(bson.`%*`({$tpfProfileId: profile.id})).all()
    for dbParticipation in dbParticipations:
        let p = newParticipation(dbParticipation)
        result[$p.id] = p


proc boostProfileParticipations*(p: Profile): Future[void] {.async.} =
    let reply = await participationsDB().update(bson.`%*`({$tpfProfileId: p.id}), bson.`%*`({"$set": {$tpfBoosted: true}}), multi = true, upsert = false)
    # echo "DDD boosting ", reply.n, " participations"
    checkMongoReply reply


proc archivedTournament*(p: Participation): Tournament =
    result = newTournament(B())
    result.id = p.tournamentId
    result.isClosed = true
    result.title = p.tournamentTitle
    result.slotKey = p.tournamentSlotKey
    result.playersCount = p.tournamentPlayers
    result.startDate = p.tournamentStartDate
    result.endDate = p.tournamentEndDate
    result.bet = p.tournamentBet
    result.chipsPrizeFund = p.tournamentPrizeFundChips
    result.bucksPrizeFund = p.tournamentPrizeFundBucks


proc findAllTournamentsAndProfileParticipation(profile: Profile): Future[TournamentTable] {.async.} =
    result = await findAllTournaments()

    let participations = await findProfileParticipations(profile)

    for key, p in participations:
        if not result.hasKey($p.tournamentId):
            if p.rewardPoints > 0:
                result[$p.tournamentId] = p.archivedTournament()
            else:
                let t = await findTournament(p.tournamentId)
                if not t.isNil:
                    result[$t.id] = t
        if result.hasKey($p.tournamentId):
            result[$p.tournamentId].participation = p


proc closeTournament(t: Tournament): Future[void] {.async.} =
    logTournamentsDetails "Closing tournament '", t.title, "' (", t.id, ") ended at ", t.endDate
    t.isClosed = true
    await t.commit()


proc initialChipsReward(cfg: TournamentsConfig, duration: int, level: int): int64 =
    (cfg.levels[level].chipsRewardPerHour * duration) div (60 * 60)

proc chipsPrizeIncrement(cfg: TournamentsConfig, t: Tournament): int64 =
    (cfg.levels[t.level].chipsRewardPer10KBet * (t.bet + t.entryFee)) div 10_000

proc initialBucksReward(cfg: TournamentsConfig, duration: int, level: int): int64 =
    (cfg.levels[level].bucksRewardPerHour * duration) div (60 * 60)

proc bucksPrizeIncrement(cfg: TournamentsConfig, t: Tournament): int64 =
    (cfg.levels[t.level].bucksRewardPer10KBet * (t.bet + t.entryFee)) div 10_000


proc gainParticipationScore*(t: Tournament, p: Participation, scoreGain: int): Future[void] {.async.} =
    let cfg = sharedGameConfig().tournaments

    assert(p.tournamentID == t.id)

    if scoreGain == 0:
        return

    if p.score == 0 and t.entryFee == 0:
        t.chipsPrizeFund = t.chipsPrizeFund + chipsPrizeIncrement(cfg, t)
        t.bucksPrizeFund = t.bucksPrizeFund + bucksPrizeIncrement(cfg, t)
        logTournamentsDetails "User '", p.profileName, "' (", p.profileId, ") gained first score ", scoreGain, " in free tournament '", t.title, "' (fee = ", t.entryFee, ", bet = ", t.bet, "),",
            "  prizeFund chips = ", t.chipsPrizeFund, ", bucks = ", t.bucksPrizeFund
        # ORM temporary workaround:
        # await t.commit()
        checkMongoReply await t.collection.update(
            bson.`%*`({"_id": t.bson["_id"]}),
            bson.`%*`({"$inc": {
                $tfChipsPrizeFund: chipsPrizeIncrement(cfg, t),
                $tfBucksPrizeFund: bucksPrizeIncrement(cfg, t)}}),
            multi = false, upsert = false)
    else:
        logTournamentsDetails "User '", p.profileName, "' (", p.profileId, ") gained score ", scoreGain, " in tournament ", p.tournamentId

    p.score = p.score + scoreGain
    p.scoreTime = getTime()
    await p.commit()


proc finalize(p: Participation, t: Tournament, place: int): Future[void] {.async.} =
    p.finalPlace = place
    p.rewardPoints = calcRewardPoints(t.playersCount, place, p.score)
    if $tpfBoostRate in p.bson:
        p.rewardPoints = (p.rewardPoints.float * p.boostRate).int
    elif p.boosted:
        # echo "DDD tournament points boosting ", p.rewardPoints, " -> ", (p.rewardPoints.float * sharedGameBalance().boosters.tournamentPointsRate).int
        p.rewardPoints = (p.rewardPoints.float * sharedGameBalance().boosters.tournamentPointsRate).int
    p.rewardChips = calcRewardCurrency(t.chipsPrizeFund, t.playersCount, place)
    p.rewardBucks = calcRewardCurrency(t.bucksPrizeFund, t.playersCount, place)

    logTournamentsDetails "Rewarding #", place, " player '", p.profileName, "'' with ", p.rewardPoints, " points and ", p.rewardChips, " chips"

    p.tournamentTitle = t.title
    p.tournamentSlotKey = t.slotKey
    p.tournamentPlayers = t.playersCount
    p.tournamentStartDate = t.startDate
    p.tournamentEndDate = t.endDate
    p.tournamentEntryFee = t.entryFee
    p.tournamentBet = t.bet
    p.tournamentPrizeFundChips = t.chipsPrizeFund
    p.tournamentPrizeFundBucks = t.bucksPrizeFund

    await p.commit()


proc leaveTournament*(participation: Participation): Future[void] {.async.} =
    logTournamentsDetails participation.profileId, " leaving participation ", participation.id , " in tournament ", participation.tournamentId
    checkMongoReply await tournamentsDB().update(
        bson.`%*`({$tfId: participation.tournamentId}),
        bson.`%*`({"$inc": {$tfPlayers: -1}}),
        multi = false, upsert = false)
    checkMongoReply await participationsDB().remove(bson.`%*`({$tpfId: participation.id}))


# for reset_progress cheat
proc leaveAllTournaments*(profile: Profile): Future[void] {.async.} =
    let participations = await profile.findProfileParticipations()
    for key, p in participations:
        await p.leaveTournament()


proc finishTournament(tournament: Tournament): Future[void] {.async.} =
    # if forceDate:
    #     tournament.endDate = getTime() + initInterval(seconds = 10)
    #     echo await tournamentsDB().update(bson.`%*`({$tfId: tournament.id}),
    #         bson.`%*`({"$set": {$tfEndDate: tournament.endDate}}),
    #         multi = false, upsert = false )

    logTournaments "Finishing tournament '", tournament.title, "' ended at ", tournament.endDate, ",  prizeFund:  chips = ", tournament.chipsPrizeFund, ", bucks = ", tournament.bucksPrizeFund

    await tournament.closeTournament()

    var participants = await findTournamentParticipants(tournament.id)
    participants.sort do (p1, p2: Participation) -> int:
        result = cmp(p2.score, p1.score)
        if result == 0:
            result = cmp(p1.scoreTime, p2.scoreTime)

    for place in 1..participants.len:
        let p = participants[place - 1]
        await p.finalize(tournament, place)

    discard await tournamentsDB().remove(bson.`%*`({"_id": tournament.id}))

    for p in participants:
        if p.isBot:
            await p.leaveTournament()
        else:
            await notifyTournamentFinished(p.profileID, p.id)


proc forceFinish(t: Tournament, seconds: int): Future[void] {.async.} =
    t.endDate = getTime() + initInterval(seconds = seconds)
    logTournaments "Forcing tournament '", t.title, "' finish at ", t.endDate
    await t.commit()
    await rescheduleTask( "finish tournament", bson.`%*`({ "tournamentID": t.id }), t.endDate.toSeconds )


const fastStartDelay = 10
const fastDurationRatio = 3

proc createTournament(title: string, slotKey: string, level: int, bet: int64, entryFee: int64, chipsPrizeFund: int64, bucksPrizeFund: int64, startDelay: int, duration: int, allowBotsJoin: bool) {.async.} =
        let startDate = getTime() + initInterval(seconds = startDelay)
        let endDate = startDate + initInterval(seconds = duration)

        let tournamentID = genOid()
        logTournaments "Adding tournament '", title, "'  (", tournamentID, ")"

        await scheduleTask( endDate.toSeconds, "finish tournament", bson.`%*`({ "tournamentID": tournamentID }) )

        if allowBotsJoin:
            await scheduleTask( startDate.toSeconds, "tournament bots join", bson.`%*`({ "tournamentID": tournamentID }) )

        await scheduleTask( startDate.toSeconds, "tournament bots spin", bson.`%*`({ "tournamentID": tournamentID }) )

        # in case server will crash while executing tournament creation, we create tournament just after scheduling all related tasks
        discard await tournamentsDB().insert(bson.`%*`({
            $tfId: tournamentID,
            $tfTitle: title,
            $tfSlot: slotKey,
            $tfBet: bet,
            $tfPlayers: 0,
            $tfStartDate: startDate,
            $tfEndDate: endDate,
            $tfLevel: level,
            $tfEntryFee: entryFee,
            $tfChipsPrizeFund: chipsPrizeFund,
            $tfBucksPrizeFund: bucksPrizeFund,
             }), ordered = true, writeConcern = nil)


proc getRandomTournamentLevel(cfg: TournamentsConfig): int =
    var rollSum = 0.0
    for k, v in cfg.levels:
        rollSum += v.probability

    var roll = random(rollSum)
    for k, v in cfg.levels:
        if roll <= v.probability:
            return k
        else:
            roll -= v.probability


proc generateTournaments(cfg: TournamentsConfig, count: int, fast: bool = false): Future[void] {.async.} =
    for i in 1 .. count:
        let slotLevel = cfg.getRandomTournamentLevel()
        let tc = cfg.levels[slotLevel].cases.random()
        let slot = cfg.slots[tc.slotKey]

        await createTournament(title = if fast: "_" & tc.name & "_"  else: tc.name,
                               slotKey = tc.slotKey,
                               level = tc.level,
                               bet = tc.bet,
                               entryFee = tc.entryFee,
                               chipsPrizeFund = initialChipsReward(cfg, tc.duration, tc.level),
                               bucksPrizeFund = initialBucksReward(cfg, tc.duration, tc.level),
                               startDelay = if fast: fastStartDelay  else: cfg.startDelay,
                               duration = if fast: tc.duration div fastDurationRatio  else: tc.duration,
                               allowBotsJoin = not fast)

    await reportTournamentCreated(count, fast)


proc findOrCreateTutorialTournament*(p: Profile): Future[Tournament] {.async.} =
    let cfg = sharedGameConfig().tournaments
    #let tutorialSlotKeys = filter(toSeq(keys(cfg.slots)), proc (k: string): bool = cfg.slots[k].tutorialTournamentName.len > 0)
    let tutorialSlotKeys = filter(toSeq(keys(cfg.slots)),
        proc (k: string): bool =  parseEnum[BuildingId](k) in p.slotsBuilded())
    let slotKey = tutorialSlotKeys.random()
    let slot = cfg.slots[slotKey]

    let tournamentID = genOid()
    checkMongoReply await tournamentsDB().update(
        bson.`%*`({
            $tfHidden: true,
            $tfTutorialProfile: p.id,
        }),
        bson.`%*`({
            "$setOnInsert": {
                $tfId: tournamentID,
                $tfTitle: slot.tutorialTournamentName,
                $tfSlot: slotKey,
                $tfBet: cfg.tutorialBet,
                $tfPlayers: 0,
                $tfStartDate: getTime(),
                $tfLevel: 0,
                $tfEntryFee: cfg.tutorialEntryFee,
                $tfChipsPrizeFund: initialChipsReward(cfg, cfg.tutorialDuration, level = 1),
                $tfBucksPrizeFund: initialBucksReward(cfg, cfg.tutorialDuration, level = 1)
            }
        }),
        multi = false, upsert = true)
    let tdata = await tournamentsDB().find(bson.`%*`({$tfTutorialProfile: p.id})).one()
    result = newTournament(tdata)
    logTournaments "Got tutorial tournament ", result.title
    let pdata = await participationsDB().find(bson.`%*`({$tpfTournamentId: result.id, $tpfProfileId: p.id})).oneOrNone()
    if not pdata.isNil:
        result.participation = newParticipation(pdata)


proc createFastTournament*(): Future[void] {.async.} =
    await generateTournaments(sharedGameConfig().tournaments, 1, fast = true)


proc createTournamentWithConfig*(req: JsonNode): Future[string] {.async.} =
    let cfg = sharedGameConfig().tournaments

    let title = req{"title"}.getStr(default = nil)
    if title.len == 0  or  title.len > 30:
        return "Incorrect title '" & title & "'"

    let slotKey = req{"slot"}.getStr(default = nil)
    if slotKey notin cfg.slots:
        return "Unknown slot '" & slotKey & "'"

    let level = req{"level"}.getInt()
    if level < 1 or level > 2:
        return "Invalid level " & $level

    let bet = req{"bet"}.getInt()
    if bet <= 0 or bet > 1_000_000_000:
        return "Invalid bet " & $bet

    let entryFee = req{"entryFee"}.getInt()
    if entryFee <= 0 or entryFee > 1_000_000_000:
        return "Invalid entry fee " & $entryFee

    let chipsPrizeFund = req{"chipsPrizeFund"}.getInt()
    if chipsPrizeFund < 0 or chipsPrizeFund > 1_000_000_000_000:
        return "Invalid chips prize fund " & $chipsPrizeFund

    let bucksPrizeFund = req{"bucksPrizeFund"}.getInt()
    if bucksPrizeFund < 0 or bucksPrizeFund > 1_000_000_000_000:
        return "Invalid bucks prize fund " & $bucksPrizeFund

    let startDelay = req{"startDelay"}.getInt()
    if startDelay < 0 or startDelay > 1_000_000:
        return "Invalid start delay " & $startDelay

    let duration = req{"duration"}.getInt()
    if duration < 0 or duration > 1_000_000:
        return "Invalid duration " & $duration

    await createTournament(title = title,
                           slotKey = slotKey,
                           level = level,
                           bet = bet,
                           entryFee = entryFee,
                           chipsPrizeFund = chipsPrizeFund,
                           bucksPrizeFund = bucksPrizeFund,
                           startDelay = startDelay,
                           duration = duration,
                           allowBotsJoin = true)


proc joinTournament*(profile: Profile, t: Tournament): Future[Participation] {.async.} =
    let cfg = sharedGameConfig().tournaments

    let updateBson = bson.`%*`({"$inc": {$tfPlayers: 1}})
    t.playersCount = t.playersCount + 1

    if t.entryFee > 0:
        profile.chips = profile.chips - t.entryFee
        t.chipsPrizeFund = t.chipsPrizeFund + chipsPrizeIncrement(cfg, t)
        t.bucksPrizeFund = t.bucksPrizeFund + bucksPrizeIncrement(cfg, t)
        updateBson["$inc"][$tfChipsPrizeFund] = chipsPrizeIncrement(cfg, t).toBson()
        updateBson["$inc"][$tfBucksPrizeFund] = bucksPrizeIncrement(cfg, t).toBson()

    logTournamentsDetails if profile{$tpfBotID}.isNil: "" else: "Bot ", "'", profile.name, "' (", profile.id, ")  joining tournament '",
        t.title, "' (fee = ", t.entryFee, ", bet = ", t.bet, "),  total players = ", t.playersCount, ", prizeFund: chips = ", t.chipsPrizeFund, ", bucks = ", t.bucksPrizeFund

    let part = newParticipation(newBsonDocument())
    part.id = genOid()
    part.tournamentId = t.id
    part.profileId = profile.id
    part.profileName = profile.name
    part.joinTime = getTime()
    let botID = profile{$tpfBotID}
    if not botID.isNil:
        part.isBot = true
        part.botID = botID
    part.score = 0
    part.scoreTime = getTime()
    if profile.boosters.affectsTournaments():
        # echo "DDD participation is boosted"
        part.boosted = true
        part.boostRate = profile.gconf.getGameBalance().boosters.tournamentPointsRate
    discard await participationsDB().insert(part.mongoSetDict())

    # ORM temporary workaround:
    # await tournament.commit()

    if t.isHidden  and  t.tutorialProfile == profile.id:
        let cfg = sharedGameConfig().tournaments
        t.startDate = getTime()
        t.endDate = t.startDate + initInterval(seconds = cfg.tutorialDuration)
        updateBson["$set"] = bson.`%*`({$tfStartDate: t.startDate, $tfEndDate: t.endDate})
        await scheduleTask( t.endDate.toSeconds, "finish tournament", bson.`%*`({ "tournamentID": t.id }) )
        await scheduleTask( getTime().toSeconds, "tournament bots join", bson.`%*`({ "tournamentID": t.id }) )
        await scheduleTask( getTime().toSeconds, "tournament bots spin", bson.`%*`({ "tournamentID": t.id }) )

    checkMongoReply await t.collection.update(
        bson.`%*`({$tfId: t.id}),
        updateBson,
        multi = false, upsert = false)

    await profile.commit()
    #logTournamentsDetails "prizeFund is ", (await findTournament(t.id)).prizeFund
    return part


proc ufoFreeRoundsReward(profile: Profile, part: Participation): int =
    var rewardTag = ""
    if part.tournamentEntryFee == 0:
        rewardTag = "free_"
    else:
        rewardTag = "paid_"

    if part.finalPlace == 1:
        rewardTag &= "winner"
    elif part.rewardChips > 0 or part.rewardBucks > 0:
        rewardTag &= "prize"
    else:
        rewardTag &= "participant"

    let rew = profile.gconf.getGameBalance().tournamentRewards
    if not rew.isNil and rewardTag in rew:
        result = rew{rewardTag}.getInt()


proc claimTournamentReward*(profile: Profile, p: Participation): Future[JsonNode] {.async.} =
    let freeRoundsReward = profile.ufoFreeRoundsReward(p)
    logTournamentsDetails profile.id, " claiming reward for participation ", p.id , " in tournament ", p.tournamentId, " - ",
            p.rewardChips, " chips, ", p.rewardBucks, " bucks and ", p.rewardPoints, " tournament points"
    profile.chips = profile.chips + p.rewardChips
    profile.bucks = profile.bucks + p.rewardBucks
    profile.tourPoints = profile.tourPoints + p.rewardPoints

    result = json.`%*`({"status": "Ok", "response": {
        "chips": p.rewardChips, "bucks": p.rewardBucks, "tourPoints": p.rewardPoints}})

    if freeRoundsReward > 0:
        let freeRounds = await getOrCreateFreeRounds(profile.id)
        freeRounds.addFreeRounds($ufoSlot, freeRoundsReward)
        await freeRounds.save()
        result["response"]["freeRounds"] = %freeRoundsReward
        result[FREE_ROUNDS_JSON_KEY] = freeRounds.toJson()

    await profile.commit()
    await cancelNotifyTournamentFinished(profile.id, p.id)


proc getParticipants(t: Tournament, sinceTime: float): Future[JsonNode] {.async.} =
    result = newJObject()
    let participants = await findTournamentParticipants(t.id)
    for p in participants:
        if sinceTime == 0 or p.scoreTime.toSeconds > sinceTime:
            let json = newJObject()
            if sinceTime == 0 or p.joinTime.toSeconds > sinceTime:
                json["profileId"] = % $p.profileId
                json["playerName"] = %(if p.profileName.len == 0: "Player"  else: p.profileName)
            json["score"] = %p.score
            json["scoreTime"] = %p.scoreTime.toSeconds
            result[$p.id] = json


proc listTournaments*(profile: Profile, sinceTimeSet: JsonNode): Future[JsonNode] {.async.} =
    let tournaments = await findAllTournamentsAndProfileParticipation(profile)

    result = newJObject()

    let response = newJObject()
    result["tournaments"] = response

    for key, t in tournaments:
        let isFinished = (getTime() > t.endDate or t.isClosed)

        if isFinished and t.timeLeft() < -60:  # more than one minute closing delay for unknown reason
            await rescheduleTask( "finish tournament", bson.`%*`({ "tournamentID": t.id }), 1 )  # to highest priority

        if not isFinished or not t.participation.isNil:
            let json = newJObject()
            json[$tfTitle] = %t.title
            json[$tfSlot] = %t.slotKey
            json[$tfBet] = %t.bet
            json[$tfPlayers] = %t.playersCount
            json[$tfStartDate] = %t.startDate.toSeconds
            json[$tfEndDate] = %t.endDate.toSeconds
            json[$tfLevel] = %t.level
            json[$tfEntryFee] = %t.entryFee
            json[$tfChipsPrizeFund] = %t.chipsPrizeFund
            json[$tfBucksPrizeFund] = %t.bucksPrizeFund
            if t.isClosed:
                json[$tfClosed] = %t.isClosed
            let p = t.participation
            if not p.isNil:
                json["partId"] = % $p.id
                json[$tpfScore] = %p.score
                if p.boosted:
                    json[$tpfBoosted] = %p.boosted
                if t.isClosed:
                    json[$tpfRewardPoints] = %p.rewardPoints
                    json[$tpfRewardChips] = %p.rewardChips
                    json[$tpfRewardBucks] = %p.rewardBucks
                    json[$tpfFinalPlace] = %p.finalPlace
                    let freeRoundsReward = profile.ufoFreeRoundsReward(p)
                    if freeRoundsReward > 0:
                        json[$tpfRewardFreeRounds] = %freeRoundsReward
                else:
                    var sinceTime = 0.0
                    if not sinceTimeSet.isNil  and  key in sinceTimeSet:
                        sinceTime = sinceTimeSet[key].getFloat()
                    json["participants"] = await t.getParticipants(sinceTime)
            response[key] = json


proc getTutorialTournamentResp*(t: Tournament): Future[JsonNode] {.async.} =
    result = newJObject()

    let response = newJObject()
    result["tournaments"] = response

    let json = newJObject()
    json[$tfTitle] = %t.title
    json[$tfSlot] = %t.slotKey
    json[$tfBet] = %t.bet
    json[$tfPlayers] = %t.playersCount
    json[$tfStartDate] = %t.startDate.toSeconds
    if $tfEndDate in t.bson:
        json[$tfEndDate] = %t.endDate.toSeconds
    else:
        json["duration"] = %sharedGameConfig().tournaments.tutorialDuration
    json[$tfLevel] = %t.level
    json[$tfEntryFee] = %t.entryFee
    json[$tfChipsPrizeFund] = %t.chipsPrizeFund
    json[$tfBucksPrizeFund] = %t.bucksPrizeFund
    if t.isClosed:
        json[$tfClosed] = %t.isClosed
    let p = t.participation
    if not p.isNil:
        json["partId"] = % $p.id
        json[$tpfScore] = %p.score
        if t.isClosed:
            json[$tpfRewardPoints] = %p.rewardPoints
            json[$tpfRewardChips] = %p.rewardChips
            json[$tpfRewardBucks] = %p.rewardBucks
            json[$tpfFinalPlace] = %p.finalPlace
        else:
            json["participants"] = await t.getParticipants(sinceTime = 0.0)
    response[$t.id] = json


proc getDetails*(t: Tournament, sinceTime: float): Future[JsonNode] {.async.} =
    result = newJObject()
    result[$tfChipsPrizeFund] = %t.chipsPrizeFund
    result[$tfBucksPrizeFund] = %t.bucksPrizeFund
    result[$tfEndDate] = %(t.endDate.toSeconds)
    result["participants"] = await t.getParticipants(sinceTime)


proc tryGetTournamentDetails*(profile: Profile, jData: JsonNode): Future[JsonNode] {.async.} =
    let profileId = profile["_id"]
    let partId = jData["partId"].getStr().parseOid()
    logTournamentsDetails profileId, " requesting information with participation ", partId
    let p = await findParticipation(partId)
    if p.isNil:
        return json.`%*`({"status": "Bad input - not participated"})
    if p.profileId != profileId:
        echo "Bad input - wrong participation (requested from ", profileId, "  but belongs to ", p.profileId, ")"
        return json.`%*`({"status": "Bad input - wrong participation"})

    var t: Tournament
    if p.finalPlace > 0:
        t = p.archivedTournament()
    else:
        t = await findTournament(p.tournamentId)
    let resp = await t.getDetails(jData{"sinceTime"}.getFloat())
    if p.boosted:
        resp[$tpfBoosted] = %p.boosted
    result = json.`%*`({"status": "Ok", "response": resp})


proc tryForceFinishTournament*(profile: Profile, jData: JsonNode): Future[JsonNode] {.async.} =
    let profileId = profile["_id"]
    let tournamentId = jData["tournamentId"].getStr().parseOid()
    logTournaments profileId, " finishing tournament ", tournamentId
    let t = await findTournament(tournamentId)
    if t.isNil:
        return json.`%*`({"status": "Bad input - no tournament found"})
    if not t.isRunning():
        return json.`%*`({"status": "Bad input - tournament is not running"})
    await t.forceFinish(seconds = 15)
    let resp = await t.getDetails(jData{"sinceTime"}.getFloat())
    result = json.`%*`({"status": "Ok", "response": resp})


proc tryGainTournamentScore*(profile: Profile, jData: JsonNode): Future[JsonNode] {.async.} =
    let profileId = profile["_id"]
    let partId = jData["partId"].getStr().parseOid()
    logTournaments profileId, " gaining tournament participation score ", partId
    let p = await findParticipation(partId)
    if p.isNil:
        return json.`%*`({"status": "Bad input - not participated"})
    if p.profileId != profileId:
        echo "Bad input - wrong participation (requested from ", profileId, "  but belongs to ", p.profileId, ")"
        return json.`%*`({"status": "Bad input - wrong participation"})
    if p.finalPlace > 0:
        return json.`%*`({"status": "Tournament is already closed"})
    let t = await findTournament(p.tournamentId)
    if t.isNil:
        return json.`%*`({"status": "Bad input - no tournament found"})
    await t.gainParticipationScore(p, 5)
    let resp = await t.getDetails(jData{"sinceTime"}.getFloat())
    result = json.`%*`({"status": "Ok", "response": resp})


proc tryJoinTournament*(profile: Profile, jData: JsonNode): Future[JsonNode] {.async.} =
    let profileId = profile["_id"]
    let tournamentId = jData["tournamentId"].getStr().parseOid()
    logTournamentsDetails profileId, " joining participation in tournament ", tournamentId
    let t = await findTournament(tournamentId)
    if t.isNil:
        return json.`%*`({"status": "Bad input - no tournament found"})
    if not t.isRunning():
        return json.`%*`({"status": "Bad input - tournament is not running"})

    if profile.chips < t.entryFee:
        return json.`%*`({"status": "Bad input - not enough chips"})

    if $tfTutorialProfile notin t.bson  and  parseEnum[BuildingId](t.slotKey) notin profile.slotsBuilded():
        return json.`%*`({"status": "Bad input - slot is not available"})

    var participationSearch = await participationsDB().find(bson.`%*`({$tpfTournamentId: tournamentId, $tpfProfileId: profileId})).count
    if participationSearch > 0:
        return json.`%*`({"status": "Bad input - already participates"})

    let participation = await profile.joinTournament(t)
    logTournamentsDetails "Ok - participation ID = ", participation.id
    #let participants = await t.getParticipants(sinceTime = 0.0)
    result = await t.getDetails(sinceTime = 0.0)
    result["status"] = % "Ok"
    result["partId"] = % $participation.id
    result["chips"] = % profile.chips
    if participation.boosted or $tpfBoostRate in participation.bson:
        result[$tpfBoosted] = %participation.boosted
    #return json.`%*`({"status": "Ok", "partId": % $partId, "chips": %profile.chips, "participants": participants})


proc tryLeaveTournament*(profile: Profile, jData: JsonNode): Future[JsonNode] {.async.} =
    let profileId = profile["_id"]
    let partId = jData["partId"].getStr().parseOid()
    logTournamentsDetails profileId, " leaving participation ", partId
    let p = await findParticipation(partId)
    if p.isNil:
        return json.`%*`({"status": "Bad input - not participated"})
    if p.profileId != profileId:
        echo "Bad input - wrong participation (requested from ", profileId, "  but belongs to ", p.profileId, ")"
        return json.`%*`({"status": "Bad input - wrong participation"})

    await p.leaveTournament()
    return json.`%*`({"status": "Ok"})


proc tryClaimTournamentReward*(profile: Profile, jData: JsonNode): Future[JsonNode] {.async.} =
    let profileId = profile["_id"]
    let partId = jData["partId"].getStr().parseOid()
    logTournamentsDetails profileId, " claiming reward for participation ", partId
    let p = await findParticipation(partId)
    if p.isNil:
        return json.`%*`({"status": "Bad input - not participated"})
    if p.profileId != profileId:
        echo "Bad input - wrong participation (requested from ", profileId, "  but belongs to ", p.profileId, ")"
        return json.`%*`({"status": "Bad input - wrong participation"})
    # let t = await findTournament(p.tournamentId)
    # if not t.isNil and not t.isClosed:
    if p.finalPlace == 0:
        return json.`%*`({"status": "Bad input - tournament is not closed yet"})

    await p.leaveTournament()
    return await profile.claimTournamentReward(p)


proc tournamentSpinIsValid*(profileId: Oid, gameSlotId: string, jData: JsonNode): Future[tuple[j: JsonNode, t: Tournament]] {.async.} =
    var partIdData: JsonNode

    let mode = jData{"mode"}{"kind"}.getInt()
    if mode != smkTournament.int:
        partIdData = jData{"tournPartId"}
    else:
        partIdData = jData{"mode"}{"tournPartId"}
    if partIdData.isNil:
        return

    let partId = partIdData.getStr().parseOid()
    let p = await findParticipation(partId)
    if p.isNil:
        result.j = json.`%*`({"status": "Invalid tournament participation " & $partId})
        return
    if p.profileId != profileId:
        result.j = json.`%*`({"status": "Invalid tournament participation " & $partId & " user - expected " & $p.profileId & " but is " & $profileId})
        return

    var t: Tournament
    if p.finalPlace > 0:
        t = p.archivedTournament()
    else:
        t = await findTournament(p.tournamentId)
    if gameSlotId != t.slotKey:
        result.j = json.`%*`({"status": "Invalid tournament participation " & $partId & " slot - expected " & t.slotKey & " but is " & gameSlotId})
    t.participation = p
    #if not tournament.isAvailable():
    #    return json.`%*`({"status": "Tournament is finished"})
    result.t = t


proc scoreGain(t: Tournament, payout: int64): int =
    result = (payout.float / (t.bet.float * 0.5)).int


proc applyTournamentSpin*(profileId: Oid, t: Tournament, jData: JsonNode, resp: JsonNode, spinSequenceEnd: bool): Future[void] {.async.} =
    if not t.isRunning():
        logTournamentsDetails "Warning: score can't be gained on non-available tournament for participation ", t.participation.id
        return

    var totalGain = 0
    for st in resp["stages"]:
        let payout = st.calcPayout()
        if st[$srtStage].getStr() == "Bonus":
            let gain = t.scoreGain(payout)
            totalGain += gain
            if gain > 0:
                st["tournScoreGain"] = %gain
            logTournamentsDetails "Bonus game payout = ", payout, ",  bet = ", t.bet, ",  scoreGain = ", gain, ",  totalGain = ", totalGain
        else:
            if spinSequenceEnd:
                let totalPayout = payout + t.participation.spinPayout
                t.participation.spinPayout = 0
                let gain = t.scoreGain(totalPayout)
                totalGain += gain
                if gain > 0:
                    st["tournScoreGain"] = %gain
                logTournamentsDetails "Spin final payout = ", payout, ",  total = ", totalPayout, ",  bet = ", t.bet, ",  scoreGain = ", gain, ",  totalGain = ", totalGain
            else:
                t.participation.spinPayout = t.participation.spinPayout + payout
                logTournamentsDetails "Spin payout = ", payout, ",  total = ", t.participation.spinPayout

    await t.gainParticipationScore(t.participation, totalGain)
    await t.participation.commit()


proc onGenerateTournaments(args: Bson): Future[float] {.async.} =
    let cfg = sharedGameConfig().tournaments
    await generateTournaments(cfg, 1)
    return cfg.generationInterval.float

registerScheduleTask("generate tournaments", onGenerateTournaments, regular = true)


proc onFinishTournament(args: Bson): Future[float] {.async.} =
    let tID = args["tournamentID"]
    let t = await findTournament(tID)
    if t.isNil:
        echo "Warning: tournament ", tID, " not found."
        return 0

    logTournaments "Finishing tournament '", t.title, "'  (", tID, ")"
    await t.finishTournament()
    return 0

registerScheduleTask("finish tournament", onFinishTournament)
