import json
import nimongo.bson
import asyncdispatch

import falconserver.auth.profile_types
import falconserver.auth.profile
import falconserver.auth.profile_helpers
import falconserver.common.response
import falconserver.common.bson_helper
import shafa / game / [ message_types, reward_types ]
export message_types

template toBson*(m: Message): Bson = m.toJson().toBson()
template loadMessage*(bs: Bson): Message = bs.toJson().loadMessage()

proc addMessage*(p: Profile, msg: Message) =
    p[$prfMessages].add(msg.toBson())
    p[$prfMessages] = p[$prfMessages]  # to make object aware of changes

proc processMessage*(command: string, request: JsonNode, profile: Profile): Future[JsonNode] {.async.} =
    result = newJObject()
    var messagesNode = newJArray()
    result.add("messages", messagesNode)

    case command:
    of "check":
        for msgb in profile[$prfMessages]:
            let msg = msgb.loadMessage()
            messagesNode.add(msg.toJson())

    of "remove":
        var msgs = newBsonArray()
        for msgb in profile[$prfMessages]:
            let msg = msgb.loadMessage()
            if request{$mfKind}.getStr() == msg.kind:
                msg.showed = true
                await profile.acceptRewards(msg.rewards, result)
            else:
                msgs.add(msg.toBson())
        profile[$prfMessages] = msgs

    else:
        echo "processMessage unkown command"

    result{"status"} = %StatusCode.Ok.int
