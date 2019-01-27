import times, json, asyncdispatch
import falconserver / auth / [profile_random, session]
import falconserver / common / [game_balance, get_balance_config, bson_helper]


proc updateWithWheelFreeSpin*(resp: JsonNode, p: Profile) {.async.} =
    resp["prevFreeSpin"] = %p.fortuneWheelState.lastFreeTime
    resp["freeSpinTimeout"] = %p.getGameBalance().fortuneWheel.freeSpinTimeout
    resp["freeSpinsLeft"] = %p.fortuneWheelState.freeSpinsLeft


proc updateWithDiscountedExchange*(resp: JsonNode, p: Profile) {.async.} =
    resp["nextDiscountedExchange"] = %p.nextExchangeDiscountTime
    resp["exchangeChips"] = p{$prfExchangeNum, $prfChips}.toJson()
