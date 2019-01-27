import json, logging, oids, sequtils, strutils, tables, times, asyncdispatch
import os except DeviceId

import nimongo / [ bson, mongo ]

import falconserver / [ schedule, nester ]
import falconserver / auth / [ profile_types, profile ]
import falconserver / common / [ db, bson_helper, stats, config, staging ]

import notifications
export notifications


# Debugging:
if isStage:
    sharedRouter().routes:
        get "/sendDebugPush":
            ## Test purpose only
            resp Http400, "Bad request"
