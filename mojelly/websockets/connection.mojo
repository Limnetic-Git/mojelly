"""WebSocket message callbacks driven by Mojelly's HTTP event loop."""

from mojelly.http.request import HTTPRequest
from mojelly.websockets.aliases import Bytes, DEFAULT_MAX_REQUEST_BODY_SIZE
from mojelly.websockets.frames import OpCode
from mojelly.websockets.protocol import OPEN
from mojelly.websockets.protocol.base import (
    send_text,
    send_binary,
    send_ping,
    send_close,
)
from mojelly.websockets.protocol.server import ServerProtocol
from mojelly.websockets.utils.bytes import str_to_bytes


struct WebSocket(Movable):
    """One upgraded connection, borrowed only for the duration of a callback.

    Messages are delivered after reassembly. Sends queue frames on the owning
    libuv worker; callbacks must return promptly and must not retain this value.
    The original HTTP request exposes headers, cookies, query and path params.
    """

    var request: HTTPRequest
    var protocol: ServerProtocol
    var message: Bytes
    var message_opcode: Int

    def __init__(
        out self,
        var request: HTTPRequest,
        max_size: Int = DEFAULT_MAX_REQUEST_BODY_SIZE,
        max_header_size: Int = 65536,
    ):
        self.request = request^
        self.protocol = ServerProtocol(
            max_size=max_size, max_header_size=max_header_size
        )
        self.message = Bytes()
        self.message_opcode = OpCode.OP_BINARY

    def is_text(self) -> Bool:
        return self.message_opcode == OpCode.OP_TEXT

    def send_text(mut self, message: String) raises:
        send_text(self.protocol, str_to_bytes(message))

    def send_binary(mut self, message: Bytes) raises:
        send_binary(self.protocol, message)

    def ping(mut self, data: Bytes = Bytes()) raises:
        send_ping(self.protocol, data)

    def close(mut self, code: Int = 1000, reason: String = "") raises:
        if self.protocol.get_state() == OPEN:
            send_close(self.protocol, code, reason)


comptime WebSocketHandler = def(mut WebSocket, Bytes) raises thin -> None
