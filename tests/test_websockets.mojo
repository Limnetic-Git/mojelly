from std.testing import assert_equal, assert_true, assert_false
from std.memory import Pointer
from mojelly.websockets.aliases import Bytes, CPointer
from mojelly.websockets.frames import Frame, Close, OpCode
from mojelly.websockets.streams import StreamReader
from mojelly.websockets.utils.bytes import (
    str_to_bytes,
    bytes_to_str,
    gen_mask,
    pack,
    unpack,
    b64decode,
)
from mojelly.websockets.utils.sha1 import sha1_string
from mojelly.websockets.utils.handshake import ws_accept_key
from mojelly.websockets.utils.uri import URI
from mojelly.websockets.utils.uuid import UUIDGenerator
from mojelly.websockets.utils.time import now
from mojelly.websockets.sync.server import serve, WSConnection
from std.collections import Span
from mojelly.websockets.protocol import OPEN
from mojelly.websockets.protocol.client import ClientProtocol
from mojelly.websockets.protocol.server import ServerProtocol
from mojelly.websockets.protocol.base import (
    receive_data,
    send_text,
    send_binary,
    send_close,
)
from mojelly.websockets.http import HTTPRequest


def no_op(mut conn: WSConnection, data: Span[Byte, _]) raises:
    pass


def main() raises:
    with serve[no_op]("127.0.0.1", 0)^ as server:
        assert_equal(server.address(), "127.0.0.1:0")
    assert_equal(sha1_string(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    assert_equal(sha1_string("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
    assert_equal(
        ws_accept_key("dGhlIHNhbXBsZSBub25jZQ=="),
        "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
    )
    assert_equal(bytes_to_str(str_to_bytes("Привет 🌍")), "Привет 🌍")
    var packed = pack["!BBH"](1, 255, 65535)
    var decoded = unpack("!BBH", packed)
    assert_equal(decoded[2], 65535)
    assert_equal(len(b64decode[True]("AAEC/w==")), 4)
    assert_equal(len(gen_mask()), 4)
    var uri = URI.parse("ws://localhost:8080/echo?q=test")
    assert_equal(uri.get_hostname(), "localhost")
    assert_equal(uri.get_port(), 8080)
    assert_equal(uri.get_path(), "/echo?q=test")
    var uuid = UUIDGenerator(42)
    assert_equal(String(uuid.next()).byte_length(), 36)
    assert_true(now(utc=True).year >= 2026)
    for masked in [False, True]:
        for size in [0, 5, 125, 126, 65536]:
            var payload = Bytes(length=size, fill=42)
            var frame = Frame(OpCode.OP_BINARY, payload)
            var wire = frame.serialize(mask=masked)
            var reader = StreamReader()
            var ptr = Pointer(to=reader)
            var split = len(wire) // 2
            reader.feed_data(Bytes(wire[:split]))
            var partial = Frame.parse(ptr, mask=masked)
            assert_false(Bool(partial))
            assert_equal(reader.offset, 0)
            reader.feed_data(Bytes(wire[split:]))
            var parsed = Frame.parse(ptr, mask=masked)
            assert_true(Bool(parsed))
            assert_true(parsed.value() == frame)
    var client = ClientProtocol(
        URI.parse("ws://localhost:8080/echo"), key="dGhlIHNhbXBsZSBub25jZQ=="
    )
    var server = ServerProtocol()
    var request = client.connect()
    client.send_request(request)
    var request_bytes = client.data_to_send()
    for value in request_bytes:
        receive_data(server, Bytes(length=1, fill=value))
    var events = server.events_received()
    assert_equal(len(events), 1)
    var response = server.accept(events[0][HTTPRequest])
    server.send_response(response)
    var response_bytes = server.data_to_send()
    for value in response_bytes:
        receive_data(client, Bytes(length=1, fill=value))
    assert_equal(server.get_state(), OPEN)
    assert_equal(client.get_state(), OPEN)
    send_text(client, str_to_bytes("Привет"))
    var wire = client.data_to_send()
    for value in wire:
        receive_data(server, Bytes(length=1, fill=value))
    var messages = server.events_received()
    assert_equal(len(messages), 1)
    assert_equal(bytes_to_str(messages[0][Frame].data), "Привет")
    print("WebSocket Mojo 1.1 tests passed")
