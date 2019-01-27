import json, strutils, strutils, tables
import falconserver.auth.profile_types
import falconserver.quest.quest_types
import falconserver / common / [ currency, checks, config ]


type NearMissPattern* = ref object
    data*: seq[int8]
    name*: string
    weight*: int
    scatterCount*: int
    wildCount*: int
    bonusCount*: int

type NearMissSubstitution* = ref object
    srcSet*: seq[int8]
    dstSet*: seq[int8]

type SlotNearMissConfig* = ref object
    probability*: float
    substitutions*: seq[NearMissSubstitution]
    patterns*: seq[NearMissPattern]

type NearMissConfig* = ref object
    slots*: TableRef[string, SlotNearMissConfig]


import falconserver.slot.machine_base

proc parseSlotNearMissConfig(slotKey: string, j: JsonNode): SlotNearMissConfig =
    # echo slotKey
    # echo j
    let sm = getSlotMachineByGameID(slotKey)

    result.new()
    result.probability = j["probability"].to(float)
    result.substitutions = j["substitutions"].to(seq[NearMissSubstitution])
    result.patterns = @[]

    for v in j["patterns"]:
        let pattern = NearMissPattern.new()
        pattern.data = v["data"].to(seq[int8])
        pattern.name = v["name"].to(string)
        pattern.weight = v["weight"].to(int)
        pattern.scatterCount = sm.countSymbolsOfType(pattern.data, IScatter)
        pattern.wildCount = sm.countSymbolsOfType(pattern.data, IWild)
        pattern.bonusCount = sm.countSymbolsOfType(pattern.data, IBonus)
        logNearMisses pattern.data, " -> ", pattern.scatterCount, " scatters, ", pattern.wildCount, " wilds, ", pattern.bonusCount, " bonuses"
        result.patterns.add(pattern)


proc parseNearMisses*(j: JsonNode): NearMissConfig =
    result.new()
    result.slots = newTable[string, SlotNearMissConfig]()
    for k, v in j:
        result.slots[k] = parseSlotNearMissConfig(k, v)


const nearMissData* = staticRead("../resources/balance/near_miss_patterns.json")
var gNearMissData: NearMissConfig

proc sharedNearMissData*(): NearMissConfig =
    if gNearMissData.isNil:
        gNearMissData = parseNearMisses(parseJson(nearMissData))
    gNearMissData



# testNearMiss()
# discard sharedNearMissData()
