import json, asyncdispatch, times, strutils, tables, typetraits
import nimongo.bson, nimongo.mongo, bson_helper
import falconserver.common.db


const defaultConfigJson = staticRead("../resources/balance/config.json")

proc defaultConfigData(): Bson =
    result = parseJson(defaultConfigJson).toBson()


proc overwriteValues(toB, fromB: Bson) =
    if not fromB.isNil:
        for k, v in toB:
            if v.kind == BsonKindDocument:
                overwriteValues(v, fromB{k})
            elif k in fromB:
                toB[k] = fromB[k]


proc parseField[T](b: Bson, key: string): T =
    if b.isNil or key notin b:
        raise newException(ValueError, "No value for key '" & key & "'")
    try:
        when T is float64: result = b[key].toFloat64()
        elif T is int:     result = b[key].toInt()
        elif T is int64:   result = b[key].toInt64()
        elif T is bool:    result = b[key].toBool()
        #elif T is Oid:     result = b[key].toOid()
        elif T is Time:    result = b[key].toTime()
        elif T is string:  result = b[key].toString()
        else:
            static:
                echo "No implementation for reading type '", T.name, "'' from Bson"
                {.error: "No implementation for reading type T from Bson".}
    except:
        raise newException(ValueError, "Can't parse value '" & b[key].toString() & "' as " & T.name)


proc inRange[T](value: T, rangeFrom: T, rangeTo: T): T =
    if value < rangeFrom  or  value > rangeTo:
        raise newException(ValueError, "Value '" & $value & "' not in range [" & $rangeFrom & " - " & $rangeTo & "]")
    result = value


proc parseOptionalField[T](b: Bson, key: string, defaultValue: T): T =
    if b.isNil or key notin b:
        result = defaultValue
    else:
        result = parseField[T](b, key)


type LogsConfig* = ref object
    requests*: int
    schedule*: int
    scheduleDelayWarningT*: float
    notifications*: int
    tournaments*: int
    nearMisses*: int
    deltaDNA*: int


proc parseLogs(b: Bson): LogsConfig =
    result.new()

    result.requests = parseField[int](b, "requests")
    result.schedule = parseField[int](b, "schedule")
    result.scheduleDelayWarningT = parseField[int](b, "scheduleDelayWarningT").float
    result.notifications = parseField[int](b, "notifications")
    result.tournaments = parseField[int](b, "tournaments")
    result.nearMisses = parseField[int](b, "nearMisses")
    result.deltaDNA = parseField[int](b, "deltaDNA")


type NotificationsConfig* = ref object
    sleepHour*: int
    wakeHour*: int
    minSendingInterval*: int
    limitPerDay*: int
    logoutInactivityTime*: int
    resetLimitsOnLogin*: int
    priorities*: seq[int]


proc parseNotifications(b: Bson): NotificationsConfig =
    result.new()

    result.sleepHour = parseField[int](b, "sleepHour").inRange(1, 24)
    result.wakeHour = parseField[int](b, "wakeHour").inRange(1, result.sleepHour)
    result.minSendingInterval = parseField[int](b, "minSendingInterval").inRange(1, 365*24*60*60)
    result.limitPerDay = parseField[int](b, "limitPerDay").inRange(1, 100)
    result.logoutInactivityTime = parseField[int](b, "logoutInactivityTime").inRange(10, 60*60)
    result.resetLimitsOnLogin = parseField[int](b, "resetLimitsOnLogin").inRange(0, 1)
    result.priorities = toSeqInt[int](b["priorities"])


type SlotTournamentCaseConfig* = ref object of RootObj
    slotKey*: string
    name*: string
    entryFee*: int
    bet*: int
    duration*: int
    level*: int


type SlotTournamentConfig* = ref object of RootObj
    tutorialTournamentName*: string
    tournamentNames*: seq[string]
    botSpinDelay*: float
    botScores*: seq[int]
    botProbs*: seq[float]
    #cases*: seq[SlotTournamentCaseConfig]


type TournamentLevelConfig* = ref object
    chipsRewardPerHour*: int64
    chipsRewardPer10KBet*: int64
    bucksRewardPerHour*: int64
    bucksRewardPer10KBet*: int64
    probability*: float
    cases*: seq[SlotTournamentCaseConfig]
    botsJoinFastDuration*: float
    botsJoinFastDelayMin*: float
    botsJoinFastDelayMax*: float
    botsJoinRegularDelayMin*: float
    botsJoinRegularDelayMax*: float


type TournamentsConfig* = ref object
    generationInterval*: int
    startDelay*: int

    levels*: TableRef[int, TournamentLevelConfig]
    slots*: TableRef[string, SlotTournamentConfig]

    tutorialDuration*: int
    tutorialBet*: int
    tutorialEntryFee*: int

    botStopSpinProb*: float


proc parseTournamentSlotCase(slotKey: string, b: Bson): SlotTournamentCaseConfig =
    result.new

    result.slotKey = slotKey
    result.name = parseField[string](b, "name")
    result.entryFee = parseField[int](b, "entryFee").inRange(0, 999_999_999)
    result.bet = parseField[int](b, "bet").inRange(1000, 999_999_999)
    result.duration = parseField[int](b, "duration").inRange(60, 2*60*60)
    result.level = parseField[int](b, "level").inRange(0, 2)


proc parseTournamentSlot(config: TournamentsConfig, key: string, b: Bson): SlotTournamentConfig =
    result.new()

    result.tutorialTournamentName = parseField[string](b, "tutorialName")
    for v in b["cases"]:
        let tournamentCase = parseTournamentSlotCase(key, v)
        config.levels[tournamentCase.level].cases.add(tournamentCase)
    var botsB = b["bots"]
    result.botSpinDelay = parseField[float](botsB, "spinInterval")
    if botsB["scores"].len != botsB["probs"].len:
        raise newException(ValueError, "bot probs and scores arrays have different lengths")
    result.botScores = toSeqInt[int](botsB["scores"])
    result.botProbs = toSeqFloat[float](botsB["probs"])


proc parseLevel(b: Bson): TournamentLevelConfig =
    result.new()

    result.chipsRewardPerHour = parseField[int64](b, "chipsRewardPerHour")
    result.chipsRewardPer10KBet = parseField[int64](b, "chipsRewardPer10KBet")
    result.bucksRewardPerHour = parseField[int64](b, "bucksRewardPerHour")
    result.bucksRewardPer10KBet = parseField[int64](b, "bucksRewardPer10KBet")
    result.probability = parseField[float](b, "probability")

    result.cases = @[]

    let botsJoin = b["botsJoin"]
    result.botsJoinFastDuration = parseField[int](botsJoin, "fastDuration").float.inRange(0, 60*60)
    result.botsJoinFastDelayMin = parseField[int](botsJoin, "fastDelayMin").float.inRange(1, 1000)
    result.botsJoinFastDelayMax = parseField[int](botsJoin, "fastDelayMax").float.inRange(result.botsJoinFastDelayMin, 1000)
    result.botsJoinRegularDelayMin = parseField[int](botsJoin, "regularDelayMin").float.inRange(1, 1000)
    result.botsJoinRegularDelayMax = parseField[int](botsJoin, "regularDelayMax").float.inRange(1, 1000)


proc parseTournaments(b: Bson): TournamentsConfig =
    result.new()

    result.generationInterval = parseField[int](b, "generationInterval").inRange(5*60, 5*60*60)
    result.startDelay = parseField[int](b, "startDelay").inRange(0, 5*60*60)

    result.tutorialDuration = parseField[int](b, "tutorialDuration").inRange(60, 10*60*60)
    result.tutorialBet = parseField[int](b, "tutorialBet").inRange(1000, 999_999_999)
    result.tutorialEntryFee = parseField[int](b, "tutorialEntryFee").inRange(0, 999_999_999)

    result.botStopSpinProb = parseField[float](b, "botStopSpinProb").inRange(0.0, 0.1)

    result.levels = newTable[int, TournamentLevelConfig]()
    for k, v in b["levels"]:
        result.levels[k.parseInt()] = parseLevel(v)

    result.slots = newTable[string, SlotTournamentConfig]()
    for k, v in b["slots"]:
        result.slots[k] = parseTournamentSlot(result, k, v)


type GameConfig* = ref object
    version*: int
    data*: Bson
    dbID*: Bson
    minClientVersion*: int
    maintenanceTime*: float
    logs*: LogsConfig
    notifications*: NotificationsConfig
    tournaments*: TournamentsConfig

# let TIME = epochTime() + 40.0

proc parseConfig*(b: Bson): GameConfig =
    result.new()
    result.data = b
    result.dbID = b{"_id"}
    result.version = parseField[int](b, "version")
    if not b{"logs"}.isNil:
        result.logs = parseLogs(b["logs"])
    result.notifications = parseNotifications(b{"notifications"})
    result.tournaments = parseTournaments(b{"tournaments"})
    result.minClientVersion = parseOptionalField[int](b, "minClientVersion", 0)
    result.maintenanceTime = parseOptionalField[float](b, "maintenanceTime", 0)

var config {.threadvar.}: GameConfig

proc sharedGameConfig*(): GameConfig {.gcsafe.} =
    result = config


proc tryReplaceGameConfig*(b: Bson): string =
    echo "Parsing config candidate - ", b.toJson()
    try:
        config = parseConfig(b)
        result = nil
    except ValueError:
        result = getCurrentExceptionMsg()


var prevSavedBStr = ""

proc runConfigUpdate*() {.async.} =
    while true:
        var savedB = await sharedDB()["config"].find(bson.`%*`({"version": config.version})).oneOrNone()
        if savedB.isNil:
            #echo "No config in DB"
            savedB = bson.`%*`({})
        let savedBStr = $savedB
        if prevSavedBStr != savedBStr:
            echo "Updated config from DB"
            var configB = defaultConfigData()
            overwriteValues(configB, savedB)
            try:
                config = parseConfig(configB)
                prevSavedBStr = savedBStr
            except ValueError:
                echo "Saved config parsing exception - ", getCurrentExceptionMsg()
        await sleepAsync(10_000)


proc shouldLogRequests*(logLevel: int): bool =
    sharedGameConfig().logs.requests >= logLevel

template logRequests*(logLevel: int, args: varargs[untyped]) =
    if sharedGameConfig().logs.requests >= logLevel:
        echo args

template logTournaments*(args: varargs[untyped]) =
    if sharedGameConfig().logs.tournaments >= 1:
        echo "[tournaments]:  ", args

template logTournamentsDetails*(args: varargs[untyped]) =
    if sharedGameConfig().logs.tournaments >= 2:
        echo "[tournaments]:  ", args

proc shouldLogSchedule*(): bool =
    sharedGameConfig().logs.schedule >= 1

template logSchedule*(args: varargs[untyped]) =
    if shouldLogSchedule():
        echo "[schedule]:  ", args

proc shouldLogNotifications*(): bool =
    sharedGameConfig().logs.notifications >= 1

template logNotifications*(args: varargs[untyped]) =
    if shouldLogNotifications():
        echo "[notifications]:  ", args

template logNearMisses*(args: varargs[untyped]) =
    if sharedGameConfig().logs.nearMisses >= 1:
        echo "[near misses]:  ", args

proc configForPull*(): JsonNode =
    result = sharedGameConfig().data.toJson()
    result.delete "logs"  # should not be editable from console
    result.delete "version"  # is implicit too

proc configForPush*(jData: JsonNode): Bson =
    result = jData.toBson()
    result["version"] = sharedGameConfig().version.toBson()
    result["logs"] = sharedGameConfig().data["logs"]


proc configScheme*(): JsonNode =
    result = json.`%*`({
        "fields": {
            "minClientVersion": { "descr": "Minimal client version" }
        }
        })


try:
    config = parseConfig(defaultConfigData())
    echo "Default config parsed ok"
except ValueError:
    echo "Default config parsing exception - ", getCurrentExceptionMsg()
    quit(1)
