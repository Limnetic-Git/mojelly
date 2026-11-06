# This code is taken from a publicly available repository distributed under the terms of the MIT license:
# https://github.com/msaelices/mojo-websockets/blob/main/LICENSE
from std.memory import OptionalPointer
from mojelly.websockets.aliases import CPointer
from std.collections import Optional
from std.sys.info import align_of, size_of
from std.ffi import external_call
from mojelly.websockets.aliases import os_is_macos
from std.memory import MutOpaquePointer
from std.memory import Pointer
from std.collections import Span
from std.time import sleep
from std.collections import Array
from std.utils import Variant

from mojelly.websockets.aliases import Bytes, Duration

from mojelly.websockets.libc import (
    AF_INET,
    AF_INET6,
    AI_PASSIVE,
    INET_ADDRSTRLEN,
    INET6_ADDRSTRLEN,
    SHUT_RDWR,
    SOCK_STREAM,
    SOL_SOCKET,
    SO_ERROR,
    SO_REUSEADDR,
    accept,
    addrinfo,
    c_char,
    c_uchar,
    c_int,
    c_uint,
    c_void,
    close,
    gai_strerror,
    getpeername,
    getsockname,
    getsockopt,
    htons,
    in_addr,
    inet_ntop,
    inet_pton,
    listen,
    ntohs,
    recv,
    send,
    setsockopt,
    shutdown,
    sockaddr,
    sockaddr_in,
    socket,
    socklen_t,
)
from mojelly.websockets.logger import logger
from mojelly.websockets.socket import Socket
from mojelly.websockets.utils.string import to_string

comptime default_buffer_size = 4096
comptime default_tcp_keep_alive = Duration(
    15 * 1000 * 1000 * 1000
)  # 15 seconds

comptime MissingPortError = Error("missing port in address")
comptime TooManyColonsError = Error("too many colons in address")


trait AddrInfo:
    def get_ip_address(self, host: String) raises -> in_addr:
        """
        TODO: Once default functions can be implemented in traits, this function should use the functions currently
        implemented in the `addrinfo_macos` and `addrinfo_unix` structs.
        """
        ...


trait Net:
    def __init__(out self) raises:
        ...

    def __init__(out self, keep_alive: Duration) raises:
        ...

    # A listen method should be implemented on structs that implement Net.
    # Signature is not enforced for now.
    # fn listen(mut self, network: String, addr: String) raises -> Listener:
    #    ...


trait Connection:
    def __init__(out self, laddr: String, raddr: String) raises:
        ...

    def __init__(out self, laddr: TCPAddr, raddr: TCPAddr) raises:
        ...

    def read(self, mut buf: Bytes) raises -> Int:
        ...

    def write(self, buf: Bytes) raises -> Int:
        ...

    def close(self) raises:
        ...

    def local_addr(mut self) raises -> TCPAddr:
        ...

    def remote_addr(self) raises -> TCPAddr:
        ...


trait Addr(Copyable, Deinitable, Movable, Writable):
    def __init__(out self):
        ...

    def __init__(out self, ip: String, port: UInt16):
        ...

    def network(self) -> String:
        ...


@fieldwise_init
struct NetworkType(Copyable, Movable):
    var value: String

    comptime EMPTY = NetworkType("")
    comptime TCP = NetworkType("tcp")
    comptime TCP4 = NetworkType("tcp4")
    comptime TCP6 = NetworkType("tcp6")
    comptime UDP = NetworkType("udp")
    comptime UDP4 = NetworkType("udp4")
    comptime UDP6 = NetworkType("udp6")
    comptime IP = NetworkType("ip")
    comptime IP4 = NetworkType("ip4")
    comptime IP6 = NetworkType("ip6")
    comptime UNIX = NetworkType("unix")


@fieldwise_init
struct TCPAddr(Addr, Copyable, Movable):
    var ip: String
    var port: UInt16
    var zone: String  # IPv6 addressing zone

    def __init__(out self):
        self.ip = "127.0.0.1"
        self.port = 8000
        self.zone = ""

    def __init__(out self, ip: String, port: UInt16):
        self.ip = ip
        self.port = port
        self.zone = ""

    def __init__(out self, *, copy: Self):
        self.ip = copy.ip
        self.port = copy.port
        self.zone = copy.zone

    def network(self) -> String:
        return NetworkType.TCP.value

    def __eq__(self, other: Self) -> Bool:
        return (
            self.ip == other.ip
            and self.port == other.port
            and self.zone == other.zone
        )

    def __ne__(self, other: Self) -> Bool:
        return not self == other

    def __str__(self) -> String:
        if self.zone != "":
            return join_host_port(self.ip + "%" + self.zone, String(self.port))
        return join_host_port(self.ip, String(self.port))

    def __repr__(self) -> String:
        return String(self)

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(
            "TCPAddr(",
            "ip=",
            repr(self.ip),
            ", port=",
            String(self.port),
            ", zone=",
            repr(self.zone),
            ")",
        )


struct TCPConnection(Copyable, Movable):
    var socket: Socket[TCPAddr]

    def __init__(out self, var socket: Socket[TCPAddr]):
        self.socket = socket^

    def __init__(out self, *, deinit move: Self):
        self.socket = move.socket^

    def __init__(out self, *, copy: Self):
        self.socket = copy.socket.copy()

    def connect(mut self, host: String, port: Int) raises:
        self.socket.connect(host, UInt16(port))

    def read(self, mut buf: Bytes) raises -> Int:
        try:
            return Int(self.socket.receive(buf))
        except e:
            if String(e) == "EOF":
                raise e
            else:
                logger.error(e)
                raise Error(
                    "TCPConnection.read: Failed to read data from connection."
                )

    def write(self, buf: Span[Byte, _]) raises -> Int:
        try:
            self.socket.send_all(buf)
            return len(buf)
        except e:
            logger.error(
                "TCPConnection.write: Failed to write data to connection."
            )
            raise e

    def close(mut self) raises:
        self.socket.close()

    def shutdown(mut self) raises:
        self.socket.shutdown()

    def teardown(mut self) raises:
        self.socket.teardown()

    def is_closed(self) -> Bool:
        return self.socket._closed

    # TODO: Switch to property or return ref when trait supports attributes.
    def local_addr(self) -> TCPAddr:
        return self.socket.local_address().copy()

    def remote_addr(self) -> Optional[TCPAddr]:
        return self.socket.remote_address()


def resolve_internet_addr(network: String, address: String) raises -> TCPAddr:
    var host: String = ""
    var port: String
    var portnum: Int = 0
    if (
        network == NetworkType.TCP.value
        or network == NetworkType.TCP4.value
        or network == NetworkType.TCP6.value
        or network == NetworkType.UDP.value
        or network == NetworkType.UDP4.value
        or network == NetworkType.UDP6.value
    ):
        if address != "":
            var host_port = split_host_port(address)
            host = host_port.host
            port = host_port.port
            portnum = atol(port)
    elif (
        network == NetworkType.IP.value
        or network == NetworkType.IP4.value
        or network == NetworkType.IP6.value
    ):
        if address != "":
            host = address
    elif network == NetworkType.UNIX.value:
        raise Error("Unix addresses not supported yet")
    else:
        raise Error("unsupported network type: " + network)
    return TCPAddr(host, UInt16(portnum))


def join_host_port(host: String, port: String) -> String:
    if host.find(":") != -1:  # must be IPv6 literal
        return "[" + host + "]:" + port
    return host + ":" + port


comptime missingPortError = Error("missing port in address")
comptime tooManyColonsError = Error("too many colons in address")


struct HostPort(Copyable, Movable):
    var host: String
    var port: String

    def __init__(out self, host: String, port: String):
        self.host = host
        self.port = port


def split_host_port(hostport: String) raises -> HostPort:
    var host: String
    var port: String
    var colon_index = hostport.rfind(":")
    var j: Int = 0
    var k: Int = 0

    if colon_index == -1:
        raise missingPortError
    if hostport[byte=0] == "[":
        var end_bracket_index = hostport.find("]")
        if end_bracket_index == -1:
            raise Error("missing ']' in address")
        if end_bracket_index + 1 == hostport.byte_length():
            raise missingPortError
        elif end_bracket_index + 1 == colon_index:
            host = String(hostport[byte=1:end_bracket_index])
            j = 1
            k = end_bracket_index + 1
        else:
            if hostport[byte=end_bracket_index + 1] == ":":
                raise tooManyColonsError
            else:
                raise missingPortError
    else:
        host = String(hostport[byte=:colon_index])
        if host.find(":") != -1:
            raise tooManyColonsError
    if String(hostport[byte=j:]).find("[") != -1:
        raise Error("unexpected '[' in address")
    if String(hostport[byte=k:]).find("]") != -1:
        raise Error("unexpected ']' in address")
    port = String(hostport[byte = colon_index + 1 :])

    if port == "":
        raise missingPortError
    if host == "":
        raise Error("missing host")
    return HostPort(host, port)


def parse_address(address: String) raises -> Tuple[String, UInt16]:
    """Parse an address string into a host and port.

    Args:
        address: The address string.

    Returns:
        A tuple containing the host and port.
    """
    var colon_index = address.rfind(":")
    if colon_index == -1:
        raise MissingPortError

    var host: String
    var port: String
    var j: Int = 0
    var k: Int = 0

    if address[byte=0] == "[":
        var end_bracket_index = address.find("]")
        if end_bracket_index == -1:
            raise Error("missing ']' in address")

        if end_bracket_index + 1 == address.byte_length():
            raise MissingPortError
        elif end_bracket_index + 1 == colon_index:
            host = String(address[byte=1:end_bracket_index])
            j = 1
            k = end_bracket_index + 1
        else:
            if address[byte=end_bracket_index + 1] == ":":
                raise TooManyColonsError
            else:
                raise MissingPortError
    else:
        host = String(address[byte=:colon_index])
        if host.find(":") != -1:
            raise TooManyColonsError

    if String(address[byte=j:]).find("[") != -1:
        raise Error("unexpected '[' in address")
    if String(address[byte=k:]).find("]") != -1:
        raise Error("unexpected ']' in address")

    port = String(address[byte = colon_index + 1 :])
    if port == "":
        raise MissingPortError
    if host == "":
        raise Error("missing host")
    return host, UInt16(Int(port))


def binary_port_to_int(port: UInt16) -> Int:
    """Convert a binary port to an integer.

    Args:
        port: The binary port.

    Returns:
        The port as an integer.
    """
    return Int(ntohs(port))


def binary_ip_to_string[
    address_family: Int
](var ip_address: UInt32) raises -> String:
    """Convert a binary IP address to a string by calling `inet_ntop`.

    Parameters:
        address_family: The address family of the IP address.

    Args:
        ip_address: The binary IP address.

    Returns:
        The IP address as a string.
    """
    comptime assert Int(address_family) in [
        AF_INET,
        AF_INET6,
    ], "Address family must be either AF_INET or AF_INET6."
    var ip: String

    comptime if address_family == AF_INET:
        ip = inet_ntop[address_family, INET_ADDRSTRLEN](ip_address)
    else:
        ip = inet_ntop[address_family, INET6_ADDRSTRLEN](ip_address)

    return ip


@fieldwise_init
struct addrinfo_macos(AddrInfo, Copyable, Movable):
    """
    For MacOS, I had to swap the order of ai_canonname and ai_addr.
    https://stackoverflow.com/questions/53575101/calling-getaddrinfo-directly-from-python-ai-addr-is-null-pointer.
    """

    var ai_flags: c_int
    var ai_family: c_int
    var ai_socktype: c_int
    var ai_protocol: c_int
    var ai_addrlen: socklen_t
    var ai_canonname: OptionalPointer[c_char, MutUntrackedOrigin]
    var ai_addr: OptionalPointer[sockaddr, MutUntrackedOrigin]
    var ai_next: OptionalPointer[c_void, MutUntrackedOrigin]

    def __init__(out self):
        self.ai_flags = 0
        self.ai_family = 0
        self.ai_socktype = 0
        self.ai_protocol = 0
        self.ai_addrlen = 0
        self.ai_canonname = None
        self.ai_addr = None
        self.ai_next = None

    def get_from_host(self, var host: String) raises -> CPointer[Self]:
        var hints = Self()
        hints.ai_family = Int32(AF_INET)
        hints.ai_socktype = Int32(SOCK_STREAM)
        var result: OptionalPointer[Self, MutUntrackedOrigin] = None
        getaddrinfo(host, String(), hints, result)
        if not result:
            raise Error("getaddrinfo returned no addresses")
        return result.value()

    def get_ip_address(self, host: String) raises -> in_addr:
        var result = self.get_from_host(host)
        try:
            if not result[].ai_addr:
                raise Error("getaddrinfo returned a null address")
            return (
                result[]
                .ai_addr.value()
                .unsafe_bitcast[sockaddr_in]()[]
                .sin_addr.copy()
            )
        finally:
            freeaddrinfo(result)


@fieldwise_init
struct addrinfo_unix(AddrInfo, Copyable, Movable):
    """
    Standard addrinfo struct for Unix systems. Overwrites the existing libc `getaddrinfo` function to adhere to the AnAddrInfo trait.
    """

    var ai_flags: c_int
    var ai_family: c_int
    var ai_socktype: c_int
    var ai_protocol: c_int
    var ai_addrlen: socklen_t
    var ai_addr: OptionalPointer[sockaddr, MutUntrackedOrigin]
    var ai_canonname: OptionalPointer[c_char, MutUntrackedOrigin]
    var ai_next: OptionalPointer[c_void, MutUntrackedOrigin]

    def __init__(
        out self,
        ai_flags: c_int = 0,
        ai_family: c_int = 0,
        ai_socktype: c_int = 0,
        ai_protocol: c_int = 0,
        ai_addrlen: socklen_t = 0,
    ):
        self.ai_flags = ai_flags
        self.ai_family = ai_family
        self.ai_socktype = ai_socktype
        self.ai_protocol = ai_protocol
        self.ai_addrlen = ai_addrlen
        self.ai_canonname = None
        self.ai_addr = None
        self.ai_next = None

    def get_from_host(self, var host: String) raises -> CPointer[Self]:
        var hints = Self()
        hints.ai_family = Int32(AF_INET)
        hints.ai_socktype = Int32(SOCK_STREAM)
        var result: OptionalPointer[Self, MutUntrackedOrigin] = None
        getaddrinfo(host, String(), hints, result)
        if not result:
            raise Error("getaddrinfo returned no addresses")
        return result.value()

    def get_ip_address(self, host: String) raises -> in_addr:
        var result = self.get_from_host(host)
        try:
            if not result[].ai_addr:
                raise Error("getaddrinfo returned a null address")
            return (
                result[]
                .ai_addr.value()
                .unsafe_bitcast[sockaddr_in]()[]
                .sin_addr.copy()
            )
        finally:
            freeaddrinfo(result)


struct TCPListener(Copyable, Movable):
    """
    A TCP listener that listens for incoming connections and can accept them.
    """

    var socket: Socket[TCPAddr]

    def __init__(out self, var socket: Socket[TCPAddr]):
        self.socket = socket^

    def __init__(out self) raises:
        self.socket = Socket[TCPAddr]()

    def __init__(out self, *, deinit move: Self):
        self.socket = move.socket^

    def __init__(out self, *, copy: Self):
        self.socket = copy.socket.copy()

    def accept(self) raises -> TCPConnection:
        return TCPConnection(self.socket.accept())

    def close(mut self) raises -> None:
        return self.socket.close()

    def shutdown(mut self) raises -> None:
        return self.socket.shutdown()

    def teardown(mut self) raises:
        self.socket.teardown()

    def addr(self) -> TCPAddr:
        return self.socket.local_address().copy()


struct ListenConfig(Copyable, Movable):
    var _keep_alive: Duration

    def __init__(out self, keep_alive: Duration = default_tcp_keep_alive):
        self._keep_alive = keep_alive

    def listen[
        address_family: Int = AF_INET
    ](mut self, host: String, port: Int) raises -> TCPListener:
        comptime assert address_family in [
            AF_INET,
            AF_INET6,
        ], "Address family must be either AF_INET or AF_INET6."
        var socket = Socket[TCPAddr]()
        socket.set_socket_option(SO_REUSEADDR, 1)
        socket.bind(host, UInt16(port))
        socket.listen(128)
        return TCPListener(socket^)


def get_address_info(
    host: String,
) raises -> Variant[addrinfo_macos, addrinfo_unix]:
    comptime if os_is_macos():
        var ptr = addrinfo_macos().get_from_host(host)
        var value = ptr[].copy()
        freeaddrinfo(ptr)
        value.ai_addr = None
        value.ai_canonname = None
        value.ai_next = None
        return value^
    else:
        var ptr = addrinfo_unix().get_from_host(host)
        var value = ptr[].copy()
        freeaddrinfo(ptr)
        value.ai_addr = None
        value.ai_canonname = None
        value.ai_next = None
        return value^


def _getaddrinfo[
    T: AddrInfo
](
    node: Pointer[mut=False, c_char, _],
    service: OptionalPointer[c_char, ImmUntrackedOrigin],
    hints: Pointer[T, _],
    result: Pointer[OptionalPointer[T, MutUntrackedOrigin], _],
) -> c_int:
    return external_call["getaddrinfo", c_int](node, service, hints, result)


def getaddrinfo[
    T: AddrInfo
](
    var node: String,
    var service: String,
    hints: T,
    mut res: OptionalPointer[T, MutUntrackedOrigin],
) raises:
    # Pass an empty service as NULL rather than a pointer to an empty string
    var service_ptr: OptionalPointer[c_char, ImmUntrackedOrigin] = None
    if service.byte_length() > 0:
        service_ptr = (
            service.unsafe_ptr()
            .unsafe_bitcast[c_char]()
            .unsafe_origin_cast[ImmUntrackedOrigin]()
        )
    var status = external_call["getaddrinfo", c_int](
        node.unsafe_ptr(), service_ptr, Pointer(to=hints), Pointer(to=res)
    )
    if status != 0:
        raise Error("getaddrinfo failed: ", status)


def freeaddrinfo[T: AddrInfo, //](ptr: CPointer[T]):
    """Free the memory allocated by `getaddrinfo`."""
    external_call["freeaddrinfo", NoneType, CPointer[T]](ptr)


# fn create_connection(
#     host: String, port: UInt16
# ) raises -> TCPConnection:
#     """
#     Connect to a server using a socket.
#
#     Args:
#         host: String - The host to connect to.
#         port: UInt16 - The port to connect to.
#
#     Returns:
#         Int32 - The socket file descriptor.
#     """
#     var ip: in_addr
#     print("Connecting to " + host + " on port " + port)
#     if os_is_macos():
#         ip = addrinfo_macos().get_ip_address(host)
#     else:
#         ip = addrinfo_unix().get_ip_address(host)
#
#     # Convert ip address to network byte order.
#     var addr: sockaddr_in = sockaddr_in(
#         AF_INET, htons(port), ip, StaticTuple[c_char, 8](0, 0, 0, 0, 0, 0, 0, 0)
#     )
#     var addr_ptr = Pointer[sockaddr_in](to=addr)
#     var sock = socket(AF_INET, SOCK_STREAM, 0)
#
#     if (
#         external_call["connect", c_int](sock, addr_ptr, sizeof[sockaddr_in]())
#         == -1
#     ):
#         _ = shutdown(sock, SHUT_RDWR)
#         raise Error("Failed to connect to server")
#
#     var laddr = TCPAddr()
#     var raddr = TCPAddr(host, Int(port))
#     var conn = TCPConnection(sock, laddr, raddr)
#
#     return conn


# fn create_listener(host: String, port: UInt16) raises -> TCPListener:
#     """
#     Create a listener that listens for incoming connections.
#
#     Args:
#         host: String - The host to listen on.
#         port: UInt16 - The port to listen on.
#
#     Returns:
#         TCPListener - The listener.
#     """
#     var addr = TCPAddr(host, Int(port))
#     return TCPListener(addr)
