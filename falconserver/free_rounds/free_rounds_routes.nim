import strutils, json

import falconserver / [ nester ]
import falconserver / map / building / [ builditem ]
import falconserver / auth / [ profile, profile_random, profile_types, session, profile_helpers ]
import falconserver / common / [ response, response_wrapper ]


import free_rounds


let router = sharedRouter()


router.routes:
    sessionPost "/free-rounds/{gameSlotID}/get-reward":
        let gameSlotID = @"gameSlotID"

        let bid = parseEnum[BuildingId](gameSlotID, noBuilding)
        if bid.buidingKind() != slot:
            respJson Http200, json.`%*`({"status": StatusCode.Ok.int, "result": false, "reason": "Unknown slot " & gameSlotID})
            return
        
        let freeRounds = await findFreeRounds(profile.id)
        let (err, reward) = await freeRounds.getFreeRoundReward(gameSlotID)
        if not err.isNil:
            err["status"] = %StatusCode.Ok.int
            err["result"] = %false
            respJson Http200, err
            return
        
        let resp = json.`%*`({"status": StatusCode.Ok.int, "result": true})
        resp.updateWithFreeRounds(freeRounds)
        await wrapRespJson(clRequest.session.profile, resp, clRequest.clientVersion)

        respJson Http200, resp