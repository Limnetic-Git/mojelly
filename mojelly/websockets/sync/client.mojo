# This code is taken from a publicly available repository distributed under the terms of the MIT license:
# https://github.com/msaelices/mojo-websockets/blob/main/LICENSE
from std.memory import Pointer
from mojelly.websockets.aliases import (
    Bytes,
    DEFAULT_BUFFER_SIZE,
    DEFAULT_MAX_REQUEST_BODY_SIZE,
)
from mojelly.websockets.frames import Frame
from mojelly.websockets.net import TCPAddr, TCPConnection
from mojelly.websockets.socket import Socket
from mojelly.websockets.protocol import OPEN
from mojelly.websockets.protocol.base import (
    receive_data,
    receive_eof,
    send_binary,
    send_continuation,
    send_text,
    send_close,
)
from mojelly.websockets.protocol.client import ClientProtocol
from mojelly.websockets.utils.bytes import str_to_bytes
from mojelly.websockets.utils.uri import URI


struct Client(Movable):
    var uri: URI
    var conn: TCPConnection
    var protocol: ClientProtocol

    def __init__(out self, uri: String) raises:
        self.uri = URI.parse(uri)
        if self.uri.is_wss():
            raise Error("wss requires a TLS transport")
        self.protocol = ClientProtocol(self.uri.copy())
        self.conn = TCPConnection(Socket[TCPAddr]())

    def __enter__(mut self) raises -> ClientSession[origin_of(self)]:
        self.conn.connect(self.uri.get_hostname(), self.uri.get_port())
        var request = self.protocol.connect()
        self.protocol.send_request(request)
        _ = self.conn.write(self.protocol.data_to_send())
        # The HTTP response may span multiple reads, including a split CRLF sequence
        while self.protocol.get_state() != OPEN:
            var buffer = Bytes(capacity=DEFAULT_BUFFER_SIZE)
            if self.conn.read(buffer) == 0:
                raise Error("EOF during WebSocket handshake")
            receive_data(self.protocol, buffer)
            if self.protocol.get_handshake_exc():
                raise self.protocol.get_handshake_exc().value()
        return ClientSession(Pointer(to=self))

    def __exit__(mut self) raises:
        self.close()

    def send_binary(mut self, message: Bytes) raises:
        send_binary(self.protocol, message)
        _ = self.conn.write(self.protocol.data_to_send())

    def send_text(mut self, message: String) raises:
        send_text(self.protocol, str_to_bytes(message))
        _ = self.conn.write(self.protocol.data_to_send())

    def send_continuation(mut self, message: Bytes, fin: Bool = False) raises:
        send_continuation(self.protocol, message, fin=fin)
        _ = self.conn.write(self.protocol.data_to_send())

    def recv(mut self) raises -> Bytes:
        var result = Bytes()
        while True:
            var complete = False
            var events = self.protocol.events_received()
            for event in events:
                if complete:
                    self.protocol.add_event(event.copy())
                elif event.isa[Frame]():
                    if event[Frame].is_data():
                        result.extend(event[Frame].data[:])
                        if len(result) > DEFAULT_MAX_REQUEST_BODY_SIZE:
                            raise Error("WebSocket message is too large")
                        complete = event[Frame].fin
                    elif event[Frame].opcode == 8:
                        _ = self.conn.write(self.protocol.data_to_send())
                        self.conn.close()
                        raise Error("EOF: WebSocket closed")
            var pending = self.protocol.data_to_send()
            if len(pending) > 0:
                _ = self.conn.write(pending)
            if complete:
                return result^
            if self.protocol.get_parser_exc():
                raise self.protocol.get_parser_exc().value()
            var buffer = Bytes(capacity=DEFAULT_BUFFER_SIZE)
            if self.conn.read(buffer) == 0:
                receive_eof(self.protocol)
                self.conn.close()
                raise Error("EOF: WebSocket closed")
            receive_data(self.protocol, buffer)

    def recv_text(mut self) raises -> String:
        var data = self.recv()
        return String(from_utf8=data[:])

    def close(mut self) raises:
        if not self.conn.is_closed():
            if self.protocol.get_state() == OPEN:
                send_close(self.protocol)
                _ = self.conn.write(self.protocol.data_to_send())
            self.conn.close()


def connect(uri: String) raises -> Client:
    return Client(uri)


@fieldwise_init
struct ClientSession[origin: MutOrigin](ImplicitlyCopyable):
    # The context owns Client, and the session holds a tracked borrow of that owner
    var pointer: Pointer[mut=True, Client, Self.origin]

    def send_text(self, message: String) raises:
        self.pointer[].send_text(message)

    def send_binary(self, message: Bytes) raises:
        self.pointer[].send_binary(message)

    def send_continuation(self, message: Bytes, fin: Bool = False) raises:
        self.pointer[].send_continuation(message, fin)

    def recv(self) raises -> Bytes:
        return self.pointer[].recv()

    def recv_text(self) raises -> String:
        return self.pointer[].recv_text()

    def close(self) raises:
        self.pointer[].close()
