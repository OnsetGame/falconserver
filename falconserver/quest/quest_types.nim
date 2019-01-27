# import falconserver.map.building.builditem
import strutils

#[
    Story Quests represented in upper case, daily in lower case
 ]#
type
    QuestTaskType* = enum
        qttFreeRounds = (-2, "zZZ")
        qttLevelUp = (-1, "zZ")

        qttBuild   = "AA"
        qttUpgrade = "AB"

        # first tasks iteration
        qttSpinNTimes         = "ac"
        qttWinBigWins         = "aa"
        qttMakeWinSpins       = "ab"
        qttSpinNTimesMaxBet   = "ad"
        qttWinChipOnSpins     = "ae"
        qttWinFreespinsCount  = "ah"
        qttWinBonusTimes      = "ai"
        qttWinChipOnFreespins = "aq"
        qttWinChipsOnBonus    = "ar"

        # qttPlayRoulette     = "ak" not used
        # qttPlayPvP          = "am" not used
        # qttWinPvP           = "ao" not used
        # qttCollectChips     = "ap" not used

        # second tasks iteration
        qttWinNChips       = "as"

        qttWinN5InRow      = "at"
        qttWinN4InRow      = "av"
        qttWinN3InRow      = "aw"

        qttCollectScatters = "ax"
        qttCollectBonus    = "aj"
        qttCollectWild     = "al"

        qttBlowNBalloon    = "ay"
        qttMakeNRespins    = "az"
        # qttThrowTNTCandy   = "ba" not used, implemented in qttCollectWild
        qttPolymorphNSymbolsIntoWild = "bb"

        qttGroovySevens              = "bd"
        qttGroovyLemons              = "bc"
        qttGroovyBars                = "be"
        qttGroovyCherries            = "bh"
        qttCollectHi0                = "h0"
        qttCollectHi1                = "h1"
        qttCollectHi2                = "h2"
        qttCollectHi3                = "h3"

        qttShuffle                   = "bs"
        qttCollectHidden             = "bo"
        qttCollectMultipliers        = "bm"
        qttWinNLines                 = "bl"

    QuestTaskFields* = enum
        qtfType            = "t"    ## task type from enum QuestTaskType
        qtfObject          = "o"    ## task BuildingId
        qtfTotalProgress   = "tp"   ## total task progress
        qtfCurrentProgress = "cp"   ## current task progress, task completed when current reach's total
        qtfProgressIndex   = "pi"
        qtfProgress        = "p"
        qtfDifficulty      = "m"    ## Difficulty multiplayer
        qtfStage           = "s"    ## Last slot stage

    QuestTaskProgress* = enum
        qtpNone = "n"
        qtpHasProgress = "p"
        qtpCompleted = "c"

    QuestDataFields* = enum
        qdfSpins           = "s"
        qdfSlotQuests      = "q"
        qdfCompleteTime    = "u"
        qdfAutoComplete    = "i"
        qdfOldLvl          = "o"
        qdfBet             = "b"
        qdfLines           = "l"
        qdfTotalWin        = "w"
        qdfBonusWin        = "g"
        qdfBonusPayout     = "p"
        qdfBetLevel        = "z"
        qdfStage           = "t"
        qdfMidBet          = "f"
        qdfTotalBet        = "a"
        qdfCollectedChips  = "c"
        qdfQuests          = "d"
        qdfKind            = "k"
        qdfExchangeParts   = "ep"
        qdfFreespins       = "e"
        qdfFreespinsCount  = "fc"

    QuestFields* = enum
        qfId     = "i"     ## quest id
        qfReward = "r"     ## reward earned on quest completed
        qfState  = "d"     ## quest data for tracking tasks progress, stored in db
        qfStatus = "s"     ## quest status: {InProgress, GoalAchieved}
        qfTasks  = "t"     ## quest's task list
        qfKind   = "k"     ## kind of quest

    QuestType* {.pure.} = enum  ## Type of quest
        ## Type of quest
        City
        Slot
        LevelUp

    QuestKind* {.pure.} = enum  ## Kind of quest
        ## Kind of quest
        Daily = "d"
        Story = "s" ## Tutorial Quest and Story Quest
        Achievment = "a"
        LevelUp = "l"

    QuestProgress* {.pure.} = enum
        ## Current quest status
        None  = (-1, "n")
        Ready = "r"
        InProgress = "p"
        GoalAchieved = "g"
        Completed = "c"

    QuestRewardKind* = enum
        qrChips = "cc"
        qrBucks = "cb"
        qrParts = "cp"
        qrExp   = "x"
        qrIncomeChips = "ic"
        qrIncomeBucks = "ib"
        qrTourPoints  = "tp"
        qrMaxBet      = "mb"
        qrRespin
        qrFreespin
        qrBonusChips
        qrFreespinsCount
        qrBonusGame
        qrBigWin
        qrWinSpin
        qrSpin

        # ALL BOOSTERS GOES HERE BEFORE qrBoosterAll
        qrBoosterExp        = "be"
        qrBoosterIncome     = "bi"
        qrBoosterTourPoints = "bt"
        qrBoosterAll        = "ba"

        # VIP bonuses
        qrBucksPurchaseBonus = "bpb"  # == prfBucksPurchaseBonus
        qrChipsPurchaseBonus = "cpb"  # == prfChipsPurchaseBonus
        qrGiftsBonus         = "grb"  # == prfGiftsBonus
        qrExchangeDiscount   = "ed"   # == prfExchangeDiscount
        qrFortuneWheelSpin   = "fws"

        qrSlot


    QuestRewardFields* = enum
        qrfType  = "t" ## type of reward - [ProfileFields]
        qrfCount = "c" ## count of reward
        qrfIsDef = "d" ## is reward deferred
        qrfTbet  = "f" ## helper field, for calculate deferred reward

    DailyDifficultyType* = enum
        trivial, easy, intermediate, medium, hard

proc parseQuestTaskType*(s: string, id: int): QuestTaskType =
    var compVal = s # for levelUp task with id -1 and other posible tasks with id less than 0
    if id >= 100_000:
        compVal = s.toLowerAscii()
    elif id >= 0:
        compVal = s.toUpperAscii()

    for t in low(QuestTaskType)..high(QuestTaskType):
        if $t == compVal:
            return t

    raise newException(ValueError, "invalid enum value: " & s)
