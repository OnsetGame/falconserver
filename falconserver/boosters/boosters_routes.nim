import falconserver.nester

import falconserver / common / [ response_wrapper, orm ]
#import falconserver / admin / [admin_profile, admin_permissions, slot_zsm_test]
#import falconserver.auth.profile_types

import falconserver.tournament.tournaments
import falconserver.map.collect

# import nimongo.bson
# import nimongo.mongo

import json, asyncdispatch, tables, strutils, sequtils
import oids
import sha1
import times
import logging
import os

import boosters
export boosters

echo "boosters_routes added"

sharedRouter().routes:
    sessionPost "/boost/{booster}":
        let booster = @"booster"
        if booster == $btIncome:
            profile.saveReadyIncomeGain(Currency.Chips)
            profile.saveReadyIncomeGain(Currency.Bucks)
        if not await profile.boosters.start(booster):
            respJson Http200, json.`%*`({"status": "Invalid booster " & booster})
        else:
            if booster == $btTournamentPoints:
                await boostProfileParticipations(profile)
            var resp = json.`%*`({"boosters": profile.boosters.stateResp()})
            await profile.commit()
            if booster == $btIncome:
                resp["collectConfig"] = profile.collectConfig()
            await wrapRespJson(profile, resp, clRequest.clientVersion)
            respJson Http200, resp
