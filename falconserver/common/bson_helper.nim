import json

import times
import boolseq

import nimongo.bson
export bson


proc toBson*(s: seq[int8]): Bson =
    result = newBsonArray()
    for i in s:
        discard result.add(i.toBson)

proc toSeqTyped*[baseT, T](b: Bson, s: var seq[T]) =
    s.setLen(b.len)

    var i = 0
    for v in b:
        s[i] = T(v.baseT)
        inc i

proc toSeqTyped*[baseT, T](b: Bson): seq[T] =
    toSeqTyped[baseT, T](b, result)

proc toSeqInt*[T](b: Bson, s: var seq[T]) =
    toSeqTyped[int, T](b, s)

proc toSeqInt*[T](b: Bson): seq[T] =
    toSeqTyped[int, T](b, result)

proc toSeqFloat*[T](b: Bson): seq[T] =
    toSeqTyped[float, T](b, result)

proc toSeqInt8*(b: Bson, s: var seq[int8]) {.deprecated, inline.} =
    toSeqInt(b, s)

proc toBson*(s: seq[tuple[k: int, v: int]]): Bson =
    var arr = newBsonArray()
    for i in s:
        discard arr.add(i.k.toBson)
        discard arr.add(i.v.toBson)
    return arr

proc toBson*(s: seq[tuple[k: int, v: int64]]): Bson =
    var arr = newBsonArray()
    for i in s:
        discard arr.add(i.k.toBson)
        discard arr.add(i.v.toBson)
    return arr

proc toBoolSeq(jn: JsonNode): BoolSeq=
    var questate = ""
    for ji in jn:
        questate.add(ji.getInt().char)

    result = newBoolSeq(questate)

proc toBson*(json: JsonNode): Bson =
    case json.kind:
    of JNull:
        result = null()
    of JBool:
        result = json.getBool().toBson()
    of JInt:
        result = json.getBiggestInt().toBson()
    of JFloat:
        result = json.getFloat().toBson()
    of JString:
        result = json.getStr().toBson()
    of JObject:
        if "boolseq" in json:
            result = binuser(json["boolseq"].toBoolSeq().string)
        else:
            result = newBsonDocument()
            for k, v in json:
                result[k] = v.toBson()
    of JArray:
        result = newBsonArray()
        for v in json:
            result.add(v.toBson())

proc toJson*(bson: Bson): JsonNode =
    case bson.kind
    of BsonKindInt32:
        result = %bson.toInt32()
    of BsonKindInt64:
        result = %bson.toInt64()
    of BsonKindDouble:
        result = %bson.toFloat64()
    of BsonKindNull:
        result = newJNull()
    of BsonKindStringUTF8:
        result = %bson.toString()
    of BsonKindArray:
        result = newJArray()
        for ch in bson:
            result.add(ch.toJson())
    of BsonKindBool:
        result = %bson.toBool()
    of BsonKindDocument:
        result = newJObject()
        for key, value in bson:
            result[key] = value.toJson()
    of BsonKindOid:
        result = %($bson)
    of BsonKindTimeUTC:
        result = %($(bson.toTime()))
    of BsonKindBinary:
        result = newJObject()
        result["boolseq"] = %newBoolSeq(bson.binstr()).toIntSeq()
    else:
        result = newJNull()
        echo "toJson(bson: Bson): not implemeted convertation from : ", bson.kind
