# This code is taken from a publicly available repository distributed under the terms of the MIT license:
# https://github.com/msaelices/mojo-websockets/blob/main/LICENSE
# Adapted from https://github.com/basalt-org/basalt/blob/076de80812dde323d9de63ea8975ad1875243dc0/basalt/utils/uuid.mojo

from std.collections import Array


struct MersenneTwister(Copyable, Movable):
    """
    Pseudo-random generator Mersenne Twister (MT19937-32bit).
    """

    comptime N: Int = 624
    comptime M: Int = 397
    comptime MATRIX_A: Int32 = 0x9908B0DF
    comptime UPPER_MASK: Int32 = 0x80000000
    comptime LOWER_MASK: Int32 = 0x7FFFFFFF
    comptime TEMPERING_MASK_B: Int32 = 0x9D2C5680
    comptime TEMPERING_MASK_C: Int32 = 0xEFC60000

    var state: Array[Int32, Self.N]
    var index: Int

    def __init__(out self, seed: Int):
        comptime W: Int = 32
        comptime F: Int32 = 1812433253
        comptime D: Int32 = 0xFFFFFFFF

        self.index = Self.N
        self.state = Array[Int32, Self.N]()
        self.state[0] = Int32(seed) & D

        for i in range(1, Self.N):
            self.state[i] = (
                F * (self.state[i - 1] ^ (self.state[i - 1] >> Int32(W - 2)))
                + Int32(i)
            ) & D

    def next(mut self) -> Int32:
        if self.index >= Self.N:
            for i in range(Self.N):
                var x = (self.state[i] & Self.UPPER_MASK) + (
                    self.state[(i + 1) % Self.N] & Self.LOWER_MASK
                )
                var xA = x >> 1
                if x % 2 != 0:
                    xA ^= Self.MATRIX_A
                self.state[i] = self.state[(i + Self.M) % Self.N] ^ xA
            self.index = 0

        var y = self.state[self.index]
        y ^= y >> 11
        y ^= (y << 7) & Self.TEMPERING_MASK_B
        y ^= (y << 15) & Self.TEMPERING_MASK_C
        y ^= y >> 18
        self.index += 1

        return y

    def next_ui8(mut self) -> UInt8:
        return UInt8(self.next()) & 0xFF


struct UUID(Copyable, Equatable, Movable, Writable):
    var bytes: Array[UInt8, 16]

    def __init__(out self):
        self.bytes = Array[UInt8, 16]()

    def __setitem__(mut self, index: Int, value: UInt8):
        self.bytes[index] = value

    def __getitem__(self, index: Int) -> UInt8:
        return self.bytes[index]

    def __eq__(self, other: Self) -> Bool:
        comptime for i in range(16):
            if self.bytes[i] != other.bytes[i]:
                return False
        return True

    def __ne__(self, other: Self) -> Bool:
        return not (self == other)

    def __str__(self) -> String:
        var result: String = ""
        comptime hex_digits: String = "0123456789abcdef"

        comptime for i in range(16):
            if i == 4 or i == 6 or i == 8 or i == 10:
                result += "-"
            result += (
                hex_digits[byte=Int(self.bytes[i] >> 4)]
                + hex_digits[byte=Int(self.bytes[i] & 0xF)]
            )
        return result

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.__str__())


struct UUIDGenerator(Copyable, Movable):
    var prng: MersenneTwister

    def __init__(out self, seed: Int):
        self.prng = MersenneTwister(seed)

    def next(mut self) -> UUID:
        var uuid = UUID()

        comptime for i in range(16):
            uuid[i] = self.prng.next_ui8()

        # Version 4, variant 10xx
        uuid[6] = 0x40 | (0x0F & uuid[6])
        uuid[8] = 0x80 | (0x3F & uuid[8])

        return uuid.copy()
