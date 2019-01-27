import falconserver.nester
import falconserver / common / [ response_wrapper, config, response ]
import falconserver / auth / [ profile, session ]
import json, logging, tables

sharedRouter().routes:
    sessionPost "/decisionPoint":
        respJson Http200, json.`%*`({"status":StatusCode.OK.int, "reason": "decisionPoint is empty"})
        return
