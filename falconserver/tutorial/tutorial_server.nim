import boolseq
import json except `()`

import nimongo.bson

import falconserver.auth.profile_types
import falconserver.auth.profile
import falconserver.common.bson_helper
import falconserver.common.response
import falconserver.tutorial.tutorial_types

export tutorial_types

proc completeTutorialState*(p: Profile, tutorialId: TutorialState): Bson=
    var tutorialBoolSeq = newBoolSeq(p.tutorialState.binstr())
    if tutorialBoolSeq.len <= tutorialId.int:
        tutorialBoolSeq.setLen(tutorialId.int + 1)

    tutorialBoolSeq[tutorialId.int] = true
    p.tutorialState = binuser(tutorialBoolSeq.string)

    result = p.tutorialState

    #echo "save tutorial state ", tutorialId, " upd ", result

proc tutorialStateForClient*(p: Profile): JsonNode=
    var tutorialBoolSeq = newBoolSeq(p.tutorialState.binstr())
    result = newJObject()
    for ts in low(TutorialState) .. high(TutorialState):
        if ts.int < 0: continue

        if ts.int < tutorialBoolSeq.len:
            result[$ts] = %tutorialBoolSeq[ts.int]
        else:
            result[$ts] = %false
