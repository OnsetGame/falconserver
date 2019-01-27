import json

const NO_MAINTENANCE_CLIENT_VERSION* = "no-maintenance"

const ERR_OK*                    = 0
const ERR_MISSING_FIELDS*        = 100
const ERR_UNKNOWN*               = 500

type StatusCode* {.pure.} = enum
    Failed = -1
    Ok
    InvalidRequest     ## client send wrong data for example: get reward of not completed quest
    NotEnougthChips
    NotEnougthBucks
    NotEnougthParts
    WrongMapRevision
    IncorrectSession
    LogginFailure
    QuestNotFound
    InvalidQuestState
    NotEnougthTourPoints
    IncorrectMinClientVersion
    MaintenanceInProgress
    NewMaintenanceInProgress
    
proc errorResponse*(code : int, msg : string) : JsonNode =
    var o = newJObject()
    o["status"] = %code
    result = o

proc checkJsonFields*(fields : openarray[string], node : JsonNode, err : var string) : bool =
    var er = "fields missing: "
    result = true
    for s in fields:
        if node[s].isNil:
            result = false
            er = er & s & ", "
    err = er

template fieldsCheck*(params : JsonNode, fields : openarray[string], jobj : untyped, bod: untyped): untyped =
    var jobj = params
    var err : string
    if checkJsonFields(fields, jobj, err):
        bod
    else:
        result = errorResponse(ERR_MISSING_FIELDS, err)

template responseOK*(jn : JsonNode, bod: untyped): untyped =
    let st = jn{"status"}
    if not st.isNil and st.kind == JInt and st.num == StatusCode.Ok.int:
        bod
