import httpcore, json, asyncdispatch, times, macros
import falconserver / features / features
import falconserver / common / [config, response]
import falconserver / auth / profile
export features


proc wrapRespJson*(profile: Profile, content: JsonNode, clientVersion: string) {.async.} =
    if clientVersion != NO_MAINTENANCE_CLIENT_VERSION:
        content["maintenanceTime"] = %sharedGameConfig().maintenanceTime

    if not profile.isNil:
        await content.updateWithWheelFreeSpin(profile)
        await content.updateWithDiscountedExchange(profile)
