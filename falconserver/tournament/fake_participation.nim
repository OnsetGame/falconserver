import json, logging

import oids
import random
import sequtils
import strutils
import tables
import times
import os except DeviceId
import nuuid
import streams

import nimongo.bson
import nimongo.mongo

import falconserver.auth.profile_types
import falconserver.auth.profile

import falconserver.slot.machine_base_server
import falconserver.slot.machine_balloon_server
import falconserver.slot.machine_classic_server
import falconserver.slot.machine_candy_server
import falconserver.slot.machine_ufo_server
import falconserver.slot.machine_witch_server
import falconserver.slot.machine_mermaid_server

import falconserver.tournament.tournaments
import falconserver.common.config

import falconserver.common.orm
import falconserver.common.db

import asyncdispatch
import falconserver.schedule


import parsecsv
type
    BotTemplateData = ref object
        name: string
        gender: string
        country: string
        #weight: int
        #totalWeight: int


const botNamesCSV = staticRead("falconserver/resources/bots/names.csv")

proc parseBotTemplates(): seq[BotTemplateData] =
    result = @[]
    var p: CsvParser
    #p.open("resources/bots/names.csv")
    let input = newStringStream(botNamesCSV)
    p.open(input, "names.csv")
    p.readHeaderRow()
    #var totalWeight = 0
    while p.readRow():
        let x = BotTemplateData.new
        x.name = p.rowEntry("Name")
        x.gender = p.rowEntry("Gender")
        x.country = p.rowEntry("Country")
        #x.weight = p.rowEntry("Weight").parseInt()
        #totalWeight += x.weight
        #x.totalWeight = totalWeight
        result.add(x)
    p.close()


CachedObj Bot:
    id: Oid("_id")
    index: int("index")
    profileID: Oid("profileID")
    gender: string("gender")
    country: string("country")


proc botCreateProfiles(count: int): Future[void] {.async.} =
    let profilesDB = sharedDB()["profiles"]
    let botsDB = sharedDB()["bots"]
    var botsCount = await botsDB.find(bson.`%*`({})).count()
    echo "Bots: ", botsCount, " available,  additional ", count - botsCount, " needed"
    if botsCount < count:
        let botTemplates = parseBotTemplates()
        while botsCount < count:
            let templ = botTemplates.random()
            let profileID = genOid()
            let botID = genOid()
            let bot = Bot.new
            bot.init(botsDB, bson.`%*`({}))
            let profileDoc = bson.`%*`({"_id": profileID, $tpfIsBot: true, $tpfBotID: botID, $prfName: templ.name, $prfChips: 99999999, $prfTourPoints: 0 })
            discard await profilesDB.insert(profileDoc)
            let botDoc = bson.`%*`({"_id": botID, "index": botsCount, "profileID": profileID, "gender": templ.gender, "country": templ.country })
            discard await botsDB.insert(botDoc)
            #echo "Generated bot ", botsCount, " named '", templ.name, "'"
            botsCount += 1


proc onGenerateBots*(args: Bson): Future[float] {.async.} =
    await botCreateProfiles(2000)
    return 0


proc getRandomBot(): Future[Bot] {.async.} =
    let botsDB = sharedDB()["bots"]
    let botsCount = await botsDB.find(bson.`%*`({})).count()
    let i = random(botsCount)
    logTournamentsDetails "Randomized bot index = ", i
    let botDoc = await botsDB.find(bson.`%*`({"index": i})).one()
    result.new
    result.init(botsDB, botDoc)


proc tournamentBotsJoin*(t: Tournament): Future[void] {.async.} =
    logTournamentsDetails "[", getTime().toSeconds.int, "]  Bots joining tournament '", t.title, "'"

    while true:
        let bot = await getRandomBot()
        if not await profileParticipates(t.id, bot.profileID):
            let profileDoc = await profilesDB().find(bson.`%*`({"_id": bot.profileID})).one()
            let p = newProfile(profilesDB(), profileDoc)
            discard await p.joinTournament(t)
            break


proc tryBotsJoinTournament*(jData: JsonNode): Future[JsonNode] {.async.} =
    let tournamentId = jData["tournamentId"].getStr().parseOid()
    let t = await findTournament(tournamentId)

    if t.isNil:
        echo "Warning: bots join tournament ", tournamentId, " not found."
        return
    if not t.isRunning():
        echo "Warning: bots join tournament ", tournamentId, " is not running."
        return

    await tournamentBotsJoin(t)
    let resp = await t.getDetails(jData{"sinceTime"}.getFNum())
    result = json.`%*`({"status": "Ok", "response": resp})


proc onTournamentBotsJoin(args: Bson): Future[float] {.async.} =
    let t = await findTournament(args["tournamentID"])
    if t.isNil:
        echo "Warning: bots join tournament ", args["tournamentID"], " not found."
        return 0
    if not t.isRunning():
        echo "Warning: bots join tournament ", args["tournamentID"], " is not running."
        return 0

    await tournamentBotsJoin(t)

    let cfg = sharedGameConfig().tournaments
    var levCfg = cfg.levels[t.level]

    if t.timePassed() < levCfg.botsJoinFastDuration:
        result = levCfg.botsJoinFastDelayMin + random(levCfg.botsJoinFastDelayMax - levCfg.botsJoinFastDelayMin)
    else:
        result = levCfg.botsJoinRegularDelayMin + random(levCfg.botsJoinRegularDelayMax - levCfg.botsJoinRegularDelayMin)

    if t.timeLeft()  <  result + 10:
        result = 0


proc botLeaveTournaments*(): Future[void] {.async.} =
    let tournaments = await findAllTournaments()
    var activeCount = 0
    for key, tournament in tournaments:
        if tournament.isClosed:
            let participants = await findTournamentParticipants(tournament.id)
            if participants.len > 0:
                echo "Leaving ", tournament.id
            for p in participants:
                if not p.isBot:
                    await leaveTournament(p)


proc getBotRandomScoreGain(slot: SlotTournamentConfig): int =
    var roll = random(1.0)
    for i in 0 ..< slot.botProbs.len:
        if roll <= slot.botProbs[i]:
            return slot.botScores[i]
        else:
            roll -= slot.botProbs[i]


# for k, slot in slots:
#     var gainT: ref Table[int, int] = newTable[int, int]()

#     for i in 0 ..< slot.botScores.len:
#         gainT[slot.botScores[i]] = 0

#     let rollsCount = 1000 * 1000
#     for i in 0..rollsCount:
#         gainT[getBotRandomScoreGain(slot)] += 1

#     for i in 0 ..< slot.botProbs.len:
#         let realProb = gainT[slot.botScores[i]] / rollsCount
#         if abs(realProb - slot.botProbs[i]) > 0.01:
#             echo "Slot '", k, "' score ", slot.botScores[i], "  orig prob = ", slot.botProbs[i], "  real = ", realProb


proc onTournamentBotSpin(args: Bson): Future[float] {.async.} =
    let t = await findTournament(args["tournamentID"])
    if t.isNil:
        echo "Warning: bots spin tournament ", args["tournamentID"], " not found."
        return 0
    if not t.isRunning():
        echo "Warning: bots spin tournament ", args["tournamentID"], " is not running."
        return 0

    logTournamentsDetails "Bots spinning tournament '", t.title, "',  time left = ", t.endDate.toSeconds - getTime().toSeconds

    let cfg = sharedGameConfig().tournaments
    let slotCfg = cfg.slots[t.slotKey]
    let botParticipants = await findTournamentBotParticipants(t.id)
    for k, p in botParticipants:
        if not p.botIdle:
            await t.gainParticipationScore(p, slotCfg.getBotRandomScoreGain())

            if random(1.0) <= cfg.botStopSpinProb:
                logTournamentsDetails "Bot '", p.profileName, "' (", p.profileID, ") stopped participation in '", t.title, "'"
                p.botIdle = true
                await p.commit()

    result = slotCfg.botSpinDelay

    if t.timeLeft() < result + 1:
        result = 0


registerScheduleTask("generate bots 2", onGenerateBots, regular = true)
registerScheduleTask("tournament bots join", onTournamentBotsJoin)
registerScheduleTask("tournament bots spin", onTournamentBotSpin)
