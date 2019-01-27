
const protocolVersion* = 4

template serverOnly*(body: untyped): untyped =
    when defined(falconServer):
        body

template clientOnly*(body: untyped): untyped =
    when not defined(falconServer):
        body

proc isServerCompatibleWithClientProtocolVersion*(clientProtocolVersion: int): bool =
    if clientProtocolVersion <= protocolVersion: return true
