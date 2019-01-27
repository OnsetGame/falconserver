## Base slot machine types and procedure

import tables
import sequtils

type
    ErrorInvalidZsm* = ref object of ValueError
        ## Raises when cannot construct slot model from ZSM file.

    ErrorNotImplemented* = ref object of ValueError
        ## Raises when there's some specific method that must be implemented
        ## in type inherited from base SlotMachine type.

    ItemKind* = enum
        ## Defines item behaviour, winning combinations and payment amount.
        ISimple   = 0'i8                ## Simple item - only simple combinations
        IWild     = 1'i8                ## Wild can replace any simple item
        IScatter  = 2'i8                ## Scatter adds more free spins
        IBonus    = 3'i8                ## Bonus item activates bonus mini-games
        IWild2    = 4'i8                ## Wild item of separate kind
        IDesroyed = 5'i8                ## Item was destroyed after spin

    ItemObj* = object
        ## Slot Item which is identified by ItemKind_ and id.
        id*:   int8                    ## Item unique identifier (position in ZSM file)
        kind*: ItemKind                ## ItemKind
        name*: string                  ## Item unique name (serves as id for ZSM editor)
        p*:    float                   ## Probability (if applicable)

    ItemSet* = seq[ItemObj]
        ## Set of unique items found on slot machine reels.

    Reel* = seq[ItemObj]
        ## Ordered sequence of items from item set
        ## that represents single slot machine reel.

    Combination* = seq[ItemObj]
        ## Ordered sequence of items which can be payed.

    Line* = seq[int16]
        ## Sequence of reel item indices, representing a line.

    Layout* = ref object
        ## Slot machine field layout (sequence of Reels)
        reels*:    seq[Reel]
        lastSpin*: seq[int8]

    WinningLine* = tuple
        ## Winning symplos and payouts
        numberOfWinningSymbols: int    ## Number of first symbols in line, resulting
                                       ## in winning combination
        payout: int64                  ## Payout for this line

    Paytable* = seq[seq[int]]
        ## Two-dimensional matrix that defines how much to pay for certain item
        ## combinations on lines. Column is a per-item dimension
        ## (index goes first).

    Stage* {.pure.} = enum
        ## Defines slot machine simulation game stage:
        ##   * .Spin     - simple spin
        ##   * .FreeSpin - freespin stage (scatters, destructions, etc..)
        ##   * .Bonus    - bonus game (3 bonus elements, etc..)
        Spin,
        Respin,
        FreeSpin,
        Bonus

    SlotMachine* = ref object of RootObj
        ## Base slot machine model
        items*:         ItemSet        ## Unique items set
        paytable*:      Paytable       ## Paytable for the machine
        fieldHeight*:   int8           ## Visible vertical number of items on machine
        reels*:         Layout         ## Standard (minimal) set of slot machine reels
        reelsRespin*:   Layout         ## Reel set for `respin` stage [optional]
        reelsFreespin*: Layout         ## Reel set for `freespin` stage [optional]
        lines*:         seq[Line]      ## Sequence of winning lines
        freespinCount*: int            ## Number of current free spins
        lastSpin*:      seq[int8]      ## Spin shifts per reel

    FieldRefillKind* {.pure.} = enum
        ## Defines how slot items on field behave after items destruction
        None                           ## Items on reels are filled up randomly
        ShiftUp                        ## Items on reels fly up to fill field
        ShiftDown                      ## Items drop down on reels to fill field

var slotMachineRegistry = initTable[string, SlotMachine]()

method combinations*(sm: SlotMachine, field: openarray[int8], lineCount: int): seq[Combination] {.base, gcsafe.} =
    ## Return combinations depending on current slot machine state.
    ## For single-reel machines is always a combination for its layout.
    ## For multi-reel machines it depends on machine state (which itself
    ## defines what kind of layout we must use in specific slot machine state).
    raise new(ErrorNotImplemented)

method reelCount*(sm: SlotMachine): int {.base, gcsafe.} = sm.reels.reels.len
    ## Number of slot machine reels

method payoutForCombination*(sm: SlotMachine, combination: Combination, isJackpot: var bool): WinningLine {.base, gcsafe.} =
    const NOTRACK = -1'i8
    var
        inarow = 1'i8
        inarowwild = 1'i8
        tracked = NOTRACK

    # Checking for jackpot
    if all(combination, proc(item: ItemObj): bool = item.kind == IWild):
        isJackpot = true

    # Checking for line combination without wilds
    for i in 0 .. sm.reelCount() - 2:
        if combination[i] == combination[i+1]:
            inc(inarow)
        else:
            break

    for i in 0 .. sm.reelCount() - 2:
        if combination[i].kind != IWild and tracked == NOTRACK and combination[i].kind != IWild2:
            tracked = combination[i].id
        elif combination[i+1].kind != IWild and tracked == NOTRACK and combination[i+1].kind != IWild2:
            tracked = combination[i+1].id

        if combination[i+1].kind == IScatter or combination[i+1].kind == IBonus:
            break

        if combination[i] == combination[i+1]:
            inc(inarowwild)
            if inarowwild == sm.reelCount() and tracked == NOTRACK: #when jackpot, tracked must be IWild
                tracked = combination[i].id
        elif (combination[i].kind == IWild and combination[i+1].id == tracked ) or
                (combination[i+1].kind == IWild and combination[i].id == tracked):
            inc(inarowwild)
        elif (combination[i].kind == IWild2 and combination[i+1].id == tracked ) or
                (combination[i+1].kind == IWild2 and combination[i].id == tracked):
            inc(inarowwild)
        else:
            break

    if inarow > 1 and (combination[0].kind == IWild or combination[0].kind == IWild2):
        discard
    elif tracked != NOTRACK and sm.items[tracked].kind != ISimple:
        result.numberOfWinningSymbols = 1
        return

    result.numberOfWinningSymbols = max(inarow, inarowwild)
    if inarow > 1 and inarowwild > 1:
        let
            payedsimple = sm.paytable[sm.reelCount() - inarow][combination[0].id]
            payedwild = sm.paytable[sm.reelCount() - inarowwild][tracked]
        if payedsimple == payedwild and payedsimple == 0:
            result.payout = 0
        elif payedsimple > payedwild:
            result.numberOfWinningSymbols = inarow
            result.payout = payedsimple
        else:
            result.numberOfWinningSymbols = inarowwild
            result.payout = payedwild
    elif inarow > 1:
        let payedsimple: int = sm.paytable[sm.reelCount() - inarow][combination[0].id]
        result.payout = payedsimple
    elif inarowwild > 1:
        let payedwild: int = sm.paytable[sm.reelCount() - inarowwild][tracked]
        result.payout = payedwild

proc payouts*(sm: SlotMachine, combinations: openarray[Combination], isJackpot: var bool): seq[WinningLine] {.gcsafe.} =
    result = @[]
    for combination in combinations:
        result.add(sm.payoutForCombination(combination, isJackpot))

proc payouts*(sm: SlotMachine, combinations: openarray[Combination]): seq[WinningLine] {.gcsafe.} =
    var isJackpot = false
    result = sm.payouts(combinations, isJackpot)
