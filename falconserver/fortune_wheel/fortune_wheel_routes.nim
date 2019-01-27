import json, strutils, asyncdispatch, httpcore, strtabs, oids, times, logging

import falconserver.nester
import falconserver / common / response_wrapper

import nimongo.bson

import falconserver.auth.profile
import falconserver.common.game_balance
import falconserver.common.get_balance_config
import fortune_wheel

sharedRouter().routes:
    sessionPost "/fortune/state":
        let list = newJArray()
        let gb = profile.getGameBalance()
        for i in gb.fortuneWheel.gains:
            list.add(json.`%*`({"item": i.item, "count": i.count}))

        let fw = profile.fortuneWheelState
        let resp = json.`%*`({"prevFreeSpin": fw.lastFreeTime, "nextCost": profile.fortuneWheelSpinCost(fw), "list": list, "freeSpinTimeout": profile.getGameBalance().fortuneWheel.freeSpinTimeout, "freeSpinsLeft": fw.freeSpinsLeft})
        if not fw.history.isNil:
            let history = newJArray()
            for i in fw.history:
                history.add(json.`%*`({"item": i["item"].toString(), "count": i["count"].toInt()}))
            resp["history"] = history

        await wrapRespJson(clRequest.session.profile, resp, clRequest.clientVersion)
        respJson Http200, resp

    sessionPost "/fortune/spin":
        let cost = profile.fortuneWheelSpinCost(profile.fortuneWheelState)
        if profile.bucks < cost:
            respJson Http200, json.`%*`({"status": "Not enough bucks"})
        else:
            let index = await profile.spinFortuneWheel()
            let resp = json.`%*`({"prevFreeSpin": profile.fortuneWheelState.lastFreeTime,
                                  "freeSpinTimeout": profile.getGameBalance().fortuneWheel.freeSpinTimeout,
                                  "nextCost": profile.fortuneWheelSpinCost(profile.fortuneWheelState),
                                  "choice": index,
                                  "wallet": profile.getWallet(),
                                  "freeSpinsLeft": profile.fortuneWheelState.freeSpinsLeft})
            await wrapRespJson(clRequest.session.profile, resp, clRequest.clientVersion)
            respJson Http200, resp
