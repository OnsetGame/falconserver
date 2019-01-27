import machine_base_types
export machine_base_types

const NUMBER_OF_REELS* = 5
const ELEMENTS_COUNT* = 15
const LINE_COUNT* = 20
const WILD* = 0'i8
const SCATTER* = 1'i8
const BONUS* = 2'i8
const BONUS_MIN_SYMBOLS* = 3

type SpinResult* = ref object of RootObj
    stage*: Stage
    field*: seq[int8]
    lines*: seq[WinningLine]
    freeSpinsCount*: int


