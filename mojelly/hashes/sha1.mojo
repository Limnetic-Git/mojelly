# SHA-1 Hash Implementation in Mojo
# This code is taken from a publicly available repository distributed under the terms of the MIT license:
# https://github.com/lczerniawski/crypto/blob/main/LICENSE

from helpers import _rotate_left, _to_hex

comptime k0: UInt32 = 0x5A827999  # 0 <= t <= 19
comptime k1: UInt32 = 0x6ED9EBA1  # 20 <= t <= 39
comptime k2: UInt32 = 0x8F1BBCDC  # 40 <= t <= 59
comptime k3: UInt32 = 0xCA62C1D6  # 60 <= t <= 79


# 0 <= t <= 19
@always_inline
def _f0(b: UInt32, c: UInt32, d: UInt32) -> UInt32:
    return (b & c) | ((~b) & d)


# 20 <= t <= 39
@always_inline
def _f1(b: UInt32, c: UInt32, d: UInt32) -> UInt32:
    return b ^ c ^ d


# 40 <= t <= 59
@always_inline
def _f2(b: UInt32, c: UInt32, d: UInt32) -> UInt32:
    return (b & c) | (b & d) | (c & d)


# 60 <= t <= 79
@always_inline
def _f3(b: UInt32, c: UInt32, d: UInt32) -> UInt32:
    return b ^ c ^ d

def sha1(data: Span[UInt8, ...]) -> SHA1Digest:
    """
    Compute the SHA-1 digest of the given data.

    SHA-1 is considered cryptographically broken for collision resistance and
    should not be used for new security-critical applications. Use SHA-256 or
    SHA-3 for cryptographic purposes. This implementation is provided for
    legacy compatibility and non-cryptographic uses (e.g., checksums,
    compatibility with legacy protocols).

    Args:
        data: Input bytes to hash.

    Returns:
        SHA1Digest: A 160-bit (20-byte) digest object with methods to access
        the result as raw bytes or a hex string.
    """

    var zero_bytes_padding = (56 - (len(data) + 1)) % 64

    var message = List[UInt8]()
    for i in range(len(data)):
        message.append(data[i])

    # Pad input data with 1 and 0s
    message.append(0x80)
    for _ in range(zero_bytes_padding):
        message.append(0x00)

    # Write original data length to last 8 bytes
    var original_message_bit_length = UInt64(len(data)) * 8
    message.append((UInt8(original_message_bit_length >> 56) & 0xFF))
    message.append((UInt8(original_message_bit_length >> 48) & 0xFF))
    message.append((UInt8(original_message_bit_length >> 40) & 0xFF))
    message.append((UInt8(original_message_bit_length >> 32) & 0xFF))
    message.append((UInt8(original_message_bit_length >> 24) & 0xFF))
    message.append((UInt8(original_message_bit_length >> 16) & 0xFF))
    message.append((UInt8(original_message_bit_length >> 8) & 0xFF))
    message.append(UInt8(original_message_bit_length & 0xFF))

    var h0: UInt32 = 0x67452301
    var h1: UInt32 = 0xEFCDAB89
    var h2: UInt32 = 0x98BADCFE
    var h3: UInt32 = 0x10325476
    var h4: UInt32 = 0xC3D2E1F0

    var n = 0
    while n < len(message):
        var w = List[UInt32]()
        for j in range(16):
            var base = n + (j * 4)
            var word = UInt32(message[base]) << 24
            word |= UInt32(message[base + 1]) << 16
            word |= UInt32(message[base + 2]) << 8
            word |= UInt32(message[base + 3])
            w.append(word)

        for t in range(16, 80):
            var x = w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16]
            w.append(_rotate_left(x, 1))

        var a = h0
        var b = h1
        var c = h2
        var d = h3
        var e = h4

        for t in range(20):
            var temp = _rotate_left(a, 5) + _f0(b, c, d) + e + w[t] + k0
            e = d
            d = c
            c = _rotate_left(b, 30)
            b = a
            a = temp

        for t in range(20, 40):
            var temp = _rotate_left(a, 5) + _f1(b, c, d) + e + w[t] + k1
            e = d
            d = c
            c = _rotate_left(b, 30)
            b = a
            a = temp

        for t in range(40, 60):
            var temp = _rotate_left(a, 5) + _f2(b, c, d) + e + w[t] + k2
            e = d
            d = c
            c = _rotate_left(b, 30)
            b = a
            a = temp

        for t in range(60, 80):
            var temp = _rotate_left(a, 5) + _f3(b, c, d) + e + w[t] + k3
            e = d
            d = c
            c = _rotate_left(b, 30)
            b = a
            a = temp

        h0 += a
        h1 += b
        h2 += c
        h3 += d
        h4 += e

        n += 64

    return SHA1Digest(h0, h1, h2, h3, h4)


@fieldwise_init
struct SHA1Digest:
    """
    SHA-1 hash digest.

    Represents a 160-bit SHA-1 digest, stored internally as five 32-bit state
    words. Use `to_bytes()` to export the digest as a 20-byte big-endian list
    or `to_hex()` to get a 40-character lowercase hexadecimal string.
    """

    var h0: UInt32
    var h1: UInt32
    var h2: UInt32
    var h3: UInt32
    var h4: UInt32

    def to_bytes(self) -> List[UInt8]:
        """
        Export the digest as a list of 20 bytes.

        Returns:
            List[UInt8]: The 20-byte SHA-1 digest in big-endian byte order
            (standard SHA-1 output format).
        """
        var out = List[UInt8](capacity=20)

        for h in [self.h0, self.h1, self.h2, self.h3, self.h4]:
            out.append(UInt8((h >> 24) & 0xFF))
            out.append(UInt8((h >> 16) & 0xFF))
            out.append(UInt8((h >> 8) & 0xFF))
            out.append(UInt8(h & 0xFF))

        return out^

    def to_hex(self) -> String:
        """
        Export the digest as a lowercase hexadecimal string.

        Returns:
            String: A 40-character lowercase hex string representation of the digest.
        """
        var bytes = self.to_bytes()
        return _to_hex(bytes)