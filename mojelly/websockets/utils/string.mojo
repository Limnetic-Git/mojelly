# This code is taken from a publicly available repository distributed under the terms of the MIT license:
# https://github.com/msaelices/mojo-websockets/blob/main/LICENSE
from std.collections import Span
from std.collections.string import StringSpan
from mojelly.websockets.aliases import Bytes, DEFAULT_BUFFER_SIZE
from mojelly.websockets.utils.bytes import byte, bytes_to_str

comptime SLASH = "/"
comptime HTTP = "http"
comptime HTTPS = "https"
comptime HTTP11 = "HTTP/1.1"
comptime HTTP10 = "HTTP/1.0"
comptime WS = "ws"
comptime WSS = "wss"
comptime R_CHAR = "\r"
comptime N_CHAR = "\n"
comptime LINE_BREAK = "\r\n"
comptime COLON_CHAR = ":"
comptime EMPTY_STRING = ""
comptime WHITESPACE = " "
comptime WHITESPACE_byte = Byte(32)
comptime TAB = "\t"
comptime EndOfReaderError = "No more bytes to read"
comptime OutOfBoundsError = "Read exceeds buffer bounds"


struct BytesConstant:
    comptime WHITESPACE = Byte(32)
    comptime COLON = Byte(58)
    comptime R_CHAR = Byte(13)
    comptime N_CHAR = Byte(10)


@fieldwise_init
struct CharSet(Copyable, Movable):
    var value: String
    comptime utf8 = CharSet("utf-8")


@fieldwise_init
struct MediaType(Copyable, Movable):
    var value: String
    comptime empty = MediaType("")
    comptime plain = MediaType("text/plain")
    comptime json = MediaType("application/json")


@fieldwise_init
struct Message(Copyable, Movable):
    var type: String
    comptime empty = Message("")
    comptime http_start = Message("http.response.start")


struct ByteWriter(Movable, Writer):
    # Writer in Mojo 1.1 accepts text through write_string
    var _inner: Bytes

    def __init__(out self, capacity: Int = DEFAULT_BUFFER_SIZE):
        self._inner = Bytes(capacity=capacity)

    def write_string(mut self, string: StringSpan):
        self._inner.extend(string.as_bytes())

    def write_bytes(mut self, data: Span[Byte, _]):
        self._inner.extend(data)

    def write[*Ts: Writable](mut self, *args: *Ts):
        comptime for i in range(len(Ts)):
            args[i].write_to(self)

    def consuming_write(mut self, var data: Bytes):
        self._inner.extend(data[:])

    def consuming_write(mut self, var string: String):
        self._inner.extend(string.as_bytes())

    def write_byte(mut self, value: Byte):
        self._inner.append(value)

    def consume(mut self) -> Bytes:
        var result = self._inner^
        self._inner = Bytes()
        return result^


struct ByteReader(Movable, Sized):
    # Owning a copy prevents dangling references when methods return slices
    var _inner: Bytes
    var read_pos: Int

    def __init__(out self, data: Span[Byte, _]):
        self._inner = Bytes(data)
        self.read_pos = 0

    def __init__(out self, data: Bytes):
        self._inner = data.copy()
        self.read_pos = 0

    def available(self) -> Bool:
        return self.read_pos < len(self._inner)

    def __len__(self) -> Int:
        return len(self._inner) - self.read_pos

    def peek(self) raises -> Byte:
        if not self.available():
            raise Error(EndOfReaderError)
        return self._inner[self.read_pos]

    def read_bytes(mut self, n: Int = -1) raises -> Bytes:
        var count = len(self) if n == -1 else n
        if count < 0 or count > len(self):
            raise Error(OutOfBoundsError)
        var result = Bytes(self._inner[self.read_pos : self.read_pos + count])
        self.read_pos += count
        return result^

    def read_until(mut self, char: Byte) -> Bytes:
        var start = self.read_pos
        while self.available() and self._inner[self.read_pos] != char:
            self.read_pos += 1
        return Bytes(self._inner[start : self.read_pos])

    def read_word(mut self) -> Bytes:
        return self.read_until(BytesConstant.WHITESPACE)

    def read_line(mut self) -> Bytes:
        var start = self.read_pos
        while self.available() and not is_newline(self._inner[self.read_pos]):
            self.read_pos += 1
        var result = Bytes(self._inner[start : self.read_pos])
        if self.available() and self._inner[self.read_pos] == 13:
            self.read_pos += 1
        if self.available() and self._inner[self.read_pos] == 10:
            self.read_pos += 1
        return result^

    def skip_WHITESPACE(mut self):
        while self.available() and is_space(self._inner[self.read_pos]):
            self.read_pos += 1

    def skip_carriage_return(mut self):
        while self.available() and is_newline(self._inner[self.read_pos]):
            self.read_pos += 1

    def increment(mut self, count: Int = 1):
        self.read_pos = min(len(self._inner), self.read_pos + count)

    def consume(var self, bytes_len: Int = -1) -> Bytes:
        var count = len(self) if bytes_len < 0 else min(bytes_len, len(self))
        return Bytes(self._inner[self.read_pos : self.read_pos + count])


def to_string[T: Writable](mut writer: T) -> String:
    return String(writer)


def to_string(data: Span[UInt8, _]) -> String:
    return String(from_utf8_lossy=data)


def to_string(data: Bytes) -> String:
    return bytes_to_str(data)


def compare_case_insensitive(a: Bytes, b: Bytes) -> Bool:
    return bytes_to_str(a).lower() == bytes_to_str(b).lower()


def is_newline(value: Byte) -> Bool:
    return value == 10 or value == 13


def is_space(value: Byte) -> Bool:
    return value == 32 or value == 9
