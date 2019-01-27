import tables, json
import asyncdispatch
import falconserver.common.orm

import falconserver.nester
import falconserver / common / response_wrapper
#import falconserver.routes.auth_routes

import tournaments
import fake_participation


echo "tournament_routes added"

let router = sharedRouter()
router.routes:
    sessionPost "/tournaments/createfast":
        await createFastTournament()
        let r = await listTournaments(session.profile, clRequest.body{"sinceTime"})
        await wrapRespJson(clRequest.session.profile, r, clRequest.clientVersion)
        respJson Http200, r

    sessionPost "/tournaments/tutorial":
        let participations = await session.profile.findProfileParticipations()
        if participations.len > 0:
            let r = await listTournaments(session.profile, nil)
            await wrapRespJson(clRequest.session.profile, r, clRequest.clientVersion)
            respJson Http200, r
        else:
            let t = await session.profile.findOrCreateTutorialTournament()
            while t.playersCount < 3:
                await t.tournamentBotsJoin()
            let r = await t.getTutorialTournamentResp()
            await wrapRespJson(clRequest.session.profile, r, clRequest.clientVersion)
            respJson Http200, r

    sessionPost "/tournaments/bots/join":
        let r = await tryBotsJoinTournament(clRequest.body)
        await wrapRespJson(clRequest.session.profile, r, clRequest.clientVersion)
        respJson Http200, r

    sessionPost "/tournaments/finish":
        let r = await tryForceFinishTournament(session.profile, clRequest.body)
        await wrapRespJson(clRequest.session.profile, r, clRequest.clientVersion)
        respJson Http200, r

    sessionPost "/tournaments/gain":
        let r = await tryGainTournamentScore(clRequest.session.profile, clRequest.body)
        await wrapRespJson(clRequest.session.profile, r, clRequest.clientVersion)
        respJson Http200, r

    sessionPost "/tournaments/list":
        let r = await listTournaments(clRequest.session.profile, clRequest.body{"sinceTime"})
        await wrapRespJson(clRequest.session.profile, r, clRequest.clientVersion)
        respJson Http200, r

    sessionPost "/tournaments/join":
        let resp = await tryJoinTournament(session.profile, clRequest.body)
        if not resp.hasKey("partId"):
            echo resp["status"].getStr()

        await wrapRespJson(clRequest.session.profile, resp, clRequest.clientVersion)
        respJson Http200, resp

    sessionPost "/tournaments/leave":
        let r = await tryLeaveTournament(session.profile, clRequest.body)
        await wrapRespJson(clRequest.session.profile, r, clRequest.clientVersion)
        respJson Http200, r

    sessionPost "/tournaments/claim":
        let r = await tryClaimTournamentReward(session.profile, clRequest.body)
        await wrapRespJson(clRequest.session.profile, r, clRequest.clientVersion)
        respJson Http200, r

    sessionPost "/tournaments/info":
        let r = await tryGetTournamentDetails(session.profile, clRequest.body)
        await wrapRespJson(clRequest.session.profile, r, clRequest.clientVersion)
        respJson Http200, r
