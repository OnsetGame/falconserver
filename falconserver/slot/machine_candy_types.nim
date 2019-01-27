import machine_base_types
export machine_base_types


## Candy Slot Machine Model implementation
const ReelCountCandy* = 5
const CANDY_MAX_SCATTERS* = 5
const LINE_COUNT* = 20
    ## Number of slot machine reels (columns on field)

type BonusDishes* {.pure.} = enum
    Icecream,
    Candy,
    Cake,

type SpinResult* = ref object of RootObj
    stage*: Stage
    field*: seq[int8]
    lines*: seq[WinningLine]
    dishesValue*: seq[int64]
    wildIndexes*: seq[int]
