import math


proc calcRewardShare(playersCount: int, place: int): float =
    case playersCount:
    of 1..14:
        case place:
        of 1: result = 0.6
        of 2: result = 0.3
        of 3: result = 0.1
        else: discard
    of 15..49:
        case place:
        of 1: result = 0.5
        of 2: result = 0.26
        of 3: result = 0.08
        of 4..5: result = 0.08
        else: discard
    of 50..99:
        case place:
        of 1: result = 0.4
        of 2: result = 0.19
        of 3: result = 0.07
        of 4..5: result = 0.07
        of 6..10: result = 0.04
        else: discard
    of 100..199:
        case place:
        of 1: result = 0.3
        of 2: result = 0.16
        of 3: result = 0.04
        of 4..5: result = 0.04
        of 6..10: result = 0.028
        of 11..20: result = 0.028
        else: discard
    of 200..299:
        case place:
        of 1: result = 0.25
        of 2: result = 0.12
        of 3: result = 0.04
        of 4..5: result = 0.04
        of 6..10: result = 0.025
        of 11..20: result = 0.024
        of 21..50: result = 0.005
        else: discard
    else:
        case place:
        of 1: result = 0.24
        of 2: result = 0.11
        of 3: result = 0.035
        of 4..5: result = 0.035
        of 6..10: result = 0.023
        of 11..20: result = 0.023
        of 21..50: result = 0.005
        of 51..100: result = 0.001
        else: discard


proc calcRewardPoints*(playersCount: int, place: int, score: int): int =
    result = max(1, score)
    # result = round(score / 2 + calcRewardShare(playersCount, place) * 500).int + 1


proc calcRewardCurrency*(prizeFund: int64, playersCount: int, place: int): int64 =
    result = round(prizeFund.float * calcRewardShare(playersCount, place)).int64
