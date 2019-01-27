import machine_base_types
export machine_base_types

const NUMBER_OF_REELS* = 5
const ELEMENTS_COUNT* = 15
const LINE_COUNT* = 20

type FreespinsType* {.pure.} = enum
    NoFreespin,
    Hidden,
    Multiplier,
    Shuffle

type SpinResult* = ref object of RootObj
    stage*: Stage
    field*: seq[int8]
    lines*: seq[WinningLine]

type SlotMachineCard* = ref object of SlotMachine
    wildsFeatureChances*: seq[tuple[multiplier: int, chance: float]]
    freespinChance*: float
    freespins*: int
    freegameMultiplierChances*: seq[tuple[multiplier: int, chance: float]]
    hiddenIndexes*: seq[int]
    hiddenChances*: seq[tuple[id:int, chance:float]]
    linesMultiplier*: int
    winFreespins*: bool
    freeSpinsCount*: int
    fsType*: FreespinsType
    reelsHidden*: Layout
    reelsMultiplier*: Layout
    reelsShuffle*: Layout
    maxPayout*: int64
    permutedField*: seq[int8]
    permutedLines*: seq[WinningLine]