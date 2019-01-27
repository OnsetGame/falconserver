import sets, logging, macros, typetraits, json, oids, times, asyncdispatch, strutils, algorithm
import nimongo / [ bson, mongo ]

export bson
export mongo
export asyncdispatch

proc defVal(T: typedesc): T =
    discard


proc bsonToVal[T](bv: Bson): T =
    when T is Bson:    bv
    elif T is float64: bv.toFloat64()
    elif T is int:     bv.toInt()
    elif T is int64:   bv.toInt64()
    elif T is bool:    bv.toBool()
    elif T is Oid:     bv.toOid()
    elif T is Time:    bv.toTime()
    elif T is string:  bv.toString()
    else:
        static:
            echo "No implementation for reading type '", T.name, "'' from Bson"
            {.error: "No implementation for reading type T from Bson".}


type MongoObj* = ref object of RootObj
    collection*: Collection[AsyncMongo]
    bson*: Bson


type TransparentMongoObj* = ref object of MongoObj
    changedFields*: HashSet[string]


proc init*(o: TransparentMongoObj, c: Collection[AsyncMongo], b: Bson) =
    o.collection = c
    o.bson = b
    o.changedFields = initSet[string]()


proc transparentRead*[T](o: TransparentMongoObj, dbTag: string, default: T): T =
    #echo "transparent reading ", dbTag, " from Bson"
    let bv = o.bson{dbTag}
    if not bv.isNil:
        result = bsonToVal[T](bv)
    else:
        result = default

proc transparentWrite(o: TransparentMongoObj, createIntermediateDocs: bool,  dbTags: varargs[string], value: Bson) =
    let dbPath = dbTags.join(".")
    o.changedFields.incl(dbPath)

    var b = o.bson
    for i in 0 ..< dbTags.len - 1:
        let dbt = dbTags[i]
        if dbt notin b:
            if not createIntermediateDocs:
                raise newException(Exception, "Key not found " & dbPath)

            b[dbt] = newBsonDocument()
        b = b[dbt]

    b[dbTags[^1]] = value


proc writeChanges*(o: TransparentMongoObj, b: Bson) =
    var keys = newSeqOfCap[seq[string]](o.changedFields.len)

    for k in o.changedFields:
        keys.add(k.split("."))

    keys.sort do(f,s:seq[string]) -> int:
        cmp(f.len, s.len)

    for sk in keys:
        var found = false
        for i in 0 ..< sk.len - 1:
            let subKey = sk[0 .. i].join(".")
            if subKey in b:
                found = true
                break
        if not found:
            let fullKey = sk.join(".")
            b[fullKey] = o.bson{sk}

template generateTransparentAccessors(ormType: typedesc, field: untyped, fieldType: typedesc, dbTag: string): untyped =
    template field*(o: ormType): fieldType =
        transparentRead[fieldType](o, dbTag, defVal(fieldType))
    template `field=`*(o: ormType, value: fieldType) =
        transparentWrite(o, false, dbTag, value.toBson())


template generateTransparentGenericAccessors(ormType: typedesc): untyped =
    template contains*(o: ormType, key: string): bool =
        o.bson.contains(key)
    template `[]`*(o: ormType, key: string): Bson =
        o.bson[key]
    template `{}`*(o: ormType, keys: varargs[string]): Bson =
        o.bson{keys}
    template `{}=`*(o: ormType, keys: varargs[string], value: Bson) =
        transparentWrite(o, true, keys, value)
    template `[]=`*(o: ormType, keys: varargs[string], value: Bson) =
        transparentWrite(o, false, keys, value)


type CachingMongoObj* = ref object of MongoObj
        #db*: Database[AsyncMongo]
        #bson*: Bson
        discard


type CachingField*[T] = object
        isUsed: bool
        isChanged: bool
        #initVal*: T
        curVal*: T


proc init*(o: CachingMongoObj, c: Collection[AsyncMongo], b: Bson) =
    o.collection = c
    o.bson = b


proc getVal*[T](f: var CachingField[T], b: Bson, tag: string, default: T): T =
    if not f.isUsed:
        let bv = b{tag}
        if not bv.isNil:
            f.curVal = bsonToVal[T](bv)
        else:
            f.curVal = default
        f.isUsed = true
    result = f.curVal


proc setVal*[T](f: var CachingField[T], value: T) =
    f.isUsed = true
    f.isChanged = true
    f.curVal = value


proc writeChange*[T](f: CachingField[T], b: Bson, dbTag: string) =
    if f.isChanged:
        b[dbTag] = f.curVal.toBson()


template toJson(val: string | int | int64 | float64 | bool): JsonNode = json.`%*`(val)
template toJson(val: Oid): JsonNode = % $val
template toJson(val: Time): JsonNode = % val.toSeconds

proc writeChange*[T](f: CachingField[T], j: JsonNode, jsonTag: string) =
    if f.isChanged:
        j[jsonTag] = f.curVal.toJson()

template generateCachingAccessors(ormType: typedesc, field: untyped, fieldType: typedesc, member: untyped, dbTag: string, fieldDefVal: untyped): untyped =
    template field*(o: ormType): fieldType =
        o.member.getVal(o.bson, dbTag, fieldDefVal)
    template `field=`*(o: ormType, value: fieldType) =
        o.member.setVal(value)


proc mongoSetDict*[T: MongoObj](o: T): Bson =
    result = newBsonDocument()
    mixin writeChanges
    o.writeChanges(result)

proc commit*[T: MongoObj](o: T): Future[void] {.async.} =
    doAssert(not o.collection.isNil)

    var changes = o.mongoSetDict()
    if changes.len > 0:
        let id = o.bson{"_id"}
        if not id.isNil and id.kind == BsonKindOid:
            # Update
            let s = await o.collection.update( B("_id", id), B("$set", changes), multi = false, upsert = false)
            s.checkMongoReply()
        else:
            # Insert
            while true:
                o.bson["_id"] = genOid().toBson()
                let res = await o.collection.insert(o.bson)
                let we = res.bson{"writeErrors"}
                if not we.isNil:
                    let c = we[0]{"code"}
                    if not c.isNil:
                        let code = c.toInt()
                        if code == 11000 or code == 11000: # Duplicate key
                            info o.collection, " id collision, retrying. ", o.bson["_id"]
                            continue
                    error "Unknown write errors: ", we
                break


proc jsonChanges*[T: CachingMongoObj](o: T): JsonNode =
    result = newJObject()
    o.writeChanges(result)


# For each field declared:
#
#    ORMObj SomeType:
#        someField: int("sf", "someField")
#
# macro does these things:
#
#   0. Declares type `SomeType` as ref object of RootObj
#
#   1. declares member named `someFieldF` of type `Field[int]` in type `SomeType`
#
#   2. declares typed getter  `someField`(o: SomeType): int  and setter  `someField=`(o: SomeType, value: int)
#
#   3. adds call of someFieldF.read(<bson>) and someFieldF.write(<bson>) to corresponding procs for SomeType,
#      where "sf" stands for bson tag
#
#   4. adds call of someField.write(<json>) to corresponding proc for SomeType,
#      where "someField" stands for json tag
#
#
# Typed getter and setter are needed for statements like
#
#   let x = someTypeObj.someField
#   inc x
#   someTypeObj.someField = x
#
# where we want x to be of `int` type, not a `Field[int]` one

proc addRefObjTypeDeclaration(rootSL: NimNode, typeName: NimNode, baseType: NimNode): NimNode =
    # <typeName> = ref object of RootObj:
    #     `<result = typedefFields>`
    result = newNimNode(nnkRecList)
    rootSL.add(newTree(nnkTypeSection,
        newTree(nnkTypeDef,
            newTree(nnkPostfix, newIdentNode("*"), typeName),
            newEmptyNode(),
            newTree(nnkRefTy,
                newTree(nnkObjectTy,
                    newEmptyNode(),
                    newTree(nnkOfInherit, baseType),
                    result)))))


proc ORMObj(typeName: NimNode, cached: bool, body: NimNode): NimNode =
    result = newStmtList()

    let baseTypeName = if cached: "CachingMongoObj" else: "TransparentMongoObj"
    let typedefFields = addRefObjTypeDeclaration(result, typeName, newIdentNode(baseTypeName))

    # proc writeChanges(o: <type>, b: Bson)
    var writeToBsonProcBody = newStmtList()
    let writeToBsonProc = newProc(name = newTree(nnkPostfix, newIdentNode("*"), newIdentNode("writeChanges")),
                                  params = [newEmptyNode(),
                                            newIdentDefs(newIdentNode("o"), typeName),
                                            newIdentDefs(newIdentNode("b"), newIdentNode("Bson"))],
                                  body = writeToBsonProcBody)

    # proc writeChanges(o: <type>, j: JsonNode)
    var writeToJsonProcBody = newStmtList()
    let writeToJsonProc = newProc(name = newTree(nnkPostfix, newIdentNode("*"), newIdentNode("writeChanges")),
                                  params = [newEmptyNode(),
                                            newIdentDefs(newIdentNode("o"), typeName),
                                            newIdentDefs(newIdentNode("j"), newIdentNode("JsonNode"))],
                                  body = writeToJsonProcBody)

    #let fieldTemplateName = if cached: "CachingField" else: "TransparentField"

    if not cached:
        result.add(newCall(bindsym"generateTransparentGenericAccessors", typeName))

    for field in body:
        let accessorName = field[0]
        let memberName = newIdentNode($accessorName & "F")
        if field[1][0].kind != nnkCall:
            # regular field, just add it to a final type
            typedefFields.add(newIdentDefs(newTree(nnkPostfix, newIdentNode("*"), field[0]), field[1][0]))
            continue

        let fieldType = field[1][0][0]
        let fieldDbTag = field[1][0][1]
        let fieldJsonTag = if field[1][0].len > 2: field[1][0][2]  else: fieldDbTag

        if cached:
            typedefFields.add(newIdentDefs(memberName, newTree(nnkBracketExpr, newIdentNode("CachingField"), fieldType)))
            writeToBsonProcBody.add(
                newTree(nnkCall,
                    newTree(nnkDotExpr, newTree(nnkDotExpr, newIdentNode("o"), memberName), newIdentNode("writeChange")), newIdentNode("b"), fieldDbTag))
            writeToJsonProcBody.add(
                newTree(nnkCall,
                    newTree(nnkDotExpr, newTree(nnkDotExpr, newIdentNode("o"), memberName), newIdentNode("writeChange")), newIdentNode("j"), fieldJsonTag))
            let fieldDefVal = newCall(bindsym"defVal", fieldType)
            result.add(newCall(bindsym"generateCachingAccessors", typeName, accessorName, fieldType, memberName, fieldDbTag, fieldDefVal))
        else:
            result.add(newCall(bindsym"generateTransparentAccessors", typeName, accessorName, fieldType, fieldDbTag))

    if cached:
        result.add(writeToBsonProc)
        result.add(writeToJsonProc)


macro TransparentObj*(typeName: untyped, body: untyped): untyped =
    ORMObj(typeName, false, body)

macro CachedObj*(typeName: untyped, body: untyped): untyped =
    ORMObj(typeName, true, body)
