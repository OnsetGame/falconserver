import machine_base_types
import slot_data_types

const NUMBER_OF_REELS* = 5
const NUMBER_OF_ROWS* = 3
const ELEMENTS_COUNT* = 15
const WILD* = 0'i8
const SCATTER* = 1'i8
const POT_RUNE_STATES* = 4
const LINE_COUNT* = 20

type PotState* {.pure.} = enum
    Start,
    Red,
    Yellow,
    Green,
    Blue,
    Ready

type BonusIngredients* = enum
    Ingredient1
    Ingredient2
    Ingredient3
    Ingredient4
    Ingredient5

type Pot* = ref object of RootObj
    index*: int
    stateIndex*: int
    states*: seq[PotState]

type SlotMachineWitch* = ref object of SlotMachine
    canStartBonus*: bool
    bonusPayout*: int64
    runeCounter*: int
    runeBetTotal*: int64
    bet*: int64
    freespinsMax*: int
    magicSpinChance*: int
    bonusRounds*: int
    bonusProbabilityBasis*: int
    bonusElementsChances*: seq[int]
    bonusElementsPaytable*: seq[seq[int]]

type SpinResult* = ref object of RootObj
    stage*: Stage
    field*: seq[int8]
    lines*: seq[WinningLine]
    freeSpinsCount*: int
    pots*: string
    potsStates*: seq[int]
    bonusTotalBet*: int64
    isSpider*: bool

proc getRoundPayout*(elementsPaytable: seq[seq[int]], s: openarray[int8]): int64 =
    var check: seq[int] = @[0, 0, 0, 0, 0]

    for i in 0..<s.len:
        check[s[i]].inc()

    for i in 0..<5:
        let elems =  check[i]
        if elems >= 3:
            result += elementsPaytable[i][elems - 3]
