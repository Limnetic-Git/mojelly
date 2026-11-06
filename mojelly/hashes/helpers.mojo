# This code is taken from a publicly available repository distributed under the terms of the MIT license:
# https://github.com/lczerniawski/crypto/blob/main/LICENSE

comptime hex_chars = "0123456789abcdef"


def _to_hex(bytes: List[UInt8]) -> String:
    """
    Export the digest as a lowercase hexadecimal string.

    Returns:
        String: A lowercase hex string representation of the digest.
    """
    var out = String()

    for byte in bytes:
        var v = Int(byte)
        out += hex_chars[codepoint=v >> 4]
        out += hex_chars[codepoint=v & 0x0F]

    return out


@always_inline
def _rotate_left(x: UInt32, n: UInt32) -> UInt32:
    return (x << n) | (x >> (32 - n))


@always_inline
def _rotate_right(x: UInt32, n: UInt32) -> UInt32:
    return (x >> n) | (x << (32 - n))