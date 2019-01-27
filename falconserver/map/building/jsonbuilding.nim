import builditem
import json
#import oids

proc toJson*(bi: BuildItem): JsonNode =
    result = newJObject()
    result["i"] = % bi.id.int
    result["l"] = %bi.level
    result["n"] = %bi.name
    # if bi.kind == res:
    result["t"] = %bi.lastCollectionTime

proc toBuildItem*(b : JsonNode): BuildItem =
    let id = BuildingId(b["i"].num)
    result = newBuildItem(id)
    result.level = int(b["l"].num)

    if "n" in b:
        result.name = b["n"].getStr()

    if "t" in b:
        result.lastCollectionTime = b["t"].getFloat()
