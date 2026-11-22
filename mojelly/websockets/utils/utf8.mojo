"""Incrementally validate UTF-8 across WebSocket continuation frames.

The first byte restricts the next continuation byte for overlong encodings,
surrogates and code points above U+10FFFF. Ping and Pong do not touch this
state, and only the final data frame requires that no character is partial.
"""

from mojelly.websockets.aliases import Bytes


struct UTF8Validator(Copyable, Movable):
    # Preserve a partially received UTF-8 character across continuation frames.
    var remaining: Int
    var low: Int
    var high: Int

    def __init__(out self):
        self.remaining = 0
        self.low = 128
        self.high = 191

    def feed(mut self, data: Bytes, final: Bool) raises:
        for byte in data:
            var value = Int(byte)
            if self.remaining > 0:
                if value < self.low or value > self.high:
                    raise Error("InvalidUTF8")
                self.remaining -= 1
                self.low = 128
                self.high = 191
            elif value <= 127:
                pass
            elif 194 <= value <= 223:
                self.remaining = 1
            elif 224 <= value <= 239:
                self.remaining = 2
                self.low = 160 if value == 224 else 128
                self.high = 159 if value == 237 else 191
            elif 240 <= value <= 244:
                self.remaining = 3
                self.low = 144 if value == 240 else 128
                self.high = 143 if value == 244 else 191
            else:
                raise Error("InvalidUTF8")
        if final and self.remaining != 0:
            raise Error("InvalidUTF8")
