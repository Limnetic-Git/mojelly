"""A synchronous WebSocket client with bounded network operations.

The transport is nonblocking internally. This API waits for readiness with a
monotonic deadline and presents ordinary blocking send/receive operations.
"""
from std.collections import Optional
from std.memory import Pointer
from mojelly.websockets.aliases import Bytes, DEFAULT_MAX_REQUEST_BODY_SIZE
from mojelly.websockets.frames import Frame, OpCode
from mojelly.websockets.protocol import OPEN, CONNECTING, CLOSED
from mojelly.websockets.protocol.base import (
    receive_data,
    receive_eof,
    send_binary,
    send_continuation,
    send_text,
    send_close,
    send_ping,
)
from mojelly.websockets.protocol.client import ClientProtocol
from mojelly.websockets.transport import Transport, now_ms
from mojelly.websockets.utils.bytes import str_to_bytes
from mojelly.websockets.utils.uri import URI


struct Client(Movable):
    var uri: URI
    var conn: Transport
    var protocol: ClientProtocol
    var timeout_ms: Int
    var close_timeout_ms: Int
    var last_message_opcode: Int

    def __init__(
        out self,
        uri: String,
        max_size: Int = DEFAULT_MAX_REQUEST_BODY_SIZE,
        timeout_ms: Int = 30000,
        close_timeout_ms: Int = 5000,
        origin: Optional[String] = None,
    ) raises:
        if max_size < 1 or timeout_ms < 1 or close_timeout_ms < 1:
            raise Error("Invalid client limits")
        self.uri = URI.parse(uri)
        if self.uri.scheme != "ws" and self.uri.scheme != "wss":
            raise Error("Expected a ws:// or wss:// URI")
        if self.uri.is_wss():
            raise Error("wss requires a TLS transport; use a TLS reverse proxy")
        self.protocol = ClientProtocol(
            self.uri.copy(), origin=origin, max_size=max_size
        )
        self.conn = Transport()
        self.timeout_ms = timeout_ms
        self.close_timeout_ms = close_timeout_ms
        self.last_message_opcode = OpCode.OP_BINARY

    def __enter__(mut self) raises -> ClientSession[origin_of(self)]:
        try:
            self.conn.connect(
                self.uri.get_hostname(), self.uri.get_port(), self.timeout_ms
            )
            var request = self.protocol.connect()
            self.protocol.send_request(request)
            _ = self.conn.write(self.protocol.data_to_send(), self.timeout_ms)
            var deadline = now_ms() + self.timeout_ms
            while self.protocol.get_state() == CONNECTING:
                var buffer = Bytes()
                if self.conn.read(buffer, max(1, deadline - now_ms())) == 0:
                    raise Error("EOF during WebSocket handshake")
                receive_data(self.protocol, buffer)
                if (
                    now_ms() >= deadline
                    and self.protocol.get_state() == CONNECTING
                ):
                    raise Error("Handshake timeout")
                if self.protocol.get_handshake_exc():
                    raise self.protocol.get_handshake_exc().value()
        except error:
            self.abort()
            raise error
        return ClientSession(Pointer(to=self))

    def __exit__(mut self):
        # Cleanup must not replace an exception raised by the application body.
        try:
            self.close()
        except:
            self.abort()

    def _flush(mut self) raises:
        try:
            _ = self.conn.write(self.protocol.data_to_send(), self.timeout_ms)
        except error:
            self.abort()
            raise error

    def send_binary(mut self, message: Bytes) raises:
        send_binary(self.protocol, message)
        self._flush()

    def send_text(mut self, message: String) raises:
        send_text(self.protocol, str_to_bytes(message))
        self._flush()

    def send_continuation(mut self, message: Bytes, fin: Bool = False) raises:
        send_continuation(self.protocol, message, fin=fin)
        self._flush()

    def ping(mut self, data: Bytes = Bytes()) raises:
        send_ping(self.protocol, data)
        self._flush()

    def recv(mut self) raises -> Bytes:
        var result = Bytes()
        var deadline = now_ms() + self.timeout_ms
        while True:
            var complete = False
            var events = self.protocol.events_received()
            for event in events:
                if complete:
                    self.protocol.add_event(event.copy())
                elif event.isa[Frame]():
                    if event[Frame].is_data():
                        if event[Frame].opcode != OpCode.OP_CONT:
                            self.last_message_opcode = event[Frame].opcode
                        result.extend(event[Frame].data[:])
                        complete = event[Frame].fin
                    elif event[Frame].opcode == OpCode.OP_CLOSE:
                        self._flush()
                        self.conn.close()
                        self.protocol.set_state(CLOSED)
                        raise Error("EOF: WebSocket closed")
            # Ping and Close replies are generated even when no data is returned.
            self._flush()
            if complete:
                return result^
            if self.protocol.get_parser_exc():
                self.abort()
                raise self.protocol.get_parser_exc().value()
            if self.conn.is_closed():
                raise Error("EOF: WebSocket closed")
            var buffer = Bytes()
            try:
                if self.conn.read(buffer, max(1, deadline - now_ms())) == 0:
                    receive_eof(self.protocol)
                    self.conn.close()
                    raise Error("EOF: WebSocket closed")
                receive_data(self.protocol, buffer)
                if now_ms() >= deadline:
                    raise Error("Receive timeout")
            except error:
                self.abort()
                raise error

    def recv_text(mut self) raises -> String:
        var data = self.recv()
        if self.last_message_opcode != OpCode.OP_TEXT:
            raise Error("Expected a text message")
        return String(from_utf8=data[:])

    def close(mut self, code: Int = 1000, reason: String = "") raises:
        if self.conn.is_closed():
            return
        var deadline = now_ms() + self.close_timeout_ms
        try:
            if self.protocol.get_state() == OPEN:
                send_close(self.protocol, code, reason)
            _ = self.conn.write(
                self.protocol.data_to_send(), max(1, deadline - now_ms())
            )
            while (
                not self.protocol.get_close_rcvd()
                and self.protocol.get_state() != CLOSED
            ):
                var buffer = Bytes()
                if self.conn.read(buffer, max(1, deadline - now_ms())) == 0:
                    receive_eof(self.protocol)
                    break
                receive_data(self.protocol, buffer)
                _ = self.conn.write(
                    self.protocol.data_to_send(), max(1, deadline - now_ms())
                )
                if now_ms() >= deadline:
                    break
        finally:
            # Closing is bounded even if the peer never answers our Close frame.
            self.conn.close()
            self.protocol.set_state(CLOSED)

    def abort(mut self):
        self.conn.close()
        self.protocol.set_state(CLOSED)


def connect(uri: String) raises -> Client:
    return Client(uri)


@fieldwise_init
struct ClientSession[origin: MutOrigin](ImplicitlyCopyable):
    # A tracked borrow keeps the owning Client alive for the whole with block.
    var pointer: Pointer[mut=True, Client, Self.origin]

    def send_text(self, message: String) raises:
        self.pointer[].send_text(message)

    def send_binary(self, message: Bytes) raises:
        self.pointer[].send_binary(message)

    def send_continuation(self, message: Bytes, fin: Bool = False) raises:
        self.pointer[].send_continuation(message, fin)

    def ping(self, data: Bytes = Bytes()) raises:
        self.pointer[].ping(data)

    def recv(self) raises -> Bytes:
        return self.pointer[].recv()

    def recv_text(self) raises -> String:
        return self.pointer[].recv_text()

    def close(self, code: Int = 1000, reason: String = "") raises:
        self.pointer[].close(code, reason)
