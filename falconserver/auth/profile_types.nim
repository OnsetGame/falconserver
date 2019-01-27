
import tables

const QUEST_GEN_START_ID* =  100000

type
    Achievement* = tuple[title: string, description: string]
        ## Achievement is granted for some long-time tasks

    ProfileFields* = enum
        ## Field names for storing into DB.
        ## Field names are minified for storage optimization
        ## (at least for MongoDB).
        prfId            = "_id"   ## Object ID
        prfPassword      = "pw"
        prfDevices       = "ds"    ## Connected devices
        prfName          = "n"     ## User's name
        prfTitle         = "t"     ## User's title
        prfTimeZone      = "tz"    ## Time Zone

        prfBucks         = "cb"    ## Bucks - premium currency
        prfChips         = "cc"    ## Chips - ordinary currency for betting on slot
        prfParts         = "cp"    ## Parts - currency for build building
        prfExchangeNum   = "ce"    ## Currency exchange nums for chips and parts - auto-incremented on each exchange

        prfCheats        = "cs"    ## Special sequence of spin responses for testing

        prfTourPoints    = "tp"    ## Tournament points
        prfPvpPoints     = "pp"    ## PvP Points

        prfExperience    = "x"     ## Experience (city points)
        prfLevel         = "l"     ## Level (increases depending on experience)
        prfVipPoints     = "vp"    ## VIP points (for currency exchange mechanics)
        prfVipLevel      = "vl"    ## VIP level (for currency exchange mechanics)

        prfFrame         = "f"     ## Frame around user's portrait on profile view
        prfPortrait      = "p"     ## User's portrait (either from Facebook or predefined one)
        prfMessages      = "rs"    ## Now its message system
        prfAchieves      = "as"    ## Large rewards for doind bunch of quest goals

        prfState         = "m"     ## User's profile state

        prfQuests        = "qs"    ## Current quests for user
        prfNextExchangeDiscountTime  = "qt"    ## Next time exchange may be done with discount
        prfQuestsGenId   = "qi"    ## Last quest counter

        prfTutorial      = "tu"    ## Player's tutorial scenario
        prfTutorialState = "ts"    ## Player's tutorial progress
        prfIntroSlot     = "is"    ## Player's intro slot chosen for A/B testing

        prfFBToken       = "fb"    ## Facebook Client's Auth Token
        prfVersion       = "v"     ## Profile version, used for migration from older to newer
        prfStatistics    = "s"     ## User's statistics: spins, realmoney spend etc
        prfNameChanged   = "nc"    ## User's name changing counter

        prfTaskStageOld  = "aa"    ## Stage level for tasks on slots, contains stage level as int and array of quest ids.
                                   ##  Left for backward compatibility, should be replaced with usage of prfSlotQuests
        prfSlotQuests    = "sq"    ## Slot Task stages, containing stage level and task ID for each slot
        prfIsBro         = "ib"    ## Determines user is cheater

        prfFortuneWheel  = "fw"     ## Wheel of Fortune state

        prfSpecialOffer  = "sf"     ## Special offer purchase bool state

        prfBoosters      = "b"      ## Boosters

        prfABTestConfig  = "ab"     ## Name of AB test configuration

        prfAndroidPushToken = "ap"
        prfIosPushToken = "ip"
        prfSessionPlatform = "sp"   ## Platform with which user was logged in this session.

    StateFields* = enum
        steResources = "r"
        steSlots     = "s"
        steClient    = "c"

    ProfileFrame* = enum
        ## Frame is changeable and/or buyable asset
        pfFrame0 = 0
        pfFrame1
        pfFrame2
        pfFrame3
        pfFrame4
        pfFrame5
        pfFrame6
        pfFrame7

    ProfilePortrait* = enum
        ## Player can either choose from 4 prerendered male
        ## or female portraits, or use his/her Facebook
        ## avatar for portrait if loggede in via Facebook
        ppNotSet   = -2
        ppFacebook = -1
        ppMale1    =  0
        ppMale2
        ppMale3
        ppMale4
        ppFemale1
        ppFemale2
        ppFemale3
        ppFemale4

    LinkFacebookType* = enum
        lftNone = "none"
        lftDevice = "device"
        lftFacebook = "facebook"

    LinkFacebookResults* = enum
        larHasBeenLinked
        larCantBeLinked
        larCollision
        larHasBeenAlreadyLinked

    LinkFacebookRestartApp* = bool

const
    TUTORIAL_FINISHED*   = -1
    TUTORIAL_STARTED*    =  0
    TUTORIAL_INTRO*      =  1
    TUTORIAL_INTRO_SLOT* =  2
    TUTORIAL_INTRO2*     =  3

    TUTORIAL_LAST*       =  4

const MongoCollectionProfiles*: string = "profiles"
const MongoCollectionSavedProfiles*: string = "saved_profiles"
const MongoCollectionCheaters*: string = "cheater_profiles"

const Achievements*: OrderedTable[string, Achievement] = {
    "achFirstBlood": ("First Blood", "Build 3 Slot Buildings").Achievement
}.toOrderedTable()
