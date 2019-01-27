import currency
import tables
import game_balance

import falconserver / auth / [profile_random, profile_vip_helpers]
import falconserver.common.get_balance_config

proc exchangeCritical*(p: Profile): int =
    ## Generates exchange critical - number of bonus multiplier
    ## which is given to user after exchange operation.
    let gbMults = p.getGameBalance().exchangeMultiplayers

    var mults = newSeq[int]()
    var chances = newSeq[float]()

    var tChance = 0.0
    for k, v in gbMults:
        mults.add k
        chances.add tChance
        tChance += v

    let r = p.random(tChance)
    for i, chance in chances:
        if r >= chance and i < chances.len - 1 and r <= chances[i + 1]:
            result = mults[i]
            break
        elif i == chances.len - 1:
            result = mults[i]

proc exchange*(p: Profile, exchangeNumber: int, cTo: Currency): tuple[bucksSpent: int64, changedTo: int64, critical: int] =
    ## Return amount of money according to rates, and critical value which is randomly generated
    ## multiplier for the performed exchange operation.
    if cTo == Currency.Chips:
        let (bucks, change) = exchangeRates(p.getGameBalance(), exchangeNumber, cTo)
        p.bucks = p.bucks - bucks

        let crit = exchangeCritical(p)
        p.chips  = p.chips + p.exchangeGain(change * crit)
        return (bucksSpent: bucks, changedTo: change, critical: crit)
