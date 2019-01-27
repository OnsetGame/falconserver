import asyncdispatch
import json
import httpclient
import tables
import strtabs
import unittest
import times

const
    ProtocolVersion = 1
    BaseUrl = "http://localhost:5001"

proc buildFalconClient(protocolVersion: int, devId: string = nil, sessionId: string = nil): AsyncHttpClient =
    result = newAsyncHttpClient()
    result.headers["Falcon-Proto-Version"] = $protocolVersion
    if not devId.isNil():
        result.headers["Falcon-Device-Id"] = devId
    if not sessionId.isNil():
        result.headers["Falcon-Session-Id"] = sessionId

suite "Test Error Resilience":
    echo "\n General Resilience Behaviour\n"

    setup:
        var client = buildFalconClient(ProtocolVersion)

    test "Test non-existing URL":
        let r = waitFor(client.request(BaseUrl & "/bad_url", httpGet, "{}"))
        check:
            r.status == "404 Not Found"


suite "Test Authentication":
    echo "\n Authentication\n"

    let devId = $getTime()

    setup:
        var client = buildFalconClient(ProtocolVersion, devId)

    test "Test Login With Device ID (new and existing cases)":
        var
            r: Response
            jr: JsonNode

        r = waitFor(client.request(BaseUrl & "/auth/login/device", httpPost, "{}"))
        jr = parseJson(r.body)
        check:
            r.status == "200 OK"
            jr.hasKey("sessionId")
            jr.hasKey("serverTime")

suite "Test Map":
    echo "\n Map\n"

    let devId = $getTime()

    setup:
        var client = buildFalconClient(ProtocolVersion, devId)

    test "Get Map And Create (new user)":
        let sessionId = parseJson(waitFor(client.request(BaseUrl & "/auth/login/device", httpPost, "{}")).body)["sessionId"].getStr()

        client.headers["Falcon-Device-Id"] = ""
        client.headers["Falcon-Session-Id"] = sessionId
        let map = parseJson(waitFor(client.request(BaseUrl & "/map/get", httpGet, "{}")).body)

        check:
            map.hasKey("spots")
            map.hasKey("serverTime")

    test "Get Map And Load (existing user)":
        client.headers["Falcon-Session-Id"] = ""
        let sessionId = parseJson(waitFor(client.request(BaseUrl & "/auth/login/device", httpPost, "{}")).body)["sessionId"].getStr()

        client.headers["Falcon-Session-Id"] = sessionId
        let map = parseJson(waitFor(client.request(BaseUrl & "/map/get", httpGet, "{}")).body)

        check:
            map.hasKey("spots")
            map.hasKey("serverTime")


suite "[Eiffel Slot] Spin Test":
    echo "\n Eiffel Slot\n"

    let devId = $getTime()

    setup:
        var client = buildFalconClient(ProtocolVersion, devId)

    test "[Eiffel Slot] Spinning With Bad JSON":
        let r = waitFor(client.request(BaseUrl & "/slot/spin/dreamTowerSlot", httpPost, "asdasdsa}'"))
        checkpoint($r)
        check r.status == "502 Bad Gateway"

    test "[Eiffel Slot] Spin Unauthorized":
        let r = waitFor(client.request(BaseUrl & "/slot/spin/dreamTowerSlot", httpPost, $(%*{"bet": 20, "lines": 20})))
        check r.status == "502 Bad Gateway"

    test "[Eiffel Slot] Spin Success":
        let sessionId = parseJson(waitFor(client.request(BaseUrl & "/auth/login/device", httpPost, "{}")).body)["sessionId"].getStr()

        client.headers["Falcon-Session-Id"] = sessionId
        let r = waitFor(client.request(BaseUrl & "/slot/spin/dreamTowerSlot", httpPost, $(%*{"bet": 20, "lines": 20})))
        check r.status == "200 OK"

        let jr = parseJson(r.body)
        checkpoint($jr)
        check:
            jr.hasKey("chips")
            jr.hasKey("stages")
            jr.hasKey("serverTime")


suite "[Balloon Slot] Spin Test":
    echo "\n Balloon Slot\n"

    let devId = $getTime()

    setup:
        var client = buildFalconClient(ProtocolVersion, devId)

    test "[Balloon Slot] Spin Success":
        let sessionId = parseJson(waitFor(client.request(BaseUrl & "/auth/login/device", httpPost, "{}")).body)["sessionId"].getStr()

        client.headers["Falcon-Session-Id"] = sessionId
        let r = waitFor(client.request(BaseUrl & "/slot/spin/balloonSlot", httpPost, $(%*{"bet": 20, "lines": 15})))
        check r.status == "200 OK"

        let jr = parseJson(r.body)
        checkpoint($jr)
        check:
            jr.hasKey("stages")
            jr.hasKey("serverTime")


suite "[Candy Slot] Spin Test":
    echo "\n Candy Slot\n"

    let devId = $getTime()

    setup:
        var client = buildFalconClient(ProtocolVersion, devId)

    test "[Candy Slot] Spin Success":
        let sessionId = parseJson(waitFor(client.request(BaseUrl & "/auth/login/device", httpPost, "{}")).body)["sessionId"].getStr()

        client.headers["Falcon-Session-Id"] = sessionId
        let r = waitFor(client.request(BaseUrl & "/slot/spin/candySlot", httpPost, $(%*{"bet": 20, "lines": 15})))
        check r.status == "200 OK"

        let jr = parseJson(r.body)
        checkpoint($jr)
        check:
            jr.hasKey("stages")
            jr.hasKey("serverTime")
            jr["stages"].len() >= 1

echo ""
