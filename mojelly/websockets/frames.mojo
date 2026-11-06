# This code is taken from a publicly available repository distributed under the terms of the MIT license:
# https://github.com/msaelices/mojo-websockets/blob/main/LICENSE
# WebSocket frame definitions, opcodes, and close codes

from mojelly.websockets.aliases import (
    CPointer,
    Bytes,
    DEFAULT_MAX_REQUEST_BODY_SIZE,
)
from mojelly.websockets.utils.bytes import bytes_to_str
from std.bit import byte_swap
from std.collections import Dict, Optional
from std.collections.string import StringSpan
from std.memory import Pointer, bitcast, unsafe_memcmp
from std.sys.info import is_big_endian

from mojelly.websockets.streams import Streamable
from mojelly.websockets.utils.string import Bytes, ByteWriter
from mojelly.websockets.utils.bytes import (
    pack,
    unpack,
    int_as_bytes,
    int_from_bytes,
    gen_mask,
)


# Opcodes for WebSocket frames
struct OpCode(Copyable, Movable):
    """
    Opcodes for WebSocket frames.
    """

    comptime OP_CONT = 0x00
    comptime OP_TEXT = 0x01
    comptime OP_BINARY = 0x02
    comptime OP_CLOSE = 0x08
    comptime OP_PING = 0x09
    comptime OP_PONG = 0x0A


comptime DATA_OPCODES = (
    OpCode.OP_CONT,
    OpCode.OP_TEXT,
    OpCode.OP_BINARY,
)

comptime CTRL_OPCODES = (
    OpCode.OP_CLOSE,
    OpCode.OP_PING,
    OpCode.OP_PONG,
)


# Close codes
struct CloseCode(Copyable, Movable):
    """
    Close codes for WebSocket close frames.
    """

    comptime CLOSE_CODE_NORMAL_CLOSURE = 1000
    comptime CLOSE_CODE_GOING_AWAY = 1001
    comptime CLOSE_CODE_PROTOCOL_ERROR = 1002
    comptime CLOSE_CODE_UNSUPPORTED_DATA = 1003
    # 1004 is reserved
    comptime CLOSE_CODE_NO_STATUS_RCVD = 1005
    comptime CLOSE_CODE_ABNORMAL_CLOSURE = 1006
    comptime CLOSE_CODE_INVALID_DATA = 1007
    comptime CLOSE_CODE_POLICY_VIOLATION = 1008
    comptime CLOSE_CODE_MESSAGE_TOO_BIG = 1009
    comptime CLOSE_CODE_MANDATORY_EXTENSION = 1010
    comptime CLOSE_CODE_INTERNAL_ERROR = 1011
    comptime CLOSE_CODE_SERVICE_RESTART = 1012
    comptime CLOSE_CODE_TRY_AGAIN_LATER = 1013
    comptime CLOSE_CODE_BAD_GATEWAY = 1014
    comptime CLOSE_CODE_TLS_HANDSHAKE = 1015


# Close code that are allowed in a close frame.
comptime EXTERNAL_CLOSE_CODES = (
    CloseCode.CLOSE_CODE_NORMAL_CLOSURE,
    CloseCode.CLOSE_CODE_GOING_AWAY,
    CloseCode.CLOSE_CODE_PROTOCOL_ERROR,
    CloseCode.CLOSE_CODE_UNSUPPORTED_DATA,
    CloseCode.CLOSE_CODE_INVALID_DATA,
    CloseCode.CLOSE_CODE_POLICY_VIOLATION,
    CloseCode.CLOSE_CODE_MESSAGE_TOO_BIG,
    CloseCode.CLOSE_CODE_MANDATORY_EXTENSION,
    CloseCode.CLOSE_CODE_INTERNAL_ERROR,
    CloseCode.CLOSE_CODE_SERVICE_RESTART,
    CloseCode.CLOSE_CODE_TRY_AGAIN_LATER,
    CloseCode.CLOSE_CODE_BAD_GATEWAY,
)

# OK codes in a closed frame.
comptime OK_CLOSE_CODES = (
    CloseCode.CLOSE_CODE_NORMAL_CLOSURE,
    CloseCode.CLOSE_CODE_GOING_AWAY,
    CloseCode.CLOSE_CODE_NO_STATUS_RCVD,
)

comptime MAX_FRAME_OVERHEAD = 14  # FIN bit and opcode (1 byte) + length (1 or 3 or 9 bytes) + mask (4 bytes)


@inline(.always)
def get_op_code_name(code: Int) raises -> String:
    var name: String
    if code == OpCode.OP_CONT:
        name = "CONT"
    elif code == OpCode.OP_TEXT:
        name = "TEXT"
    elif code == OpCode.OP_BINARY:
        name = "BINARY"
    elif code == OpCode.OP_CLOSE:
        name = "CLOSE"
    elif code == OpCode.OP_PING:
        name = "PING"
    elif code == OpCode.OP_PONG:
        name = "PONG"
    else:
        name = "UNKNOWN"
    return name


@inline(.always)
def get_close_code_name(code: UInt16) raises -> String:
    var name: String
    if code == CloseCode.CLOSE_CODE_NORMAL_CLOSURE:
        name = "NORMAL_CLOSURE"
    elif code == CloseCode.CLOSE_CODE_GOING_AWAY:
        name = "GOING_AWAY"
    elif code == CloseCode.CLOSE_CODE_PROTOCOL_ERROR:
        name = "PROTOCOL_ERROR"
    elif code == CloseCode.CLOSE_CODE_UNSUPPORTED_DATA:
        name = "UNSUPPORTED_DATA"
    elif code == CloseCode.CLOSE_CODE_NO_STATUS_RCVD:
        name = "NO_STATUS_RCVD"
    elif code == CloseCode.CLOSE_CODE_ABNORMAL_CLOSURE:
        name = "ABNORMAL_CLOSURE"
    elif code == CloseCode.CLOSE_CODE_INVALID_DATA:
        name = "INVALID_DATA"
    elif code == CloseCode.CLOSE_CODE_POLICY_VIOLATION:
        name = "POLICY_VIOLATION"
    elif code == CloseCode.CLOSE_CODE_MESSAGE_TOO_BIG:
        name = "MESSAGE_TOO_BIG"
    elif code == CloseCode.CLOSE_CODE_MANDATORY_EXTENSION:
        name = "MANDATORY_EXTENSION"
    elif code == CloseCode.CLOSE_CODE_INTERNAL_ERROR:
        name = "INTERNAL_ERROR"
    elif code == CloseCode.CLOSE_CODE_SERVICE_RESTART:
        name = "SERVICE_RESTART"
    elif code == CloseCode.CLOSE_CODE_TRY_AGAIN_LATER:
        name = "TRY_AGAIN_LATER"
    elif code == CloseCode.CLOSE_CODE_BAD_GATEWAY:
        name = "BAD_GATEWAY"
    elif code == CloseCode.CLOSE_CODE_TLS_HANDSHAKE:
        name = "TLS_HANDSHAKE"
    else:
        name = "UNKNOWN"
    return name


@inline(.always)
def get_close_code_explanation(code: UInt16) raises -> String:
    var explanation: String
    if code == CloseCode.CLOSE_CODE_NORMAL_CLOSURE:
        explanation = "OK"
    elif code == CloseCode.CLOSE_CODE_GOING_AWAY:
        explanation = "going away"
    elif code == CloseCode.CLOSE_CODE_PROTOCOL_ERROR:
        explanation = "protocol error"
    elif code == CloseCode.CLOSE_CODE_UNSUPPORTED_DATA:
        explanation = "unsupported data"
    elif code == CloseCode.CLOSE_CODE_NO_STATUS_RCVD:
        explanation = "no status received [internal]"
    elif code == CloseCode.CLOSE_CODE_ABNORMAL_CLOSURE:
        explanation = "abnormal closure [internal]"
    elif code == CloseCode.CLOSE_CODE_INVALID_DATA:
        explanation = "invalid frame payload data"
    elif code == CloseCode.CLOSE_CODE_POLICY_VIOLATION:
        explanation = "policy violation"
    elif code == CloseCode.CLOSE_CODE_MESSAGE_TOO_BIG:
        explanation = "message too big"
    elif code == CloseCode.CLOSE_CODE_MANDATORY_EXTENSION:
        explanation = "mandatory extension"
    elif code == CloseCode.CLOSE_CODE_INTERNAL_ERROR:
        explanation = "internal error"
    elif code == CloseCode.CLOSE_CODE_SERVICE_RESTART:
        explanation = "service restart"
    elif code == CloseCode.CLOSE_CODE_TRY_AGAIN_LATER:
        explanation = "try again later"
    elif code == CloseCode.CLOSE_CODE_BAD_GATEWAY:
        explanation = "bad gateway"
    elif code == CloseCode.CLOSE_CODE_TLS_HANDSHAKE:
        explanation = "TLS handshake failure [internal]"
    else:
        explanation = "unknown"
    return explanation


def apply_mask(data: Bytes, mask: Bytes) raises -> Bytes:
    # Repeat the mask every four bytes without allocating an intermediate buffer
    if len(mask) != 4:
        raise Error("A WebSocket mask must contain four bytes")
    var result = Bytes(capacity=len(data))
    for i in range(len(data)):
        result.append(data[i] ^ mask[i % 4])
    return result^


struct Frame(Copyable, Equatable, Movable, Writable):
    var opcode: Int
    var data: Bytes
    var fin: Bool
    var rsv1: Bool
    var rsv2: Bool
    var rsv3: Bool

    def __init__(
        out self,
        opcode: Int,
        data: Bytes,
        fin: Bool = True,
        rsv1: Bool = False,
        rsv2: Bool = False,
        rsv3: Bool = False,
    ):
        self.opcode = opcode
        self.data = data.copy()
        self.fin = fin
        self.rsv1 = rsv1
        self.rsv2 = rsv2
        self.rsv3 = rsv3

    def __eq__(self, other: Self) -> Bool:
        return (
            self.opcode == other.opcode
            and self.data == other.data
            and self.fin == other.fin
            and self.rsv1 == other.rsv1
            and self.rsv2 == other.rsv2
            and self.rsv3 == other.rsv3
        )

    def __ne__(self, other: Self) -> Bool:
        return not self == other

    def __str__(self) -> String:
        return String(self)

    def write_to[W: Writer](self, mut writer: W):
        writer.write(
            "Frame(opcode=",
            self.opcode,
            ", bytes=",
            len(self.data),
            ", fin=",
            self.fin,
            ")",
        )

    def write_repr_to[W: Writer](self, mut writer: W):
        self.write_to(writer)

    def _data_as_text(self) -> String:
        return bytes_to_str(self.data)

    def _data_as_binary(self) -> String:
        var result = String()
        for value in self.data:
            result.write(hex(value), " ")
        return result

    def check(self) raises:
        # Check RFC 6455 constraints before writing a frame or delivering it to the application
        if self.rsv1 or self.rsv2 or self.rsv3:
            raise Error("ProtocolError: reserved bits must be zero")
        if self.opcode not in DATA_OPCODES and self.opcode not in CTRL_OPCODES:
            raise Error("ProtocolError: invalid opcode")
        if self.opcode in CTRL_OPCODES:
            if len(self.data) > 125 or not self.fin:
                raise Error("ProtocolError: invalid control frame")

    def is_data(self) -> Bool:
        return self.opcode in DATA_OPCODES

    def serialize[
        gen_mask_func: def() thin -> Bytes = gen_mask
    ](self, *, mask: Bool) raises -> Bytes:
        self.check()
        var length = len(self.data)
        var output = Bytes(capacity=length + MAX_FRAME_OVERHEAD)
        var first = self.opcode | (128 if self.fin else 0)
        output.append(Byte(first))
        var second = 128 if mask else 0
        if length < 126:
            output.append(Byte(second | length))
        elif length < 65536:
            output.append(Byte(second | 126))
            var encoded = int_as_bytes[DType.uint16, True](UInt16(length))
            output.extend(encoded[:])
        else:
            output.append(Byte(second | 127))
            var encoded = int_as_bytes[DType.uint64, True](UInt64(length))
            output.extend(encoded[:])

        # The client adds a random mask, while the server sends the original payload
        if mask:
            var key = gen_mask_func()
            if len(key) != 4:
                raise Error("A WebSocket mask must contain four bytes")
            output.extend(key[:])
            var masked = apply_mask(self.data, key)
            output.extend(masked[:])
        else:
            output.extend(self.data[:])
        return output^

    @staticmethod
    def parse[
        T: Streamable
    ](stream_ptr: Pointer[mut=True, T, _], *, mask: Bool) raises -> Optional[
        Frame
    ]:
        # Save the position so an incomplete TCP packet does not consume part of a frame
        var start = stream_ptr[].position()
        var header = stream_ptr[].read_exact(2)
        if not header:
            return None
        var head1 = Int(header.value()[0])
        var head2 = Int(header.value()[1])
        if ((head2 & 128) != 0) != mask:
            raise Error("ProtocolError: incorrect masking")
        var length = head2 & 127
        if length >= 126:
            var width = 2 if length == 126 else 8
            var extended = stream_ptr[].read_exact(width)
            if not extended:
                stream_ptr[].restore(start)
                return None
            var value = UInt64(0)
            for byte in extended.value():
                value = (value << 8) | UInt64(byte)
            if value > UInt64(DEFAULT_MAX_REQUEST_BODY_SIZE):
                raise Error("PayloadTooBig")
            if (width == 2 and value < 126) or (width == 8 and value < 65536):
                raise Error("ProtocolError: non-minimal payload length")
            length = Int(value)
        var key = Bytes()
        if mask:
            var optional_key = stream_ptr[].read_exact(4)
            if not optional_key:
                stream_ptr[].restore(start)
                return None
            key = optional_key.value().copy()
        var payload = stream_ptr[].read_exact(length)
        if not payload:
            stream_ptr[].restore(start)
            return None
        var data = payload.value().copy()
        if mask:
            data = apply_mask(data, key)
        var frame = Frame(
            head1 & 15,
            data,
            (head1 & 128) != 0,
            (head1 & 64) != 0,
            (head1 & 32) != 0,
            (head1 & 16) != 0,
        )
        frame.check()
        return frame^


@fieldwise_init
struct Close(Copyable, Movable, Writable):
    var code: UInt16
    var reason: String

    def __str__(self) -> String:
        return String(self)

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.code, " ", self.reason)

    @staticmethod
    def parse(data: Bytes) raises -> Close:
        if len(data) == 0:
            return Close(UInt16(CloseCode.CLOSE_CODE_NO_STATUS_RCVD), "")
        if len(data) == 1:
            raise Error("ProtocolError: close frame too short")
        var code = UInt16(data[0]) * 256 + UInt16(data[1])
        var reason = String(from_utf8=data[2:])
        var close = Close(UInt16(code), reason)
        close.check()
        return close^

    def serialize(self) raises -> Bytes:
        self.check()
        var result = int_as_bytes[DType.uint16, True](self.code)
        result.extend(self.reason.as_bytes())
        return result^

    def check(self) raises:
        var code = Int(self.code)
        if code not in EXTERNAL_CLOSE_CODES and not (3000 <= code < 5000):
            raise Error("ProtocolError: invalid status code")
        if self.reason.byte_length() > 123:
            raise Error("ProtocolError: close reason is too long")
