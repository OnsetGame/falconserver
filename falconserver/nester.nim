import nest, asynchttpserver, asyncdispatch, cookies, strtabs, strutils, json, times, tables
import falconserver.common.response
import falconserver.common.config
import falconserver.auth.session
export nest.map
export asynchttpserver, strtabs
export Request

import nuuid

type
    Handler = proc(r: Request, args: RoutingArgs): Future[void]
    NesterRouter* = Router[Handler]

proc newRouter*(): NesterRouter = nest.newRouter[Handler]()

var gRouter: NesterRouter
var gRequestLogLevel {.threadvar.}: TableRef[string, int]

proc sharedRouter*(): NesterRouter =
    if gRouter.isNil:
        gRouter = newRouter()
        gRequestLogLevel = newTable[string, int]()
    gRouter

template map(router: Router, action: string, path: string, withSession: bool, logLevel: int, handler: untyped) =
    block:
        proc handleRoute(r: Request, args: RoutingArgs) {.async.} =
            template request: Request {.inject, used.} = r
            var parms: StringTableRef
            template params(r: Request): StringTableRef {.inject, used.} =
                args.queryArgs

            template `@`(a: string): string {.inject, used.} =
                args.pathArgs[a]

            when withSession:
                let clRequest {.inject, used.} = await checkRequest(request)
                if clRequest.status != StatusCode.OK:
                    respJson Http200, json.`%*`({"status": clRequest.status.int, "reason": clRequest.reason})
                    return
                let session {.inject, used.} = clRequest.session
                let profile {.inject, used.} = session.profile
                let requestBody {.inject, used.} = clRequest.body
            handler

        router.map(handleRoute, action, path)
        if logLevel > 1:
            gRequestLogLevel[path] = logLevel

template get*(router: Router, path: string, body: untyped) =
    map(router, "get", path, withSession = false, logLevel = 1, body)

template getEx*(router: Router, path: string, logLevelValue: int, body: untyped) =
    map(router, "get", path, withSession = false, logLevel = logLevelValue, body)

template postEx*(router: Router, path: string, logLevelValue: int, body: untyped) =
    map(router, "post", path, withSession = false, logLevel = logLevelValue, body)

template post*(router: Router, path: string, body: untyped) =
    postEx(router, path, 1, body)

template sessionPostEx*(router: Router, path: string, logLevelValue: int, body: untyped) =
    map(router, "post", path, withSession = true, logLevel = logLevelValue, body)

template sessionPost*(router: Router, path: string, body: untyped) =
    sessionPostEx(router, path, 1, body)

template redirect*(url: string) =
    yield request.respond(Http303, "", newHttpHeaders({"Location": url}))

template resp*(code: HttpCode, content: string,
               contentType = "text/html;charset=utf-8") =
    yield request.respond(code, content, newHttpHeaders({"Access-Control-Allow-Origin" : "*", "Content-Type": contentType}))

template resp*(code: HttpCode,
               headers: openarray[tuple[key, value: string]],
               content: string) =
    yield request.respond(code, content, newHttpHeaders(headers))

template respJson*(code: HttpCode, content: JsonNode) =
    let c = content
    let t = epochTime()
    c["serverTime"] = %t
    logRequests 2, "- ", request.url.path, " ", request.body, " response is ", code, " at ", t
    resp code, {"Access-Control-Allow-Origin" : "*", "Content-Type" : "application/json"}, $c

template routes*(router: NesterRouter, body: untyped) =
    template get(path: string, b: untyped) {.inject.} =
        router.get(path, b)

    template getEx(path: string, logLevel: int, b: untyped) {.inject.} =
        router.getEx(path, logLevel, b)

    template post(path: string, b: untyped) {.inject.} =
        router.post(path, b)

    template postEx(path: string, logLevel: int, b: untyped) {.inject.} =
        router.postEx(path, logLevel, b)

    template sessionPost(path: string, b: untyped) {.inject.} =
        router.sessionPost(path, b)

    template sessionPostEx(path: string, logLevel: int, b: untyped) {.inject.} =
        router.sessionPostEx(path, logLevel, b)

    body

proc cookies*(r: Request): StringTableRef =
    if (let cookie = r.headers.getOrDefault("Cookie"); cookie != ""):
        result = parseCookies(cookie)
    else:
        result = newStringTable()

converter toStringEx*(values: HttpHeaderValues): string =
    return seq[string](values).join(",")

proc allowCrossOriginRequests(r: Request) {.async.} =
    let headers = newHttpHeaders({
            "Access-Control-Allow-Origin" : "*",
            "Access-Control-Allow-Headers" : r.headers["Access-Control-Request-Headers"].toStringEx(),
            "Access-Control-Allow-Methods": r.headers["Access-Control-Request-Method"].toStringEx()})
    await r.respond(Http200, "", headers)

proc serve*(r: NesterRouter, p: Port) {.async.} =
    r.compress()
    let server = newAsyncHttpServer()

    proc dispatch(request: Request) {.async, gcsafe.} =
        if request.reqMethod == HttpOptions:
            await allowCrossOriginRequests(request)
        else:
            let logLevel = gRequestLogLevel.getOrDefault(request.url.path, 1)
            logRequests logLevel, "> ", request.url.path, " ", request.body

            let res = r.route($request.reqMethod, request.url, request.headers)
            let t0 = epochTime()

            if res.status == routingFailure:
                await request.respond(Http404, "Resource not found")
            else:
                var ok = false
                var requestId: string
                try:
                    await res.handler(request, res.arguments)
                    ok = true
                except:
                    requestId = generateUUID()
                    echo "Exception caught(", requestId, "): ", getCurrentExceptionMsg()
                    echo getCurrentException().getStackTrace()

                if not ok:
                    if requestId.len > 0:
                        requestId = " Request id: " & requestId
                    else:
                        requestId = ""
                    resp(Http500, "Internal server error." & requestId)


            logRequests logLevel, ">~", request.url.path, " ", request.body, " in ", formatFloat(epochTime() - t0, format = ffDecimal, precision = 3), "s"

    while true:
        try:
            await server.serve(p, dispatch)
        except:
            echo "Exception caught in server: ", getCurrentExceptionMsg()
            echo getCurrentException().getStackTrace()

        try:
            server.close()
        except:
            echo "Exception caught while closing server: ", getCurrentExceptionMsg()
            echo getCurrentException().getStackTrace()

        await sleepAsync(500)
