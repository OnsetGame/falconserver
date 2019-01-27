import sequtils, tables
import slot_data_types

const PIPES_IN_ROW* = 3
const PIPES_IN_COLUMN* = 3

type PipeDirection* = enum
    Left,  # 0
    Top,   # 1
    Right, # 2
    Down   # 3

type MilkFillDirection* = enum
    direct = 0,
    indirect,
    both

type FillInfo* = ref object of RootObj
    pipePos*:int8
    fillAnimDirection*:MilkFillDirection

type BonusField* = seq[int8]
type FillOrder* = seq[seq[FillInfo]]
type FillStatus* = seq[bool]

type Pipes* = enum
    pipeCross,              #[ + ]##0
    pipeTopRight,           #[|`>]##1
    pipeTopLeft,            #[<`|]##2
    pipeHorizontal,         #[---]##3
    pipeVertical,           #[ | ]##4
    pipeBottomLeft,         #[<_|]##5
    pipeBottomRight         #[|_>]##6

const pipesConnectors* : array[low(Pipes) .. high(Pipes), array[4, bool]] = [
    [true,true,true,true], # pipe has connector in direction : left, top, right, down
    [false,true,true,false],
    [true,true,false,false],
    [true, false, true, false],
    [false,true,false,true],
    [true,false,false,true],
    [false,false,true,true]
]

const pipesFillAnimDirection* = {
    pipeCross: {Left:direct}.toTable(), # pipe's milk fill animation direction when milk comes from connector.
    pipeTopLeft: {Left:direct,Top:indirect}.toTable(),
    pipeTopRight: {Top:direct,Right:indirect}.toTable(),
    pipeBottomLeft: {Left:direct,Down:indirect}.toTable(),
    pipeBottomRight: {Right:indirect,Down:direct}.toTable(),
    pipeVertical: {Top:direct,Down:indirect}.toTable(),
    pipeHorizontal: {Left:direct,Right:indirect}.toTable()
}.toTable()

type BonusSpinResult* = ref object of RootObj
    field* : BonusField
    fillOrder* : FillOrder
    stateOfFullness* : seq[bool]
    win*: int64
    hasDouble*:bool

type UfoBonusData* = ref object of RootObj
    spinResults*: seq[BonusSpinResult]
    totalBet*: int64
    totalWin*: int64

proc getNeighborPipesIndexes*(pipeIndex: int8): seq[int8] =
    result = newSeq[int8](4)

    result[Left.int] = -1
    if pipeIndex mod PIPES_IN_ROW != 0:
        result[Left.int] = pipeIndex - 1

    result[Top.int] = pipeIndex - PIPES_IN_ROW

    result[Right.int] = pipeIndex + 1
    if result[Right.int] mod PIPES_IN_ROW == 0:
        result[Right.int] = -1

    result[Down.int] = pipeIndex + PIPES_IN_ROW

proc couldPipeProvideMilk*(p:Pipes, dir:PipeDirection): bool =
    result = pipesConnectors[p][dir.int]
