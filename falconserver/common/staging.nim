import os

var isStage* = false
if getEnv("FALCON_ENV") == "stage":
    isStage = true

const stageApiUrl* = "https://stage-api.onsetgame.com"
const prodApiUrl* = "https://game-api.onsetgame.com"
