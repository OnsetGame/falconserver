# This is a wrapper for Oids that is compatible with JS target
when defined(js):
    type ObjectId* = string
    template toString*(o: ObjectId): string = o
    template toObjectId*(s: string): ObjectId = s
else:
    import oids
    type ObjectId* = Oid
    template toString*(o: ObjectId): string = $o
    template toObjectId*(s: string): ObjectId = parseOid(s)
