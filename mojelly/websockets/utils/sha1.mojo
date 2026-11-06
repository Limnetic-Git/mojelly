# This code is taken from a publicly available repository distributed under the terms of the MIT license:
# https://github.com/msaelices/mojo-websockets/blob/main/LICENSE
"""
SHA1 Implementation in pure Mojo.

This module implements the SHA-1 hashing algorithm as described in FIPS PUB 180-1.

Code converted to Mojo from this Python implementation: https://github.com/ajalt/python-sha1
"""

from std.collections import Array
from mojelly.websockets.aliases import Bytes
from mojelly.websockets.utils.bytes import bytes_to_str


def _left_rotate(n: UInt32, b: Int) -> UInt32:
    """Left rotate a 32-bit integer n by b bits."""
    return (n << UInt32(b)) | (n >> UInt32(32 - b))


def _process_chunk(
    mut chunk: Bytes,
    h0: UInt32,
    h1: UInt32,
    h2: UInt32,
    h3: UInt32,
    h4: UInt32,
) -> Tuple[UInt32, UInt32, UInt32, UInt32, UInt32]:
    """Process a chunk of data and return the new digest variables."""

    var w = Array[UInt32, 80](fill=0)

    # Break chunk into sixteen 4-byte big-endian words w[i]
    for i in range(16):
        # Convert 4 bytes to UInt32 (big-endian)
        var value: UInt32 = 0
        value |= UInt32(chunk[i * 4]) << 24
        value |= UInt32(chunk[i * 4 + 1]) << 16
        value |= UInt32(chunk[i * 4 + 2]) << 8
        value |= UInt32(chunk[i * 4 + 3])
        w[i] = value

    # Extend the sixteen 4-byte words into eighty 4-byte words
    for i in range(16, 80):
        w[i] = _left_rotate(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)

    # Initialize hash value for this chunk
    var a = h0
    var b = h1
    var c = h2
    var d = h3
    var e = h4

    var f: UInt32
    var k: UInt32
    var temp: UInt32

    for i in range(80):
        if i < 20:
            # Use alternative 1 for f from FIPS PB 180-1 to avoid bitwise not
            f = d ^ (b & (c ^ d))
            k = 0x5A827999
        elif i < 40:
            f = b ^ c ^ d
            k = 0x6ED9EBA1
        elif i < 60:
            f = (b & c) | (b & d) | (c & d)
            k = 0x8F1BBCDC
        else:
            f = b ^ c ^ d
            k = 0xCA62C1D6

        temp = _left_rotate(a, 5) + f + e + k + w[i]
        e = d
        d = c
        c = _left_rotate(b, 30)
        b = a
        a = temp

    # Add this chunk's hash to result so far
    var new_h0 = h0 + a
    var new_h1 = h1 + b
    var new_h2 = h2 + c
    var new_h3 = h3 + d
    var new_h4 = h4 + e

    return (new_h0, new_h1, new_h2, new_h3, new_h4)


struct Sha1Hash(Copyable, Movable):
    """A struct that implements the SHA-1 algorithm."""

    var _h0: UInt32
    var _h1: UInt32
    var _h2: UInt32
    var _h3: UInt32
    var _h4: UInt32
    var _unprocessed: Bytes
    var _message_byte_length: UInt64

    def __init__(out self):
        """Initialize a new SHA1 hash object."""
        # Initial digest variables
        self._h0 = 0x67452301
        self._h1 = 0xEFCDAB89
        self._h2 = 0x98BADCFE
        self._h3 = 0x10325476
        self._h4 = 0xC3D2E1F0

        # List with 0 <= len < 64 used to store the end of the message
        # if the message length is not congruent to 64
        self._unprocessed = Bytes()

        # Length in bytes of all data that has been processed so far
        self._message_byte_length = 0

    def update(mut self, data: String) raises -> None:
        """Update the current digest with string data."""
        var bytes = List[UInt8]()
        for i in range(data.byte_length()):
            bytes.append(data.as_bytes()[i])

        self._update(bytes)

    def update_bytes(mut self, data: Bytes) raises -> None:
        """Update the current digest with bytes data."""
        var bytes = List[UInt8]()
        for i in range(len(data)):
            bytes.append(UInt8(data[i]))

        self._update(bytes)

    def _update(mut self, data: List[UInt8]) raises -> None:
        """Internal update function that processes raw byte data."""
        var offset: Int = 0
        var data_len = len(data)

        # Try to build a chunk out of the unprocessed data, if any
        var chunk_size = 64 - len(self._unprocessed)
        if chunk_size > data_len:
            chunk_size = data_len

        # Add data to unprocessed
        for i in range(chunk_size):
            self._unprocessed.append(data[offset + i])

        offset += chunk_size

        # Process the full chunks
        while len(self._unprocessed) >= 64:
            var chunk = Bytes(capacity=64)
            for i in range(64):
                chunk.append(self._unprocessed[i])

            var result = _process_chunk(
                chunk, self._h0, self._h1, self._h2, self._h3, self._h4
            )
            self._h0 = result[0]
            self._h1 = result[1]
            self._h2 = result[2]
            self._h3 = result[3]
            self._h4 = result[4]

            self._message_byte_length += 64

            # Remove the processed chunk
            var new_unprocessed = Bytes(capacity=len(self._unprocessed) - 64)
            for i in range(64, len(self._unprocessed)):
                new_unprocessed.append(self._unprocessed[i])
            self._unprocessed = new_unprocessed.copy()

            # Read more data if available
            chunk_size = 64
            if offset + chunk_size > data_len:
                chunk_size = data_len - offset

            # Add more data to unprocessed
            for i in range(chunk_size):
                self._unprocessed.append(data[offset + i])

            offset += chunk_size

    def digest(self) -> Bytes:
        """Produce the final hash value (big-endian) as a Bytes object."""
        var h = self._produce_digest()
        var result = Bytes(capacity=20)

        # Pack UInt32 values into bytes (big-endian)
        for i in range(5):
            var value: UInt32
            if i == 0:
                value = h[0]
            elif i == 1:
                value = h[1]
            elif i == 2:
                value = h[2]
            elif i == 3:
                value = h[3]
            else:
                value = h[4]

            result.append(Byte((value >> 24) & 0xFF))
            result.append(Byte((value >> 16) & 0xFF))
            result.append(Byte((value >> 8) & 0xFF))
            result.append(Byte(value & 0xFF))

        return result.copy()

    def hexdigest(self) -> String:
        """Produce the final hash value (big-endian) as a hex string."""
        var h = self._produce_digest()
        var result = Bytes(capacity=20)

        for i in range(5):
            var value: UInt32
            if i == 0:
                value = h[0]
            elif i == 1:
                value = h[1]
            elif i == 2:
                value = h[2]
            elif i == 3:
                value = h[3]
            else:
                value = h[4]

            # Format each UInt32 as a 8-character hex string
            for shift in range(7, -1, -1):
                var nibble = Int((value >> UInt32(shift * 4)) & 0xF)
                if nibble < 10:
                    result.append(Byte(48 + nibble))  # 0-9
                else:
                    result.append(Byte(97 + (nibble - 10)))  # a-f

        return bytes_to_str(result)

    def _produce_digest(self) -> Tuple[UInt32, UInt32, UInt32, UInt32, UInt32]:
        """Return finalized digest variables for the data processed so far."""
        # Pre-processing:
        var message = Bytes(capacity=len(self._unprocessed))

        # Copy unprocessed data
        for i in range(len(self._unprocessed)):
            message.append(self._unprocessed[i])

        var message_byte_length = self._message_byte_length + UInt64(
            len(self._unprocessed)
        )

        # append the bit '1' to the message
        message.append(0x80)

        # append 0 <= k < 512 bits '0', so that the resulting message length (in bytes)
        # is congruent to 56 (mod 64)
        var padding_length = (56 - ((message_byte_length + 1) % 64)) % 64
        for _ in range(padding_length):
            message.append(0)

        # append length of message (before pre-processing), in bits, as 64-bit big-endian integer
        var message_bit_length = message_byte_length * 8

        # Add 8 bytes as big-endian UInt64
        message.append(UInt8((message_bit_length >> 56) & 0xFF))
        message.append(UInt8((message_bit_length >> 48) & 0xFF))
        message.append(UInt8((message_bit_length >> 40) & 0xFF))
        message.append(UInt8((message_bit_length >> 32) & 0xFF))
        message.append(UInt8((message_bit_length >> 24) & 0xFF))
        message.append(UInt8((message_bit_length >> 16) & 0xFF))
        message.append(UInt8((message_bit_length >> 8) & 0xFF))
        message.append(UInt8(message_bit_length & 0xFF))

        # Process the final chunk(s)
        # At this point, the length of the message is either 64 or 128 bytes.
        var first_chunk = Bytes(capacity=64)
        for i in range(min(64, len(message))):
            first_chunk.append(message[i])

        var h = _process_chunk(
            first_chunk, self._h0, self._h1, self._h2, self._h3, self._h4
        )

        if len(message) > 64:  # handle second chunk if needed
            var second_chunk = Bytes()
            for i in range(64, len(message)):
                second_chunk.append(message[i])

            h = _process_chunk(second_chunk, h[0], h[1], h[2], h[3], h[4])

        return h


def sha1_string(input: String) raises -> String:
    """SHA-1 Hashing Function for String input.

    Args:
        input: A String to hash.

    Returns:
        A hex SHA-1 digest of the input string.
    """
    var hasher = Sha1Hash()
    hasher.update(input)
    return hasher.hexdigest()


def sha1_digest_string(input: String) raises -> Bytes:
    """SHA-1 Hashing Function for String input that returns raw bytes.

    Args:
        input: A String to hash.

    Returns:
        A raw 20-byte SHA-1 digest of the input string.
    """
    var hasher = Sha1Hash()
    hasher.update(input)
    return hasher.digest()
