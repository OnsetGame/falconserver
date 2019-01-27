import json
import oids
import unittest

import nimongo.bson

import falconserver.auth.profile
import falconserver.auth.profile_types

suite "Testing user's profile":

    test "Profile constructor":
        let p = newProfile()
        check:
            p["_id"] != Oid()
            p.bucks == INITIAL_BUCKS
            p.chips == INITIAL_CHIPS
            p.portrait == ppNotSet.int
            p.frame == pfFrame0.int

    test "Profile to Json (default)":
        let
            p = newProfile()
            j = p.toJsonProfile()
        check:
            j[$prfBucks].getNum() == p.bucks
            j[$prfChips].getNum() == p.chips
            j[$prfPortrait].getNum() == ppNotSet.int
            j[$prfFrame].getNum() == pfFrame0.int

    test "Profile to Json (full)":
        let
            p = newProfile()
            j = p.toJsonProfile(full = true)
        check:
            j.hasKey($prfDevices)
            j.hasKey($prfCheats)