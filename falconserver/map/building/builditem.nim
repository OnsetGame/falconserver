import tables
import times

import falconserver.common.currency
import falconserver.common.game_balance

when not defined(js):
    import oids
    export oids

type
    BuildingKind* = enum
        slot, res, unic, bonus, decor, nokind

    BuildingId* = enum
        noBuilding = -1,
        cityHall = 0,
        dreamTowerSlot,
        balloonSlot,
        restaurant,
        ufoSlot,
        facebook,
        candySlot,
        ratings,
        witchSlot,
        gasStation,
        mermaidSlot,
        groovySlot,
        testSlot,
        bank,
        anySlot,
        store,
        candySlot2,
        cardSlot

    BuildItem* = ref object
        id*: BuildingId
        level*: int
        name*: string
        lastCollectionTime*: float

proc buidingKind*(id: BuildingId): BuildingKind =
    case id
    of dreamTowerSlot, balloonSlot, ufoSlot, candySlot, witchSlot, mermaidSlot, testSlot, groovySlot, cardSlot, anySlot, candySlot2:
        slot
    of restaurant, gasStation:
        res
    of cityHall, facebook, ratings, bank, store:
        unic
    of noBuilding:
        nokind
    else:
        nokind

proc newBuildItem*(id: BuildingId): BuildItem =
    result.new()
    result.id = id
    # result.kind = buidingKind(id)

proc configForBuildingId(conf:seq[BuildingConfig], bi: BuildingId): BuildingConfig=
    for c in conf:
        if c.buildingIdStr == $bi or (c.buildingIdStr == $anySlot and bi.buidingKind == slot):
            return c

proc configForBuildingName(conf: seq[BuildingConfig], name: string): BuildingConfig=
    for c in conf:
        if name == c.buildingIdStr:
            return c

proc configForBuilding(bi: BuildItem, gb: GameBalance): BuildingConfig=
    result = gb.buildingsConfig.configForBuildingName(bi.name)
    if result.isNil:
        result = gb.buildingsConfig.configForBuildingId(bi.id)

proc resourcePerHour*(bi: BuildItem, forLevel: int = 0, gb: GameBalance): int =
    let bc = bi.configForBuilding(gb)
    if not bc.isNil:
        if bc.levels.len > forLevel:
            result = bc.levels[forLevel].income
        else:
            result = bc.levels[bc.levels.len - 1].income

proc resourceCurrency*(bi: BuildItem, gb: GameBalance): Currency=
    let bc = bi.configForBuilding(gb)
    if bc.isNil:
        result = Currency.Unknown
    else:
        result = bc.currency

proc resourceCapacity*(bi: BuildItem, gb: GameBalance): int =
    let bc = bi.configForBuilding(gb)
    if not bc.isNil:
        if bc.levels.len > bi.level:
            result = bc.levels[bi.level].capacity
        else:
            result = bc.levels[bc.levels.len - 1].capacity

proc availableSlotsForIntro*(): seq[BuildingId] =
    return @[
        dreamTowerSlot,
        candySlot,
        balloonSlot
    ]
