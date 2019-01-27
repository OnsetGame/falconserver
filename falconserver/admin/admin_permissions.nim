import nimongo.bson
import falconserver.admin.admin_profile

type APermission* = enum
    apDbView
    apDbModify
    apGrantPermissions

proc checkPermission*(b: Bson, feature: APermission): bool =
    let accLevel = b[$apfAccountLevel].toInt().AdminAccountLevel
    case feature:
    of apDbView:
        result = accLevel > AdminAccountLevel.None
    of apDbModify:
        result = accLevel > AdminAccountLevel.View
    of apGrantPermissions:
        result = accLevel > AdminAccountLevel.Modify

