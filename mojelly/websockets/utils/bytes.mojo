# This code is taken from a publicly available repository distributed under the terms of the MIT license:
# https://github.com/msaelices/mojo-websockets/blob/main/LICENSE
"""Преобразование сетевых целых чисел, UTF-8 и двоичных буферов"""

from std.collections import Span
from std.ffi import external_call
from std.memory import Pointer
from std.sys import CompilationTarget, size_of
from std.os import abort
from std.sys.info import is_big_endian
from mojelly.websockets.aliases import Bytes

comptime MODIFIERS = (">", "<", "!", "=")
comptime EOL = Byte(10)


def byte(s: String) -> Byte:
    """Возвращает первый байт ASCII-разделителя"""
    return s.as_bytes()[0]


def bytes(s: String) -> Bytes:
    return str_to_bytes(s)


def str_to_bytes(s: String) -> Bytes:
    """Копирует все байты UTF-8, сохраняя многобайтовые символы"""
    return Bytes(s.as_bytes())


def bytes_to_str(data: Bytes) -> String:
    """Преобразует байты в строку с заменой некорректных последовательностей UTF-8
    """
    return String(from_utf8_lossy=data[:])


def int_from_bytes[
    dtype: DType, big_endian: Bool = False
](data: Span[Byte, _]) raises -> Int:
    """Читает целое без приведения указателя и требований к выравниванию"""
    comptime width = size_of[Scalar[dtype]]()
    if len(data) != width:
        raise Error("Integer buffer has an invalid length")
    var value = UInt64(0)
    for i in range(width):
        var index = i if big_endian else width - i - 1
        value = (value << 8) | UInt64(data[index])
    return Int(Scalar[dtype](value))


def int_as_bytes[
    dtype: DType, big_endian: Bool = False
](value: Scalar[dtype]) -> Bytes:
    """Записывает целое в указанном порядке байтов"""
    comptime width = size_of[Scalar[dtype]]()
    var result = Bytes(length=width, fill=0)
    var remaining = UInt64(value)
    for i in range(width):
        var index = width - i - 1 if big_endian else i
        result[index] = Byte(remaining & 255)
        remaining >>= 8
    return result^


def _format_width(code: Byte) raises -> Int:
    if code == 98 or code == 66:
        return 1
    if code == 104 or code == 72:
        return 2
    if code == 105 or code == 73 or code == 108 or code == 76:
        return 4
    if code == 113 or code == 81:
        return 8
    raise Error("Unsupported integer format")


def unpack(format: String, buffer: Bytes) raises -> List[Int]:
    """Декодирует поддерживаемые целочисленные форматы Python struct"""
    var codes = format.as_bytes()
    var big_endian = is_big_endian()
    var start = 0
    if len(codes) > 0:
        if codes[0] == 62 or codes[0] == 33:
            big_endian = True
            start = 1
        elif codes[0] == 60 or codes[0] == 61:
            big_endian = False if codes[0] == 60 else is_big_endian()
            start = 1
    var values = List[Int]()
    var offset = 0
    for i in range(start, len(codes)):
        var width = _format_width(codes[i])
        if offset + width > len(buffer):
            raise Error("Integer buffer is truncated")
        var value = UInt64(0)
        for j in range(width):
            var index = offset + (j if big_endian else width - j - 1)
            value = (value << 8) | UInt64(buffer[index])
        var decoded = Int(value)
        if (
            codes[i] == 98
            or codes[i] == 104
            or codes[i] == 105
            or codes[i] == 108
            or codes[i] == 113
        ):
            if width < 8 and value & (UInt64(1) << UInt64(width * 8 - 1)) != 0:
                decoded -= Int(UInt64(1) << UInt64(width * 8))
        values.append(decoded)
        offset += width
    if offset != len(buffer):
        raise Error("Integer buffer has trailing bytes")
    return values^


def pack[format: String](*values: Int) raises -> Bytes:
    """Кодирует целые числа, проверяя число аргументов и порядок байтов"""
    var codes = format.as_bytes()
    var big_endian = is_big_endian()
    var start = 0
    if len(codes) > 0:
        if codes[0] == 62 or codes[0] == 33:
            big_endian = True
            start = 1
        elif codes[0] == 60 or codes[0] == 61:
            big_endian = False if codes[0] == 60 else is_big_endian()
            start = 1
    if len(values) != len(codes) - start:
        raise Error("Integer format and argument count differ")
    var result = Bytes()
    for i in range(start, len(codes)):
        var width = _format_width(codes[i])
        var value = UInt64(values[i - start])
        for j in range(width):
            var shift = (width - j - 1 if big_endian else j) * 8
            result.append(Byte((value >> UInt64(shift)) & 255))
    return result^


struct ByteReader(Movable):
    """Хранит собственную копию буфера без неотслеживаемого заимствования"""

    var buffer: Bytes
    var index: Int

    def __init__(out self, buffer: Bytes):
        self.buffer = buffer.copy()
        self.index = 0

    def read[dtype: DType](mut self, order: String) raises -> Scalar[dtype]:
        return self._next[dtype](order)

    def _next[dtype: DType](mut self, order: String) raises -> Scalar[dtype]:
        comptime width = size_of[Scalar[dtype]]()
        if self.index + width > len(self.buffer):
            raise Error("Integer buffer is truncated")
        var data = self.buffer[self.index : self.index + width]
        self.index += width
        if order == ">" or order == "!":
            return Scalar[dtype](int_from_bytes[dtype, True](data))
        return Scalar[dtype](int_from_bytes[dtype, False](data))


def gen_token(length: Int) -> Bytes:
    """Получает случайные байты ОС для ключей handshake и масок клиента"""
    var result = Bytes(length=length, fill=0)
    comptime if CompilationTarget.is_linux():
        var offset = 0
        while offset < length:
            var count = external_call["getrandom", Int](
                result.unsafe_ptr().unsafe_offset(offset),
                length - offset,
                UInt32(0),
            )
            if count < 0:
                var error_number = external_call[
                    "__errno_location", Pointer[Int32, MutUntrackedOrigin]
                ]()[]
                if error_number == 4:
                    continue
                abort("getrandom failed")
            if count == 0:
                abort("getrandom returned no data")
            offset += count
    else:
        external_call["arc4random_buf", NoneType](result.unsafe_ptr(), length)
    return result^


def gen_mask() -> Bytes:
    return gen_token(4)


def decode_base64[validate: Bool = False](encoded: String) raises -> Bytes:
    """Декодирует base64 в двоичный буфер, не интерпретируя его как UTF-8"""
    var data = encoded.as_bytes()
    if len(data) % 4 != 0:
        raise Error("Invalid base64 length")
    var result = Bytes()
    var alphabet = String(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    )
    var padding = False
    var accumulator = UInt32(0)
    var bits = 0
    for i in range(len(data)):
        if data[i] == 61:
            padding = True
            continue
        if padding:
            raise Error("Invalid base64 padding")
        var digit = -1
        for j in range(64):
            if data[i] == alphabet.as_bytes()[j]:
                digit = j
                break
        if digit < 0:
            raise Error("Invalid base64 character")
        accumulator = (accumulator << 6) | UInt32(digit)
        bits += 6
        if bits >= 8:
            bits -= 8
            result.append(Byte((accumulator >> UInt32(bits)) & 255))
    if bits > 0 and accumulator & ((UInt32(1) << UInt32(bits)) - 1) != 0:
        raise Error("Invalid base64 padding bits")
    if (bits == 4 and (len(data) < 2 or data[len(data) - 2] != 61)) or (
        bits == 2 and (len(data) < 1 or data[len(data) - 1] != 61)
    ):
        raise Error("Invalid base64 padding")
    return result^


def b64decode[validate: Bool = False](encoded: String) raises -> Bytes:
    return decode_base64[validate](encoded)


def bytes_equal(a: Bytes, b: Bytes) -> Bool:
    return a == b
