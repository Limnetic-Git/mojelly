# This code is taken from a publicly available repository distributed under the terms of the MIT license:
# https://github.com/msaelices/mojo-websockets/blob/main/LICENSE
from mojelly.websockets.aliases import CPointer

# Code adapted from lightbug_http
from std.collections import Optional
from std.memory import stack_allocation
from std.collections import Span
from std.collections import Array
from std.sys import size_of
from std.ffi import external_call
from mojelly.websockets.aliases import os_is_macos, os_is_linux, os_is_windows
from std.memory import Pointer

from mojelly.websockets.libc import (
    accept,
    socket,
    connect,
    dup,
    recv,
    send,
    sendto,
    shutdown,
    inet_pton,
    inet_ntop,
    htons,
    ntohs,
    gai_strerror,
    bind,
    listen,
    setsockopt,
    getsockopt,
    getsockname,
    getpeername,
    close,
    sockaddr,
    sockaddr_in,
    addrinfo,
    socklen_t,
    c_void,
    c_uint,
    c_char,
    c_int,
    in_addr,
    SHUT_RDWR,
    SOL_SOCKET,
    AF_INET,
    AF_INET6,
    SOCK_STREAM,
    INET_ADDRSTRLEN,
    SO_REUSEADDR,
    SO_RCVTIMEO,
    EAGAIN,
    EBADF,
    EFAULT,
    EINTR,
    EINVAL,
    EMFILE,
    ENFILE,
    ENOMEM,
    EPERM,
    EWOULDBLOCK,
    CloseInvalidDescriptorError,
    ShutdownInvalidArgumentError,
)
from mojelly.websockets.aliases import Bytes, DEFAULT_BUFFER_SIZE
from mojelly.websockets.libc import get_errno
from mojelly.websockets.utils.time import TimeVal
from std.os import abort
from mojelly.websockets.net import (
    Addr,
    NetworkType,
    default_buffer_size,
    binary_port_to_int,
    binary_ip_to_string,
    addrinfo_macos,
    addrinfo_unix,
)
from mojelly.websockets.logger import logger


comptime SocketClosedError = "Socket: Socket is already closed"


struct Socket[AddrType: Addr, address_family: Int = AF_INET](
    Copyable, Movable, Writable
):
    var fd: Int32
    var socket_type: Int32
    var protocol: Byte
    var _local_address: Self.AddrType
    var _remote_address: Self.AddrType
    var _closed: Bool
    var _connected: Bool

    def __init__(
        out self,
        local_address: Self.AddrType = Self.AddrType(),
        remote_address: Self.AddrType = Self.AddrType(),
        socket_type: Int32 = SOCK_STREAM,
        protocol: Byte = 0,
    ) raises:
        self.fd = socket(
            Int32(Self.address_family), socket_type, Int32(protocol)
        )
        self.socket_type = socket_type
        self.protocol = protocol
        self._local_address = local_address.copy()
        self._remote_address = remote_address.copy()
        self._closed = False
        self._connected = False

    def __init__(
        out self,
        fd: Int32,
        socket_type: Int32,
        protocol: Byte,
        local_address: Self.AddrType,
        remote_address: Self.AddrType = Self.AddrType(),
    ):
        self.fd = fd
        self.socket_type = socket_type
        self.protocol = protocol
        self._local_address = local_address.copy()
        self._remote_address = remote_address.copy()
        self._closed = False
        self._connected = True

    def __init__(out self, *, deinit move: Self):
        self.fd = move.fd
        self.socket_type = move.socket_type
        self.protocol = move.protocol
        self._local_address = move._local_address^
        self._remote_address = move._remote_address^
        self._closed = move._closed
        self._connected = move._connected

    def __init__(out self, *, copy: Self):
        # Explicit copying creates a separate descriptor for the same connection
        self.fd = dup(copy.fd) if not copy._closed else -1
        self.socket_type = copy.socket_type
        self.protocol = copy.protocol
        self._local_address = copy._local_address.copy()
        self._remote_address = copy._remote_address.copy()
        self._closed = copy._closed
        self._connected = copy._connected
        if not self._closed and self.fd < 0:
            abort("Could not duplicate socket")

    def __deinit__(deinit self):
        if not self._closed:
            _ = external_call["close", Int32](self.fd)

    def __enter__(self) -> Self:
        return self.copy()

    def __exit__(mut self) raises:
        self.close()

    def __str__(self) -> String:
        return String(self)

    def __repr__(self) -> String:
        return String(self)

    def write_to[W: Writer](self, mut writer: W):
        writer.write("Socket(fd=", self.fd, ", closed=", self._closed, ")")

    def local_address(ref self) -> ref[self._local_address] Self.AddrType:
        return self._local_address

    def remote_address(self) -> Self.AddrType:
        return self._remote_address.copy()

    def set_local_address(mut self, address: Self.AddrType):
        self._local_address = address.copy()

    def set_remote_address(mut self, address: Self.AddrType):
        self._remote_address = address.copy()

    def accept(self) raises -> Self:
        var fd = accept(self.fd)
        var result = Self(
            fd, self.socket_type, self.protocol, self._local_address
        )
        var peer = result.get_peer_name()
        result._remote_address = Self.AddrType(peer[0], peer[1])
        return result^

    def listen(self, backlog: UInt = 128) raises:
        listen(self.fd, Int32(backlog))

    def bind(mut self, address: String, port: UInt16) raises:
        var binary_ip = inet_pton[Self.address_family](address)
        var local = sockaddr_in(Self.address_family, port, binary_ip)
        bind(self.fd, local)
        var bound = self.get_sock_name()
        self._local_address = Self.AddrType(bound[0], bound[1])

    def get_sock_name(self) raises -> Tuple[String, UInt16]:
        var local = sockaddr_in(Self.address_family, 0, 0)
        var length = UInt32(size_of[sockaddr_in]())
        if (
            external_call["getsockname", Int32](
                self.fd, Pointer(to=local), Pointer(to=length)
            )
            != 0
        ):
            raise Error("getsockname failed")
        return (
            binary_ip_to_string[Self.address_family](local.sin_addr.s_addr),
            ntohs(local.sin_port),
        )

    def get_peer_name(self) raises -> Tuple[String, UInt16]:
        var remote = sockaddr_in(Self.address_family, 0, 0)
        var length = UInt32(size_of[sockaddr_in]())
        if (
            external_call["getpeername", Int32](
                self.fd, Pointer(to=remote), Pointer(to=length)
            )
            != 0
        ):
            raise Error("getpeername failed")
        return (
            binary_ip_to_string[Self.address_family](remote.sin_addr.s_addr),
            ntohs(remote.sin_port),
        )

    def connect(mut self, address: String, port: UInt16) raises:
        var ip = in_addr(0)
        comptime if os_is_macos():
            ip = addrinfo_macos().get_ip_address(address)
        else:
            ip = addrinfo_unix().get_ip_address(address)
        var remote = sockaddr_in(Self.address_family, port, ip.s_addr)
        connect(self.fd, remote)
        self._connected = True
        var peer = self.get_peer_name()
        self._remote_address = Self.AddrType(peer[0], peer[1])

    def send(self, buffer: Span[Byte, _]) raises -> Int:
        # A binary payload may contain zero bytes, including its final byte
        while True:
            var sent = external_call["send", Int](
                self.fd,
                buffer.unsafe_ptr(),
                len(buffer),
                Int32(16384 if os_is_linux() else 0),
            )
            if sent >= 0:
                return sent
            if get_errno() != 4:
                raise Error("send failed: ", get_errno())

    def send_all(self, buffer: Span[Byte, _], max_attempts: Int = 3) raises:
        # After a partial write, resume at the first byte not yet sent
        var offset = 0
        while offset < len(buffer):
            var sent = self.send(buffer[offset:])
            if sent == 0:
                raise Error("send made no progress")
            offset += sent

    def send_to(
        mut self, buffer: Span[Byte, _], address: String, port: UInt16
    ) raises -> UInt:
        var ip = inet_pton[Self.address_family](address)
        var remote = sockaddr_in(Self.address_family, port, ip)
        var sent = external_call["sendto", Int](
            self.fd,
            buffer.unsafe_ptr(),
            len(buffer),
            Int32(0),
            Pointer(to=remote),
            UInt32(size_of[sockaddr_in]()),
        )
        if sent < 0:
            raise Error("sendto failed")
        return UInt(sent)

    def _receive(self, mut buffer: Bytes) raises -> UInt:
        # Grow the list through its public API so recv writes into initialized elements
        var start = len(buffer)
        var available = max(DEFAULT_BUFFER_SIZE, buffer.capacity() - start)
        for i in range(available):
            buffer.append(0)
        var received = Int(-1)
        while received < 0:
            received = external_call["recv", Int](
                self.fd,
                buffer.unsafe_ptr().unsafe_offset(start),
                available,
                Int32(0),
            )
            if received < 0 and get_errno() != 4:
                buffer.resize(start, fill=0)
                raise Error("recv failed: ", get_errno())
        buffer.resize(start + received, fill=0)
        return UInt(received)

    def receive(self, mut buffer: Bytes) raises -> UInt:
        return self._receive(buffer)

    def receive(self, size: Int = default_buffer_size) raises -> Bytes:
        var buffer = Bytes(capacity=size)
        _ = self._receive(buffer)
        return buffer^

    def get_socket_option(self, option_name: Int) raises -> Int:
        var value = Int32(0)
        var length = UInt32(size_of[Int32]())
        if (
            external_call["getsockopt", Int32](
                self.fd,
                Int32(SOL_SOCKET),
                Int32(option_name),
                Pointer(to=value),
                Pointer(to=length),
            )
            != 0
        ):
            raise Error("getsockopt failed")
        return Int(value)

    def set_socket_option(self, option_name: Int, option_value: Int = 1) raises:
        var value = Int32(option_value)
        if (
            external_call["setsockopt", Int32](
                self.fd,
                Int32(SOL_SOCKET),
                Int32(option_name),
                Pointer(to=value),
                UInt32(size_of[Int32]()),
            )
            != 0
        ):
            raise Error("setsockopt failed")

    def set_timeout(self, duration: Int) raises:
        var timeout = TimeVal(duration, 0)
        if (
            external_call["setsockopt", Int32](
                self.fd,
                Int32(SOL_SOCKET),
                Int32(SO_RCVTIMEO),
                Pointer(to=timeout),
                UInt32(size_of[TimeVal]()),
            )
            != 0
        ):
            raise Error("setsockopt timeout failed")

    def get_timeout(self) raises -> Int:
        var timeout = TimeVal()
        var length = UInt32(size_of[TimeVal]())
        if (
            external_call["getsockopt", Int32](
                self.fd,
                Int32(SOL_SOCKET),
                Int32(SO_RCVTIMEO),
                Pointer(to=timeout),
                Pointer(to=length),
            )
            != 0
        ):
            raise Error("getsockopt timeout failed")
        return timeout.tv_sec

    def shutdown(mut self) raises:
        if self._connected:
            shutdown(self.fd, SHUT_RDWR)
            self._connected = False

    def close(mut self) raises:
        if not self._closed:
            close(self.fd)
            self._closed = True
            self._connected = False

    def teardown(mut self) raises:
        self.close()
