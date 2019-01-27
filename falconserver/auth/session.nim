import json, oids, times, sets, logging, asyncdispatch, asynchttpserver, strutils

import nimongo / [ mongo, bson ]

import falconserver / common / [ response, db, get_balance_config, config ]

import profile, profile_types

type
    Session* = ref object of RootObj
        profile*: Profile    ## User's profile cache


type ClientRequest* = ref object
    session*: Session
    body*: JsonNode
    status*: StatusCode
    reason*: string
    clientVersion*: string


proc findProfile*(key: string, value: Bson): Future[Profile] {.async.} =
    # Should not be used directly
    let profileBson = await profilesDB().find(B(key, value)).oneOrNone()
    if not profileBson.isNil:
        result = newProfile(profilesDB(), profileBson)

proc findProfileBySessionId(id: Oid): Future[Profile] {.inline.} =
    # Support for old protocol. Should be removed eventually.
    findProfile("session", id.toBson())

proc findProfileById*(id: Oid): Future[Profile] {.inline.} =
    findProfile("_id", id.toBson())




proc getSession*(r: Request): Future[Session] {.async.} =
    ## Returns profile for sessionId in request, or raises if not found
    let sessId = string(r.headers.getOrDefault("Falcon-Session-Id"))
    if sessId.len == 0:
        raise newException(KeyError, "No session id in request")

    let profileId = string(r.headers.getOrDefault("Falcon-Prof-Id"))
    var p: Profile
    if profileId.len > 0:
        p = await findProfileById(parseOid(profileId))
        if not p.isNil:
            if p["session"].toOid != parseOid(sessId):
                info "wrong sessId ", sessId, " for profile ", profileId
                p = nil
    else:
        p = await findProfileBySessionId(parseOid(sessId))

    if p.isNil:
        info "Profile for session id not found ", sessId
        return

    result.new()

    await p.loadGameBalance()

    result.profile = p
    result.profile.prevRequestTime = result.profile.statistics.lastRequestTime
    result.profile.statistics.lastRequestTime = epochTime()

template clientVersion*(request: Request): string =
    request.headers.getOrDefault("Falcon-Client-Version", @["0"].HttpHeaderValues).toString()

const OLD_CLIENT_VERSION = (status: StatusCode.IncorrectMinClientVersion, reason: "Unsupported client version")
proc isClientVersionAllowable*(clientVersion: string, req: Request): bool =
    try:
        if clientVersion == NO_MAINTENANCE_CLIENT_VERSION:
            result = true
        if clientVersion.isDigit() and parseInt(clientVersion) >= sharedGameConfig().minClientVersion:
            result = true
    except:
        discard
proc oldClientVersion*(res: ClientRequest) =
    res.status = OLD_CLIENT_VERSION.status
    res.reason = OLD_CLIENT_VERSION.reason
proc oldClientVersion*(res: JsonNode) =
    res["status"] = %OLD_CLIENT_VERSION.status.int
    res["reason"] = %OLD_CLIENT_VERSION.reason
proc oldClientVersion*(): JsonNode =
    result = newJObject()
    result.oldClientVersion()


const MAINTENANCE_IN_PROGRESS = (status: StatusCode.MaintenanceInProgress, reason: "Maintenance in progress")
proc isMaintenanceInProgress*(clientVersion: string, req: Request): bool =
    if clientVersion == NO_MAINTENANCE_CLIENT_VERSION:
        result = false
    elif sharedGameConfig().maintenanceTime != 0.0 and epochTime() >= sharedGameConfig().maintenanceTime:
        result = true
proc maintenanceInProgress*(res: ClientRequest) =
    res.status = MAINTENANCE_IN_PROGRESS.status
    res.reason = MAINTENANCE_IN_PROGRESS.reason
    res.body = %{"maintenanceTime": %sharedGameConfig().maintenanceTime}
proc maintenanceInProgress*(res: JsonNode) =
    res["status"] = %MAINTENANCE_IN_PROGRESS.status.int
    res["reason"] = %MAINTENANCE_IN_PROGRESS.reason
    res["maintenanceTime"] = %sharedGameConfig().maintenanceTime
proc maintenanceInProgress*(): JsonNode =
    result = newJObject()
    result.maintenanceInProgress()

proc checkRequest*(request: Request): Future[ClientRequest] {.async.}=
    result = ClientRequest.new()
    result.clientVersion = request.clientVersion()

    if isMaintenanceInProgress(result.clientVersion, request):
        result.maintenanceInProgress()
        return

    if not isClientVersionAllowable(result.clientVersion, request):
        result.oldClientVersion()
        return

    try:
        let ses = await getSession(request)
        if ses.isNil:
            result.status = StatusCode.IncorrectSession
            result.reason = "Session does't exist"
            return result

        else:
            result.status = StatusCode.OK
            result.session = ses

    except:
        let excMsg = getCurrentExceptionMsg()
        result.status = StatusCode.IncorrectSession
        result.reason = excMsg

    try:
        let jobj = try: parseJson(request.body)
                   except: nil
        if jobj == nil:
            result.status = StatusCode.InvalidRequest
            result.reason = "Request body is nil"
            return result

        else:
            result.status = StatusCode.OK
            result.body = jobj

    except:
        echo "checkRequest exception ", getCurrentExceptionMsg()
        result.status =  StatusCode.InvalidRequest
        result.reason = getCurrentExceptionMsg()
