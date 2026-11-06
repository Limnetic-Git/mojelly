# This code is taken from a publicly available repository distributed under the terms of the MIT license:
# https://github.com/msaelices/mojo-websockets/blob/main/LICENSE
from std.collections import Span
from std.memory import Pointer
from mojelly.websockets.aliases import (
    Bytes,
    DEFAULT_BUFFER_SIZE,
    DEFAULT_MAX_REQUEST_BODY_SIZE,
)
from mojelly.websockets.frames import Frame
from mojelly.websockets.http import HTTPRequest
from mojelly.websockets.net import ListenConfig, TCPConnection, TCPListener
from mojelly.websockets.protocol import CONNECTING, OPEN
from mojelly.websockets.protocol.base import (
    receive_data,
    receive_eof,
    send_text,
    send_binary,
)
from mojelly.websockets.protocol.server import ServerProtocol
from mojelly.websockets.utils.bytes import str_to_bytes


struct WSConnection(Movable):
    # Соединение владеет транспортом и протоколом без висячих указателей на локальные переменные
    var conn: TCPConnection
    var protocol: ServerProtocol

    def __init__(
        out self, var conn: TCPConnection, var protocol: ServerProtocol
    ):
        self.conn = conn^
        self.protocol = protocol^

    def read(mut self, mut buffer: Bytes) raises -> Int:
        var count = self.conn.read(buffer)
        if count == 0:
            receive_eof(self.protocol)
        else:
            receive_data(self.protocol, buffer)
        return count

    def write(self, buffer: Bytes) raises -> Int:
        return self.conn.write(buffer[:])

    def send_text(mut self, message: String) raises:
        send_text(self.protocol, str_to_bytes(message))
        _ = self.write(self.protocol.data_to_send())

    def send_binary(mut self, message: Bytes) raises:
        send_binary(self.protocol, message)
        _ = self.write(self.protocol.data_to_send())

    def close(mut self) raises:
        self.conn.close()


comptime ConnHandler = def(
    mut conn: WSConnection, data: Span[Byte, _]
) raises thin -> None


struct Server[handler: ConnHandler](Movable):
    var host: String
    var port: Int
    var max_request_body_size: Int
    var ln: TCPListener

    def __init__(
        out self,
        host: String,
        port: Int,
        max_request_body_size: Int = DEFAULT_MAX_REQUEST_BODY_SIZE,
    ) raises:
        self.host = host
        self.port = port
        self.max_request_body_size = max_request_body_size
        self.ln = TCPListener()

    def __enter__(mut self) -> ServerSession[Self.handler, origin_of(self)]:
        return ServerSession[Self.handler, origin_of(self)](Pointer(to=self))

    def __exit__(mut self) raises:
        self.shutdown()

    def serve_forever(mut self) raises:
        var config = ListenConfig()
        var listener = config.listen(self.host, self.port)
        self.serve(listener^)

    def serve(mut self, var listener: TCPListener) raises:
        self.ln = listener^
        self.port = Int(self.ln.addr().port)
        while True:
            var conn = self.ln.accept()
            self.serve_connection(conn^)

    def serve_connection(mut self, var conn: TCPConnection) raises:
        var websocket = WSConnection(conn^, ServerProtocol())
        var message = Bytes()
        while not websocket.conn.is_closed():
            var buffer = Bytes(capacity=DEFAULT_BUFFER_SIZE)
            if websocket.read(buffer) == 0:
                break
            if websocket.protocol.get_parser_exc():
                var pending = websocket.protocol.data_to_send()
                if len(pending) > 0:
                    _ = websocket.write(pending)
                break
            if websocket.protocol.get_state() == CONNECTING:
                var requests = websocket.protocol.events_received()
                if len(requests) == 0:
                    continue
                var response = websocket.protocol.accept(
                    requests[0][HTTPRequest]
                )
                websocket.protocol.send_response(response)
                _ = websocket.write(websocket.protocol.data_to_send())
                if response.status_code != 101:
                    break
                # После handshake в том же TCP-пакете уже может находиться первый кадр
                receive_data(websocket.protocol, Bytes())
            var events = websocket.protocol.events_received()
            for event in events:
                if event.isa[Frame]() and event[Frame].is_data():
                    message.extend(event[Frame].data[:])
                    if len(message) > self.max_request_body_size:
                        raise Error("WebSocket message is too large")
                    if event[Frame].fin:
                        Self.handler(websocket, message[:])
                        message.clear()
            var pending = websocket.protocol.data_to_send()
            if len(pending) > 0:
                _ = websocket.write(pending)
            if websocket.protocol.get_eof_sent():
                break
        websocket.close()

    def address(self) -> String:
        return String(self.host, ":", self.port)

    def shutdown(mut self) raises:
        self.ln.close()


def serve[
    handler: ConnHandler
](host: String, port: Int) raises -> Server[handler]:
    return Server[handler](host, port)


@fieldwise_init
struct ServerSession[handler: ConnHandler, origin: MutOrigin](
    ImplicitlyCopyable
):
    var pointer: Pointer[mut=True, Server[Self.handler], Self.origin]

    def serve_forever(self) raises:
        self.pointer[].serve_forever()

    def shutdown(self) raises:
        self.pointer[].shutdown()

    def address(self) -> String:
        return self.pointer[].address()
