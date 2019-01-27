import json
import nimongo.bson
import nimongo.mongo
import falconserver.common.orm

TransparentObj ProfileStats:
    realMoneySpent: int64("ms", "realMoneySpent")
    spinsOnSlots: Bson("sp", "spinsOnSlots")
    
    scenesLoaded: Bson("sl", "scenesLoaded")

    questsCompleted: Bson("qc", "questsCompleted")

    lastRequestTime: float("rt", "lastRequestTime")
    registrationTime: float("prt", "registrationTime")
