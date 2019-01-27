import tables, sequtils

import falconserver.slot.machine_base
import falconserver.auth.profile_random
import falconserver.common.config

import near_misses
export near_misses


proc generateByPattern(slotConfig: SlotNearMissConfig, p: Profile, data: seq[int8]): seq[int8] =
    var subst = newTable[int8, int8]()
    for s in slotConfig.substitutions:
        p.shuffle(s.dstSet)
        for i in countup(0, s.srcSet.len - 1):
            subst[s.srcSet[i]] = s.dstSet[i]
    result = data.mapIt(if it in subst: subst[it] else: it)


proc pick*(config: NearMissConfig, p: Profile, slotKey: string, preserveItems: ItemKind, count: int): seq[int8] =
    if slotKey notin config.slots:
        return

    let slotConfig = config.slots[slotKey]
    let r = p.random(1.0)
    logNearMisses "NearMiss  random ", r, " vs probability ", slotConfig.probability
    if r > slotConfig.probability:
        return

    var patterns: seq[NearMissPattern]
    if count >= 0:
        case preserveItems:
            of IScatter:
                patterns = slotConfig.patterns.filterIt(it.scatterCount == count)
            of IBonus:
                patterns = slotConfig.patterns.filterIt(it.bonusCount == count)
            of IWild:
                patterns = slotConfig.patterns.filterIt(it.wildCount == count)
            else:
                patterns = slotConfig.patterns
    else:
        patterns = slotConfig.patterns

    if patterns.len == 0:
        logNearMisses "Required pattern not found, no change to spin result"
        return

    let pattern = p.random(patterns)
    result = generateByPattern(slotConfig, p, pattern.data)
    for s in slotConfig.substitutions:
        logNearMisses "Substituting  ", s.srcSet, "  to  ", s.dstSet
    logNearMisses "'", pattern.name, "'  ", pattern.data, "  ->  ", result
