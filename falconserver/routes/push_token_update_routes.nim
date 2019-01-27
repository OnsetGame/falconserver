import json, asyncdispatch, httpcore, oids

import falconserver.nester
import falconserver / auth / [ session, profile ]

sharedRouter().routes:
    post "/updatePushTok":
        var body = parseJson(request.body)
        let profileId = body{"pid"}.getStr()
        let password = body{"pw"}.getStr()
        let newPushToken = body{"tok"}.getStr()
        let platform = body{"platform"}.getStr()
        var ok = false
        if profileId.len != 0 and password.len != 0 and newPushToken.len != 0 and
                platform.len != 0:

            let p = await findProfileById(parseOid(profileId))
            if not p.isNil and p.password == password:
                case platform
                of "android":
                    ok = true
                    p.androidPushToken = newPushToken
                of "ios":
                    ok = true
                    p.iosPushToken = newPushToken
                else:
                    discard

                if ok:
                    await p.commit()

        if ok:
            resp Http200, "OK"
        else:
            resp Http400, "Bad request"
