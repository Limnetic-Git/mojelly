"""Own Linux sockets and translate readiness into bounded I/O operations.

The C bridge hides sockaddr and packed epoll_event layouts behind scalar
arguments and initialized byte buffers. A return value of -2 means EAGAIN,
not EOF; zero from recv means EOF. Network failures retain their errno.
The client waits with poll; the server retries only after epoll readiness.
"""

from std.collections import Span
from std.ffi import external_call
from mojelly.websockets.aliases import Bytes, DEFAULT_BUFFER_SIZE


def now_ms() -> Int:
    return external_call["ws_now_ms", Int]()


def transport_error(operation: String) -> Error:
    return Error(operation, ": errno=", external_call["ws_errno", Int32]())


struct Transport(Movable):
    # Own the sole descriptor; copying a live transport is forbidden.
    var fd: Int32

    def __init__(out self, fd: Int32 = -1):
        self.fd = fd

    def __deinit__(deinit self):
        if self.fd >= 0:
            _ = external_call["ws_close", Int32](self.fd)

    def close(mut self):
        if self.fd >= 0:
            _ = external_call["ws_close", Int32](self.fd)
            self.fd = -1

    def is_closed(self) -> Bool:
        return self.fd < 0

    def port(self) raises -> Int:
        var result = external_call["ws_port", Int32](self.fd)
        if result < 0:
            raise transport_error("getsockname")
        return Int(result)

    def listen(mut self, var host: String, port: Int) raises:
        if port < 0 or port > 65535:
            raise Error("Invalid port")
        var fd = external_call["ws_listen", Int32](
            host.as_c_string_span(), Int32(port)
        )
        if fd < 0:
            raise transport_error("listen")
        self.close()
        self.fd = fd

    def connect(mut self, var host: String, port: Int, timeout_ms: Int) raises:
        if port < 1 or port > 65535 or timeout_ms <= 0:
            raise Error("Invalid connection parameters")
        var fd = external_call["ws_connect", Int32](
            host.as_c_string_span(), Int32(port), Int32(timeout_ms)
        )
        if fd < 0:
            raise transport_error("connect")
        self.close()
        self.fd = fd

    def accept(self) raises -> Int32:
        var result = external_call["ws_accept", Int32](self.fd)
        if result == -1:
            raise transport_error("accept")
        return result

    def try_read(self, mut buffer: Bytes) raises -> Int:
        # Resize through the public API before recv writes to initialized elements;
        # shrink back to the actual byte count so zero padding never reaches WS.
        buffer.resize(DEFAULT_BUFFER_SIZE, fill=0)
        var count = external_call["ws_recv", Int](
            self.fd, buffer.unsafe_ptr(), len(buffer)
        )
        if count < 0:
            buffer.clear()
            if count == -2:
                return -2
            raise transport_error("recv")
        buffer.resize(count, fill=0)
        return count

    def try_write(self, data: Span[Byte, _]) raises -> Int:
        var count = external_call["ws_send", Int](
            self.fd, data.unsafe_ptr(), len(data)
        )
        if count == -1:
            raise transport_error("send")
        return count

    def wait(self, writing: Bool, deadline: Int) raises:
        # Keep one absolute deadline across interruptions and spurious readiness.
        # Restarting a full relative timeout here would let retries extend it forever.
        while True:
            var remaining = deadline - now_ms()
            if remaining <= 0:
                raise Error("Timeout")
            var result = external_call["ws_poll", Int32](
                self.fd, Int32(writing), Int32(min(remaining, 2147483647))
            )
            if result > 0:
                return
            if result == 0:
                raise Error("Timeout")
            if result != -2:
                raise transport_error("poll")

    def read(self, mut buffer: Bytes, timeout_ms: Int = 30000) raises -> Int:
        var deadline = now_ms() + timeout_ms
        while True:
            var count = self.try_read(buffer)
            if count != -2:
                return count
            self.wait(False, deadline)

    def write(self, data: Bytes, timeout_ms: Int = 30000) raises -> Int:
        # This blocking facade belongs to the synchronous client only. The server
        # calls try_write and keeps its own queue instead of waiting in this loop.
        var deadline = now_ms() + timeout_ms
        var offset = 0
        while offset < len(data):
            if now_ms() >= deadline:
                raise Error("Timeout")
            var count = self.try_write(data[offset:])
            if count == -2:
                self.wait(True, deadline)
            elif count <= 0:
                raise Error("send made no progress")
            else:
                offset += count
        return offset


struct Poller(Movable):
    var owner: Transport
    var ids: List[UInt64]
    var flags: List[UInt32]

    def __init__(out self) raises:
        var fd = external_call["ws_epoll_create", Int32]()
        if fd < 0:
            raise transport_error("epoll_create1")
        self.owner = Transport(fd)
        self.ids = List[UInt64](length=128, fill=0)
        self.flags = List[UInt32](length=128, fill=0)

    def watch(
        self, operation: Int, fd: Int32, id: UInt64, writing: Bool = False
    ) raises:
        if (
            external_call["ws_epoll_watch", Int32](
                self.owner.fd, Int32(operation), fd, id, Int32(writing)
            )
            != 0
        ):
            raise transport_error("epoll_ctl")

    def wait(mut self, timeout_ms: Int) raises -> Int:
        var count = external_call["ws_epoll_wait", Int32](
            self.owner.fd,
            self.ids.unsafe_ptr(),
            self.flags.unsafe_ptr(),
            Int32(128),
            Int32(timeout_ms),
        )
        if count == -1:
            raise transport_error("epoll_wait")
        return max(0, Int(count))
