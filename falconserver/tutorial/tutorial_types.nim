

type TutorialState* = enum
    tsInvalidStep             = (-1, "tutorialNotValid")
    tsPlayButton              = "TS_PLAY_BUTTON"
    tsSpinButton              = "TS_SPIN_BUTTON"
    tsTaskProgressPanel       = "TS_TASK_PROGRESS_PANEL"
    tsTournamentButton        = "TS_TOURNAMENT_BUTTON"
    tsTournamentInfoBar       = "TS_TOURNAMENT_INFO_BAR"
    tsTournamentJoin          = "TS_TOURNAMENT_JOIN"
    tsTournamentSpin          = "TS_TOURNAMENT_SPIN"
    tsTournamentInfoBarPoints = "TS_TOURNAMENT_INFOBAR_POINTS"
    tsQuestWindowBar          = "UNUSED"
    tsMapQuestAvailble        = "TS_MAP_QUEST_AVAILBLE"
    tsMapQuestGet             = "TS_MAP_QUEST_GET"
    tsMapQuestComplete        = "TS_MAP_QUEST_COMPLETE"
    tsMapQuestReward          = "TS_MAP_QUEST_REWARD"
    tsMapQuestProgress        = "UNUSED"
    tsMapQuestSpeedup         = "UNUSED"
    tsQuestMapBttn            = "UNUSED"
    tsMapQuestComplete2       = "TS_MAP_QUEST_COMPLETE_2"
    tsMapQuestReward2         = "TS_MAP_QUEST_REWARD_2"
    tsMapSpotEiffel           = "UNUSED"
    tsMapPlaySlot             = "TS_MAP_PLAY_SLOT"
    tsSlotNewTaskBtn          = "TS_SLOT_NEW_TASK_BTTN"
    tsRestaurantCollectRes    = "TS_RESTAURANT_COLLECT_RES"
    tsMapQuestGet2            = "TS_MAP_QUEST_GET_2"
    tsMapQuestAvailble2       = "TS_MAP_QUEST_AVAILBLE_2"
    tsWheelQuest              = "TS_WHEEL_QUEST"
    tsWheelGuiButton          = "TS_WHEEL_GUI_BUTTON"
    tsWheelSpin               = "TS_WHEEL_SPIN"

    tsTaskWinPlaySlot         = "TS_TASKWIN_PLAY_SLOT"
    tsWheelQuestAvailble      = "TS_WHEEL_QUEST_AVAILBLE"
    tsWheelQuestComplete      = "TS_WHEEL_QUEST_COMPLETE"
    tsWheelQuestReward        = "TS_WHEEL_QUEST_REWARD"
    tsTournamentQuestAvailble = "TS_TOURNAMENT_QUEST_AVAILBLE"
    tsUfoQuestAvailble        = "TS_UFO_QUEST_AVAILBLE"
    tsSlotBonusButton         = "TS_SLOT_BONUS_BTTN"

    tsWheelClose              = "TS_WHEEL_CLOSE"
    tsGasStationQuestAvailble = "TS_GASSTATION_QUEST_AVAILBLE"
    tsGasStationCollectRes    = "TS_GASSTATION_COLLECT_RES"
    tsBankQuestAvailble       = "TS_BANK_QUEST_AVAILBLE"
    tsBankFeatureBttn         = "TS_BANK_FEATURE_BTTN"
    tsBankWinExchangeBttn     = "TS_BANK_WIN_EXCHANGE_BTTN"
    tsBankWinClose            = "TS_BANK_WIN_CLOSE"
    tsCandyQuestAvailble      = "TS_CANDY_QUEST_AVAILBLE"
    tsMapPlayCandy            = "TS_MAP_PLAY_CANDY"
    tsCurrencyEnergy          = "TS_CURRENCY_ENERGY"

    tsBoosterQuestAvailble    = "TS_BOOSTER_QUEST_AVAILBLE"
    tsBoosterFeatureButton    = "TS_BOOSTER_FEATURE_BUTTON"
    tsBoosterWindow           = "TS_BOOSTER_WINDOW"
    tsBoosterIndicators       = "TS_BOOSTER_INDICATORS"

    tsNotEnoughTp             = "TS_NOT_ENOUGH_TP"
    tsShowTpPanel             = "TS_SHOW_TP_PANEL"
    tsBankQuestReward         = "TS_BANK_QUEST_REWARD"
    tsMapCandyQuestReward     = "TS_MAP_CANDY_QUEST_REWARD"
    tsStadiumQuestReward      = "TS_TOURNAMENT_QUEST_REWARD"
    tsFirstTournamentReward   = "TS_FIRST_TOURNAMENT_REWARD"

