import falconserver.map.building.builditem
export builditem

import quest_types
export quest_types


type
    TaskProgress* = ref object
        current*: uint64
        total*: uint64
        index*: uint

    QuestTask* = ref object of RootObj
        kind*: QuestTaskType
        target*: BuildingId
        difficulty*: DailyDifficultyType
        progresses*: seq[TaskProgress]
        prevStage*: string
        progressState*: QuestTaskProgress
