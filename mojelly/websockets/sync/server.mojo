"""A Linux WebSocket server driven by a single level-triggered epoll loop.

The handler runs on the event-loop thread. It receives a complete message,
never an arbitrary TCP chunk. Keep handlers short: socket concurrency does not
make a blocking application callback concurrent.
"""
from std.collections import Dict, Optional, Span
from std.memory import Pointer
from mojelly.websockets.aliases import (
    Bytes,
    DEFAULT_BUFFER_SIZE,
    DEFAULT_MAX_REQUEST_BODY_SIZE,
)
from mojelly.websockets.frames import Frame, OpCode
from mojelly.websockets.http import HTTPRequest
from mojelly.websockets.logger import logger
from mojelly.websockets.protocol import CONNECTING, OPEN, CLOSING, CLOSED
from mojelly.websockets.protocol.base import (
    receive_data,
    receive_eof,
    send_text,
    send_binary,
    send_ping,
    send_close,
    fail,
)
from mojelly.websockets.protocol.server import ServerProtocol
from mojelly.websockets.transport import Transport, Poller, now_ms
from mojelly.websockets.utils.bytes import str_to_bytes


struct WSConnection(Movable):
    """Own one client's transport, protocol, message assembly and output queue.

    A queue entry survives a short send or EAGAIN. Its offset advances only by
    the number of bytes the kernel actually accepted. The protocol never writes
    to a socket directly, so automatic Pong/Close replies use the same queue.
    """

    var conn: Transport
    var protocol: ServerProtocol
    var message: Bytes
    var message_opcode: Int
    var outgoing: Bytes
    var outgoing_offset: Int
    var max_pending_bytes: Int
    var accepted_at: Int
    var last_activity: Int
    var closing_at: Int
    var close_timeout_ms: Int
    var close_after_write: Bool

    def __init__(
        out self,
        var conn: Transport,
        var protocol: ServerProtocol,
        max_pending_bytes: Int = 20971520,
        close_timeout_ms: Int = 5000,
    ):
        self.conn = conn^
        self.protocol = protocol^
        self.message = Bytes()
        self.message_opcode = OpCode.OP_BINARY
        self.outgoing = Bytes()
        self.outgoing_offset = 0
        self.max_pending_bytes = max_pending_bytes
        self.accepted_at = now_ms()
        self.last_activity = self.accepted_at
        self.closing_at = 0
        self.close_timeout_ms = close_timeout_ms
        self.close_after_write = False

    def pending(self) -> Int:
        return len(self.outgoing) - self.outgoing_offset

    def collect(mut self) raises:
        var data = self.protocol.data_to_send()
        if len(data) > self.max_pending_bytes - self.pending():
            raise Error("Outgoing queue limit exceeded")
        # Compact only when appending; partial writes retain their offset.
        if self.outgoing_offset > 0:
            var remaining = Bytes(self.outgoing[self.outgoing_offset :])
            self.outgoing = remaining^
            self.outgoing_offset = 0
        self.outgoing.extend(data[:])
        if self.protocol.get_state() == CLOSING and self.closing_at == 0:
            self.closing_at = now_ms()
        if self.protocol.get_eof_sent():
            self.close_after_write = True

    def send_text(mut self, message: String) raises:
        send_text(self.protocol, str_to_bytes(message))
        self.collect()

    def send_binary(mut self, message: Bytes) raises:
        send_binary(self.protocol, message)
        self.collect()

    def ping(mut self, data: Bytes = Bytes()) raises:
        send_ping(self.protocol, data)
        self.collect()

    def is_text(self) -> Bool:
        return self.message_opcode == OpCode.OP_TEXT

    def close(mut self, code: Int = 1000, reason: String = "") raises:
        """Start the closing handshake; the reactor enforces its deadline."""
        if self.protocol.get_state() == OPEN:
            send_close(self.protocol, code, reason)
            self.collect()
        elif self.protocol.get_state() == CONNECTING:
            self.abort()

    def abort(mut self):
        """Immediately release the transport after an unrecoverable failure."""
        self.conn.close()
        self.protocol.set_state(CLOSED)

    def flush(mut self) raises:
        # A per-turn budget prevents a fast writer from starving other clients.
        var budget = 262144
        while self.pending() > 0 and budget > 0:
            var end = min(len(self.outgoing), self.outgoing_offset + budget)
            var count = self.conn.try_write(
                self.outgoing[self.outgoing_offset : end]
            )
            if count == -2:
                return
            if count <= 0:
                raise Error("send made no progress")
            self.outgoing_offset += count
            budget -= count
        if self.pending() == 0:
            self.outgoing.clear()
            self.outgoing_offset = 0
            if self.close_after_write:
                self.conn.close()
                self.protocol.set_state(CLOSED)


comptime ConnHandler = def(
    mut conn: WSConnection, data: Span[Byte, _]
) raises thin -> None


struct Server[handler: ConnHandler](Movable):
    """Own the listening socket and all client state on one thread.

    Event IDs are monotonically increasing connection IDs, not file
    descriptors: Linux may reuse a descriptor while an old event is still in
    the current batch. A stale ID therefore cannot address a newer connection.
    """

    var host: String
    var port: Int
    var max_request_body_size: Int
    var max_connections: Int
    var max_pending_bytes: Int
    var handshake_timeout_ms: Int
    var idle_timeout_ms: Int
    var close_timeout_ms: Int
    var origins: Optional[List[String]]
    var ln: Transport
    var clients: Dict[UInt64, WSConnection]
    var client_ids: List[UInt64]
    var next_id: UInt64
    var accept_paused_until: Int
    var running: Bool

    def __init__(
        out self,
        host: String,
        port: Int,
        max_request_body_size: Int = DEFAULT_MAX_REQUEST_BODY_SIZE,
        max_connections: Int = 1024,
        max_pending_bytes: Int = 20971520,
        handshake_timeout_ms: Int = 10000,
        idle_timeout_ms: Int = 60000,
        close_timeout_ms: Int = 5000,
        origins: Optional[List[String]] = None,
    ) raises:
        if (
            max_request_body_size < 1
            or max_connections < 1
            or max_pending_bytes < 256
            or handshake_timeout_ms < 1
            or idle_timeout_ms < 1
            or close_timeout_ms < 1
        ):
            raise Error("Invalid server limits")
        self.host = host
        self.port = port
        self.max_request_body_size = max_request_body_size
        self.max_connections = max_connections
        self.max_pending_bytes = max_pending_bytes
        self.handshake_timeout_ms = handshake_timeout_ms
        self.idle_timeout_ms = idle_timeout_ms
        self.close_timeout_ms = close_timeout_ms
        self.origins = origins.copy()
        self.ln = Transport()
        self.clients = Dict[UInt64, WSConnection]()
        self.client_ids = List[UInt64]()
        self.next_id = 1
        self.accept_paused_until = 0
        self.running = False

    def __enter__(mut self) -> ServerSession[Self.handler, origin_of(self)]:
        return ServerSession[Self.handler, origin_of(self)](Pointer(to=self))

    def __exit__(mut self):
        self.shutdown()

    def bind(mut self) raises:
        self.ln.listen(self.host, self.port)
        self.port = self.ln.port()

    def serve_forever(mut self) raises:
        if self.ln.is_closed():
            self.bind()
        var poller = Poller()
        poller.watch(1, self.ln.fd, 0)
        self.running = True
        try:
            self._loop(poller)
        finally:
            self.shutdown()

    def _loop(mut self, mut poller: Poller) raises:
        while self.running:
            if (
                self.accept_paused_until > 0
                and now_ms() >= self.accept_paused_until
            ):
                poller.watch(1, self.ln.fd, 0)
                self.accept_paused_until = 0
            # Timeout checks also run when no network events arrive.
            var count = poller.wait(100)
            for i in range(count):
                var id = poller.ids[i]
                var flags = poller.flags[i]
                if id == 0:
                    self._accept(poller)
                    continue
                if id not in self.clients:
                    continue
                ref client = self.clients[id]
                try:
                    if flags & (1 | 8192 | 16) != 0:
                        Self._read(client)
                    if not client.conn.is_closed():
                        client.collect()
                        client.flush()
                    if flags & 8 != 0:
                        client.abort()
                except error:
                    # A queue, network or parser failure belongs to this client.
                    logger.debug("Connection failed: ", error)
                    client.abort()
                if not client.conn.is_closed():
                    poller.watch(3, client.conn.fd, id, client.pending() > 0)
            var expired = List[UInt64]()
            var now = now_ms()
            var alive = List[UInt64]()
            for id in self.client_ids:
                ref client = self.clients[id]
                var timeout = client.conn.is_closed()
                if client.protocol.get_state() == CONNECTING:
                    timeout = (
                        timeout
                        or now - client.accepted_at >= self.handshake_timeout_ms
                    )
                elif client.closing_at > 0:
                    timeout = (
                        timeout
                        or now - client.closing_at >= self.close_timeout_ms
                    )
                else:
                    timeout = (
                        timeout
                        or now - client.last_activity >= self.idle_timeout_ms
                    )
                if timeout:
                    expired.append(id)
                else:
                    alive.append(id)
            for id in expired:
                # Closing the sole descriptor automatically removes it from epoll.
                var removed = self.clients.pop(id)
                removed.abort()
            self.client_ids = alive^

    def _accept(mut self, poller: Poller) raises:
        # Bound accept work as well as read/write work in each reactor turn.
        for _ in range(64):
            var fd: Int32
            try:
                fd = self.ln.accept()
            except error:
                # Resource exhaustion must not terminate existing connections or
                # spin continuously on a readable listener that cannot accept.
                logger.warn("Temporarily pausing accept: ", error)
                poller.watch(2, self.ln.fd, 0)
                self.accept_paused_until = now_ms() + 100
                return
            if fd == -2:
                return
            var conn = Transport(fd)
            if len(self.clients) >= self.max_connections:
                conn.close()
                continue
            var id = self.next_id
            self.next_id += 1
            poller.watch(1, fd, id)
            self.client_ids.append(id)
            self.clients[id] = WSConnection(
                conn^,
                ServerProtocol(
                    self.origins, max_size=self.max_request_body_size
                ),
                self.max_pending_bytes,
                self.close_timeout_ms,
            )

    @staticmethod
    def _read(mut client: WSConnection) raises:
        for _ in range(4):
            var buffer = Bytes()
            var count = client.conn.try_read(buffer)
            if count == -2:
                return
            if count == 0:
                receive_eof(client.protocol)
                client.close_after_write = True
                client.collect()
                return
            client.last_activity = now_ms()
            try:
                receive_data(client.protocol, buffer)
            except error:
                if client.protocol.get_state() == CONNECTING:
                    var response = client.protocol.reject(
                        400, "Bad Request", "Invalid WebSocket handshake"
                    )
                    client.protocol.send_response(response)
                    client.collect()
                    return
                raise error
            if client.protocol.get_state() == CONNECTING:
                var requests = client.protocol.events_received()
                if len(requests) == 0:
                    continue
                var response = client.protocol.accept(requests[0][HTTPRequest])
                client.protocol.send_response(response)
                client.collect()
                if response.status_code != 101:
                    return
                # TCP may deliver the HTTP request and the first frame together.
                receive_data(client.protocol, Bytes())
            var events = client.protocol.events_received()
            if client.protocol.get_parser_exc():
                client.collect()
                return
            for event in events:
                if not event.isa[Frame]() or not event[Frame].is_data():
                    continue
                if event[Frame].opcode != OpCode.OP_CONT:
                    client.message_opcode = event[Frame].opcode
                client.message.extend(event[Frame].data[:])
                if event[Frame].fin:
                    # Detach the payload before borrowing the connection mutably.
                    var message = client.message^
                    client.message = Bytes()
                    try:
                        Self.handler(client, message[:])
                    except error:
                        logger.debug("Handler failed: ", error)
                        if client.protocol.get_state() == OPEN:
                            fail(client.protocol, 1011, "Handler failed")
                        else:
                            client.close_after_write = True
                    client.message.clear()
                    if (
                        client.protocol.get_state() != OPEN
                        or client.conn.is_closed()
                    ):
                        client.collect()
                        return
            client.collect()
            if client.close_after_write:
                return

    def address(self) -> String:
        var host = "[" + self.host + "]" if ":" in self.host else self.host
        return host + ":" + String(self.port)

    def shutdown(mut self):
        # Called on the owning thread after the reactor has stopped using state.
        self.running = False
        self.clients.clear()
        self.client_ids.clear()
        self.ln.close()


def serve[
    handler: ConnHandler
](host: String, port: Int) raises -> Server[handler]:
    return Server[handler](host, port)


@fieldwise_init
struct ServerSession[handler: ConnHandler, origin: MutOrigin](
    ImplicitlyCopyable
):
    # The session is a tracked borrow; it cannot outlive the server owner.
    var pointer: Pointer[mut=True, Server[Self.handler], Self.origin]

    def serve_forever(self) raises:
        self.pointer[].serve_forever()

    def shutdown(self):
        self.pointer[].shutdown()

    def address(self) -> String:
        return self.pointer[].address()
