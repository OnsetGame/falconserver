import oids
import nimongo.bson

const MongoCollectionAdmins*: string = "admins"
const FindQueriesCollection*: string = "adminsFindQueries"

type AdminAccountLevel* {.pure.} = enum
    None   = "n" # new admin user's, waiting developers aproove
    View   = "v" # view server stats
    Modify = "m" # modify game balanse
    Full   = "f" # full access

type AdminProfileFields* = enum
    apfMail = "m"
    apfSalt = "s"
    apfSecret = "q"
    apfAccountLevel = "l"
    apfRequestId = "r"

proc newAdminProfile*(mail: string, sec: string): Bson =
    result = bson.`%*`({
        $apfMail:  mail,
        $apfSecret: sec,
        $apfSalt:   "",
        $apfRequestId: "",
        $apfAccountLevel: AdminAccountLevel.None.int
    })


