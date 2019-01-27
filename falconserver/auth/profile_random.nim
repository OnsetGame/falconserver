#
#
#            Nim's Runtime Library
#        (c) Copyright 2017 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Modified nim's standard random number generator. Based on the ``xoroshiro128+`` (xor/rotate/shift/rotate) library.
## * More information: http://xoroshiro.di.unimi.it/
## * C implementation: http://xoroshiro.di.unimi.it/xoroshiro128plus.c
##
## Do not use this module for cryptographic use!

include "system/inclrtl"
{.push debugger:off.}

import profile
export profile

import mersenne
import times

# XXX Expose RandomGenState
when defined(JS):
  type ui = uint32

  const randMax = 4_294_967_295u32
else:
  type ui = uint64

  const randMax = 18_446_744_073_709_551_615u64

type
  RandomGenState = object
    a0, a1: ui


proc rotl(x, k: ui): ui =
  result = (x shl k) or (x shr (ui(64) - k))


proc next(s: var RandomGenState): uint64 =
  let s0 = s.a0
  var s1 = s.a1
  result = s0 + s1
  s1 = s1 xor s0
  s.a0 = rotl(s0, 55) xor s1 xor (s1 shl 14) # a, b
  s.a1 = rotl(s1, 36) # c


proc nextRandomState(p: Profile): uint64 =
  var state = RandomGenState(a0: cast[uint64](p.randomState0), a1: cast[uint64](p.randomState1))
  result = next(state)
  p.randomState0 = cast[int64](state.a0)
  p.randomState1 = cast[int64](state.a1)


# proc skipRandomNumbers(s: var RandomGenState) =
#   ## This is the jump function for the generator. It is equivalent
#   ## to 2^64 calls to next(); it can be used to generate 2^64
#   ## non-overlapping subsequences for parallel computations.
#   when defined(JS):
#     const helper = [0xbeac0467u32, 0xd86b048bu32]
#   else:
#     const helper = [0xbeac0467eba5facbu64, 0xd86b048b86aa9922u64]
#   var
#     s0 = ui 0
#     s1 = ui 0
#   for i in 0..high(helper):
#     for b in 0..< 64:
#       if (helper[i] and (ui(1) shl ui(b))) != 0:
#         s0 = s0 xor s.a0
#         s1 = s1 xor s.a1
#       discard next(s)
#   s.a0 = s0
#   s.a1 = s1

var mSeed = uint32(times.epochTime() * 1_000_000_000)
#echo "seed = ", mSeed
var gMTwister = newMersenneTwister(mSeed)


proc usePrivateRandom(p: Profile): bool =
  result = not p.isNil  and  (p.randomState0 != 0 or p.randomState1 != 0)


#proc random*(max: int): int =
#  result = (gMTwister.getNum() mod max.uint32).int

proc random*(max: int): int =
  result = ((gMTwister.getNum().int64 shl 31  or  gMTwister.getNum().int64 shr 1) mod max.int64).int


# proc random*(max: uint32): uint32 =
#   result = gMTwister.getNum() mod max


# proc random*(max: int32): int32 =
#   result = cast[int32](gMTwister.getNum()) mod max


# proc random*(max: int64): int64 =
#   result = (gMTwister.getNum().int64 shl 32  or  gMTwister.getNum().int64) mod max


proc random*(max: float): float =
  result = (float(gMTwister.getNum()) / float(high(uint32))) * max


proc random*[T](x: Slice[T]): T =
  ## For a slice `a .. b` returns a value in the range `a .. b-1`.
  result = T(random(x.b - x.a)) + x.a


proc random*[T](a: openArray[T]): T =
  ## returns a random element from the openarray `a`.
  result = a[random(a.low..a.len)]


proc random*(p: Profile, max: int): int {.benign.} =
  ## Returns a random number in the range 0..max-1. The sequence of
  ## random number is always the same, unless `randomize` is called
  ## which initializes the random number generator with a "random"
  ## number, i.e. a tickcount.
  if not p.usePrivateRandom():
    return random(max).int
  while true:
    let x = p.nextRandomState()
    if x < randMax - (randMax mod ui(max)):
      return int(x mod uint64(max))


proc random*(p: Profile, max: float): float {.benign.} =
  ## Returns a random number in the range 0..<max. The sequence of
  ## random number is always the same, unless `randomize` is called
  ## which initializes the random number generator with a "random"
  ## number, i.e. a tickcount.
  if not p.usePrivateRandom():
    return random(max)
  let x = p.nextRandomState()
  when defined(JS):
    result = (float(x) / float(high(uint32))) * max
  else:
    let u = (0x3FFu64 shl 52u64) or (x shr 12u64)
    result = (cast[float](u) - 1.0) * max


proc random*[T](p: Profile, x: Slice[T]): T =
  ## For a slice `a .. b` returns a value in the range `a .. b-1`.
  result = T(p.random(x.b - x.a)) + x.a


proc random*[T](p: Profile, a: openArray[T]): T =
  ## returns a random element from the openarray `a`.
  result = a[p.random(a.low..a.len)]


proc randomize*(p: Profile, seed: int) {.benign.} =
  ## Initializes the random number generator with a specific seed.
  p.randomState0 = ui(seed shr 16).int64
  p.randomState1 = ui(seed and 0xffff).int64
  discard p.nextRandomState()


proc shuffle*[T](p: Profile, x: var openArray[T]) =
  ## Will randomly swap the positions of elements in a sequence.
  for i in countdown(x.high, 1):
    let j = p.random(i + 1)
    swap(x[i], x[j])

# when not defined(nimscript):
#   import times

#   proc randomize*(p: Profile) {.benign.} =
#     ## Initializes the random number generator with a "random"
#     ## number, i.e. a tickcount. Note: Does not work for NimScript.
#     if not p.usePrivateRandom():
#       randomize()
#       return
#     when defined(JS):
#       proc getMil(t: Time): int {.importcpp: "getTime", nodecl.}
#       p.randomize(getMil times.getTime())
#     else:
#       p.randomize(int times.getTime())

{.pop.}

when isMainModule:
  proc main =
    var occur: array[1000, int]

    var x = 8234
    var failures = 0
    for i in 0..1000 * len(occur):
      x = mRandom(len(occur)) # myrand(x)
      inc occur[x]
    for i, oc in occur:
      if oc < 790:
        echo "too few (" & $oc & ") occurrences of " & $i
        failures.inc
      elif oc > 1200:
        echo "too many (" & $oc & ") occurrences of " & $i
        failures.inc
    assert failures == 0

  main()
