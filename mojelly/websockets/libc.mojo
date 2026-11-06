# This code is taken from a publicly available repository distributed under the terms of the MIT license:
# https://github.com/msaelices/mojo-websockets/blob/main/LICENSE
from std.memory import OptionalPointer
from mojelly.websockets.aliases import CPointer

# Taken from lightbug_http

from std.collections import Array

from std.ffi import (
    external_call,
    c_char,
    c_uchar,
    c_int,
    c_uint,
    c_long,
    c_short,
    c_ushort,
    c_float,
    c_double,
)
from std.sys import size_of
from mojelly.websockets.aliases import os_is_windows, os_is_macos, os_is_linux
from std.memory import unsafe_memcpy, stack_allocation

from mojelly.websockets.aliases import Bytes

comptime IPPROTO_IPV6 = 41
comptime IPV6_V6ONLY = 26
comptime EPROTONOSUPPORT = 93

# Adapted from https://github.com/gabrieldemarmiesse/mojo-stdlib-extensions/ . Huge thanks to Gabriel!

comptime SUCCESS = 0
comptime GRND_NONBLOCK: UInt8 = 1

comptime char_UnsafePointer = CPointer[c_char]

# Adapted from https://github.com/crisadamo/mojo-Libc . Huge thanks to Cristian!
# C types
comptime c_void = UInt8
comptime c_schar = Int8
comptime c_ulong = UInt64

# `Int` is known to be machine's width
comptime c_size_t = Int
comptime c_ssize_t = Int

comptime ptrdiff_t = Int64
comptime intptr_t = Int64
comptime uintptr_t = UInt64


# --- ( error.h Constants )-----------------------------------------------------
# TODO: These are probably platform specific, we should check the values on each linux and macos.
comptime EPERM = 1
comptime ENOENT = 2
comptime ESRCH = 3
comptime EINTR = 4
comptime EIO = 5
comptime ENXIO = 6
comptime E2BIG = 7
comptime ENOEXEC = 8
comptime EBADF = 9
comptime ECHILD = 10
comptime EAGAIN = 11
comptime ENOMEM = 12
comptime EACCES = 13
comptime EFAULT = 14
comptime ENOTBLK = 15
comptime EBUSY = 16
comptime EEXIST = 17
comptime EXDEV = 18
comptime ENODEV = 19
comptime ENOTDIR = 20
comptime EISDIR = 21
comptime EINVAL = 22
comptime ENFILE = 23
comptime EMFILE = 24
comptime ENOTTY = 25
comptime ETXTBSY = 26
comptime EFBIG = 27
comptime ENOSPC = 28
comptime ESPIPE = 29
comptime EROFS = 30
comptime EMLINK = 31
comptime EPIPE = 32
comptime EDOM = 33
comptime ERANGE = 34
comptime EWOULDBLOCK = EAGAIN
comptime EINPROGRESS = 36 if os_is_macos() else 115
comptime EALREADY = 37 if os_is_macos() else 114
comptime ENOTSOCK = 38 if os_is_macos() else 88
comptime EDESTADDRREQ = 39 if os_is_macos() else 89
comptime EMSGSIZE = 40 if os_is_macos() else 90
comptime ENOPROTOOPT = 42 if os_is_macos() else 92
comptime EAFNOSUPPORT = 47 if os_is_macos() else 97
comptime EADDRINUSE = 48 if os_is_macos() else 98
comptime EADDRNOTAVAIL = 49 if os_is_macos() else 99
comptime ENETDOWN = 50 if os_is_macos() else 100
comptime ENETUNREACH = 51 if os_is_macos() else 101
comptime ECONNABORTED = 53 if os_is_macos() else 103
comptime ECONNRESET = 54 if os_is_macos() else 104
comptime ENOBUFS = 55 if os_is_macos() else 105
comptime EISCONN = 56 if os_is_macos() else 106
comptime ENOTCONN = 57 if os_is_macos() else 107
comptime ETIMEDOUT = 60 if os_is_macos() else 110
comptime ECONNREFUSED = 61 if os_is_macos() else 111
comptime ELOOP = 62 if os_is_macos() else 40
comptime ENAMETOOLONG = 63 if os_is_macos() else 36
comptime EHOSTUNREACH = 65 if os_is_macos() else 113
comptime EDQUOT = 69 if os_is_macos() else 122
comptime ENOMSG = 91 if os_is_macos() else 42
comptime EPROTO = 100 if os_is_macos() else 71
comptime EOPNOTSUPP = 102 if os_is_macos() else 95

# --- ( Network Related Constants )---------------------------------------------
comptime sa_family_t = c_ushort
comptime socklen_t = c_uint
comptime in_addr_t = c_uint
comptime in_port_t = c_ushort

# TODO: These might vary on each platform...we should confirm this.
# Taken from: https://github.com/openbsd/src/blob/master/sys/sys/socket.h#L250
# Address Family Constants
comptime AF_UNSPEC = 0  # unspecified
comptime AF_UNIX = 1  # local to host
comptime AF_LOCAL = AF_UNIX  # draft POSIX compatibility
comptime AF_INET = 2  # internetwork: UDP, TCP, etc.
comptime AF_IMPLINK = 3  # arpanet imp addresses
comptime AF_PUP = 4  # pup protocols: e.g. BSP
comptime AF_CHAOS = 5  # mit CHAOS protocols
comptime AF_NS = 6  # XEROX NS protocols
comptime AF_ISO = 7  # ISO protocols
comptime AF_OSI = AF_ISO
comptime AF_ECMA = 8  # european computer manufacturers
comptime AF_DATAKIT = 9  # datakit protocols
comptime AF_CCITT = 10  # CCITT protocols, X.25 etc
comptime AF_SNA = 11  # IBM SNA
comptime AF_DECnet = 12  # DECnet
comptime AF_DLI = 13  # DEC Direct data link interface
comptime AF_LAT = 14  # LAT
comptime AF_HYLINK = 15  # NSC Hyperchannel
comptime AF_APPLETALK = 16  # Apple Talk
comptime AF_ROUTE = 17  # Internal Routing Protocol
comptime AF_LINK = 18  # Link layer interface
comptime pseudo_AF_XTP = 19  # eXpress Transfer Protocol (no AF)
comptime AF_COIP = 20  # connection-oriented IP, aka ST II
comptime AF_CNT = 21  # Computer Network Technology
comptime pseudo_AF_RTIP = 22  # Help Identify RTIP packets
comptime AF_IPX = 23  # Novell Internet Protocol
comptime AF_INET6 = 30 if os_is_macos() else 10  # IPv6
comptime pseudo_AF_PIP = 25  # Help Identify PIP packets
comptime AF_ISDN = 26  # Integrated Services Digital Network
comptime AF_E164 = AF_ISDN  # CCITT E.164 recommendation
comptime AF_NATM = 27  # native ATM access
comptime AF_ENCAP = 28
comptime AF_SIP = 29  # Simple Internet Protocol
comptime AF_KEY = 30
comptime pseudo_AF_HDRCMPLT = 31  # Used by BPF to not rewrite headers in interface output routine
comptime AF_BLUETOOTH = 32  # Bluetooth
comptime AF_MPLS = 33  # MPLS
comptime pseudo_AF_PFLOW = 34  # pflow
comptime pseudo_AF_PIPEX = 35  # PIPEX
comptime AF_FRAME = 36  # frame (Ethernet) sockets
comptime AF_MAX = 37

# Protocol families, same as address families for now.
comptime PF_UNSPEC = AF_UNSPEC
comptime PF_LOCAL = AF_LOCAL
comptime PF_UNIX = AF_UNIX
comptime PF_INET = AF_INET
comptime PF_IMPLINK = AF_IMPLINK
comptime PF_PUP = AF_PUP
comptime PF_CHAOS = AF_CHAOS
comptime PF_NS = AF_NS
comptime PF_ISO = AF_ISO
comptime PF_OSI = AF_ISO
comptime PF_ECMA = AF_ECMA
comptime PF_DATAKIT = AF_DATAKIT
comptime PF_CCITT = AF_CCITT
comptime PF_SNA = AF_SNA
comptime PF_DECnet = AF_DECnet
comptime PF_DLI = AF_DLI
comptime PF_LAT = AF_LAT
comptime PF_HYLINK = AF_HYLINK
comptime PF_APPLETALK = AF_APPLETALK
comptime PF_ROUTE = AF_ROUTE
comptime PF_LINK = AF_LINK
comptime PF_XTP = pseudo_AF_XTP  # really just proto family, no AF
comptime PF_COIP = AF_COIP
comptime PF_CNT = AF_CNT
comptime PF_IPX = AF_IPX  # same format as = AF_NS
comptime PF_INET6 = AF_INET6
comptime PF_RTIP = pseudo_AF_RTIP  # same format as AF_INET
comptime PF_PIP = pseudo_AF_PIP
comptime PF_ISDN = AF_ISDN
comptime PF_NATM = AF_NATM
comptime PF_ENCAP = AF_ENCAP
comptime PF_SIP = AF_SIP
comptime PF_KEY = AF_KEY
comptime PF_BPF = pseudo_AF_HDRCMPLT
comptime PF_BLUETOOTH = AF_BLUETOOTH
comptime PF_MPLS = AF_MPLS
comptime PF_PFLOW = pseudo_AF_PFLOW
comptime PF_PIPEX = pseudo_AF_PIPEX
comptime PF_FRAME = AF_FRAME
comptime PF_MAX = AF_MAX

# Socket Type constants
comptime SOCK_STREAM = 1
comptime SOCK_DGRAM = 2
comptime SOCK_RAW = 3
comptime SOCK_RDM = 4
comptime SOCK_SEQPACKET = 5
comptime SOCK_DCCP = 6
comptime SOCK_PACKET = 10
comptime SOCK_CLOEXEC = O_CLOEXEC
comptime SOCK_NONBLOCK = O_NONBLOCK

# Address Information
comptime AI_PASSIVE = 1
comptime AI_CANONNAME = 2
comptime AI_NUMERICHOST = 4
comptime AI_V4MAPPED = 8
comptime AI_ALL = 16
comptime AI_ADDRCONFIG = 32
comptime AI_IDN = 64

comptime INET_ADDRSTRLEN = 16
comptime INET6_ADDRSTRLEN = 46

comptime SHUT_RD = 0
comptime SHUT_WR = 1
comptime SHUT_RDWR = 2

comptime SOL_SOCKET = 0xFFFF if os_is_macos() else 1

# Socket option flags
# TODO: These are probably platform specific, on MacOS I have these values, but we should check on Linux.
# Taken from: https://github.com/openbsd/src/blob/master/sys/sys/socket.h
comptime SO_DEBUG = 0x0001
comptime SO_ACCEPTCONN = 0x0002
comptime SO_REUSEADDR = 0x0004 if os_is_macos() else 2
comptime SO_KEEPALIVE = 0x0008 if os_is_macos() else 9
comptime SO_DONTROUTE = 0x0010
comptime SO_BROADCAST = 0x0020
comptime SO_USELOOPBACK = 0x0040
comptime SO_LINGER = 0x0080
comptime SO_OOBINLINE = 0x0100
comptime SO_REUSEPORT = 0x0200
comptime SO_TIMESTAMP = 0x0800
comptime SO_BINDANY = 0x1000
comptime SO_ZEROIZE = 0x2000
comptime SO_SNDBUF = 0x1001
comptime SO_RCVBUF = 0x1002
comptime SO_SNDLOWAT = 0x1003
comptime SO_RCVLOWAT = 0x1004
comptime SO_SNDTIMEO = 0x1005
comptime SO_RCVTIMEO = 0x1006 if os_is_macos() else 20
comptime SO_ERROR = 0x1007 if os_is_macos() else 4
comptime SO_TYPE = 0x1008
comptime SO_NETPROC = 0x1020
comptime SO_RTABLE = 0x1021
comptime SO_PEERCRED = 0x1022
comptime SO_SPLICE = 0x1023
comptime SO_DOMAIN = 0x1024
comptime SO_PROTOCOL = 0x1025


# --- ( Network Related Structs )-----------------------------------------------
@fieldwise_init
struct in_addr(Copyable, Movable):
    var s_addr: in_addr_t


@fieldwise_init
struct in6_addr(Copyable, Movable):
    var s6_addr: Array[c_char, 16]


struct sockaddr(Copyable, Movable):
    var sa_family: sa_family_t
    var sa_data: Array[c_char, 14]

    def __init__(
        out self,
        family: sa_family_t = 0,
        data: Array[c_char, 14] = Array[c_char, 14](),
    ):
        self.sa_family = family
        self.sa_data = data.copy()


struct sockaddr_in(Copyable, Movable):
    var sin_family: sa_family_t
    var sin_port: in_port_t
    var sin_addr: in_addr
    var sin_zero: Array[c_char, 8]

    def __init__(
        out self, address_family: Int, port: UInt16, binary_ip: UInt32
    ):
        """Construct a sockaddr_in struct.

        Args:
            address_family: The address family.
            port: A 16-bit integer port in host byte order, gets converted to network byte order via `htons`.
            binary_ip: The binary representation of the IP address.
        """
        self.sin_family = sa_family_t(address_family)
        self.sin_port = htons(port)
        self.sin_addr = in_addr(binary_ip)
        self.sin_zero = Array[c_char, 8](fill=0)


struct sockaddr_in6(Copyable, Movable):
    var sin6_family: sa_family_t
    var sin6_port: in_port_t
    var sin6_flowinfo: c_uint
    var sin6_addr: in6_addr
    var sin6_scope_id: c_uint


@fieldwise_init
struct addrinfo(Copyable, Movable):
    var ai_flags: c_int
    var ai_family: c_int
    var ai_socktype: c_int
    var ai_protocol: c_int
    var ai_addrlen: socklen_t
    var ai_addr: OptionalPointer[sockaddr, MutUntrackedOrigin]
    var ai_canonname: OptionalPointer[c_char, MutUntrackedOrigin]
    var ai_next: OptionalPointer[c_void, MutUntrackedOrigin]

    def __init__(out self):
        self.ai_flags = 0
        self.ai_family = 0
        self.ai_socktype = 0
        self.ai_protocol = 0
        self.ai_addrlen = 0
        self.ai_addr = None
        self.ai_canonname = None
        self.ai_next = None


# --- ( Network Related Syscalls & Structs )------------------------------------


def htonl(hostlong: c_uint) -> c_uint:
    """Libc POSIX `htonl` function.

    Args:
        hostlong: A 32-bit integer in host byte order.

    Returns:
        The value provided in network byte order.

    #### C Function
    ```c
    uint32_t htonl(uint32_t hostlong)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/htonl.3p.html..
    """
    return external_call["htonl", c_uint](hostlong)


def htons(hostshort: c_ushort) -> c_ushort:
    """Libc POSIX `htons` function.

    Args:
        hostshort: A 16-bit integer in host byte order.

    Returns:
        The value provided in network byte order.

    #### C Function
    ```c
    uint16_t htons(uint16_t hostshort)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/htonl.3p.html..
    """
    return external_call["htons", c_ushort](hostshort)


def ntohl(netlong: c_uint) -> c_uint:
    """Libc POSIX `ntohl` function.

    Args:
        netlong: A 32-bit integer in network byte order.

    Returns:
        The value provided in host byte order.

    #### C Function
    ```c
    uint32_t ntohl(uint32_t netlong)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/htonl.3p.html.
    """
    return external_call["ntohl", c_uint](netlong)


def ntohs(netshort: c_ushort) -> c_ushort:
    """Libc POSIX `ntohs` function.

    Args:
        netshort: A 16-bit integer in network byte order.

    Returns:
        The value provided in host byte order.

    #### C Function
    ```c
    uint16_t ntohs(uint16_t netshort)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/htonl.3p.html.
    """
    return external_call["ntohs", c_ushort](netshort)


def _inet_ntop(
    af: c_int,
    src: Pointer[mut=False, c_void, ImmUntrackedOrigin],
    dst: CPointer[c_char],
    size: socklen_t,
) raises -> CPointer[c_char]:
    """Libc POSIX `inet_ntop` function.

    Args:
        af: Address Family see AF_ aliases.
        src: A UnsafePointer to a binary address.
        dst: A UnsafePointer to a buffer to store the result.
        size: The size of the buffer.

    Returns:
        A UnsafePointer to the buffer containing the result.

    #### C Function
    ```c
    const char *inet_ntop(int af, const void *restrict src, char *restrict dst, socklen_t size)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/inet_ntop.3p.html..
    """
    return external_call["inet_ntop", CPointer[c_char]](af, src, dst, size)


def inet_ntop[
    address_family: Int, address_length: Int
](var ip_address: UInt32) raises -> String:
    # The list owns the buffer, and the nullable libc result is checked before dereferencing
    comptime if address_family != AF_INET:
        raise Error("IPv6 requires a 16-byte address")
    var buffer = List[c_char](length=address_length, fill=0)
    var result = external_call[
        "inet_ntop", OptionalPointer[c_char, MutUntrackedOrigin]
    ](
        Int32(address_family),
        Pointer(to=ip_address),
        buffer.unsafe_ptr(),
        UInt32(address_length),
    )
    if not result:
        raise Error("inet_ntop failed")
    return String(unsafe_from_utf8_ptr=result.value())


def _inet_pton(
    af: c_int, src: CPointer[c_char], dst: CPointer[c_void]
) -> c_int:
    """Libc POSIX `inet_pton` function. Converts a presentation format address (that is, printable form as held in a character string)
    to network format (usually a struct in_addr or some other internal binary representation, in network byte order).
    It returns 1 if the address was valid for the specified address family, or 0 if the address was not parseable in the specified address family,
    or -1 if some system error occurred (in which case errno will have been set).

    Args:
        af: Address Family: `AF_INET` or `AF_INET6`.
        src: A UnsafePointer to a string containing the address.
        dst: A UnsafePointer to a buffer to store the result.

    Returns:
        1 on success, 0 if the input is not a valid address, -1 on error.

    #### C Function
    ```c
    int inet_pton(int af, const char *restrict src, void *restrict dst)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/inet_ntop.3p.html.
    """
    return external_call["inet_pton", c_int](af, src, dst)


def inet_pton[address_family: Int](var src: String) raises -> c_uint:
    comptime if address_family != AF_INET:
        raise Error("IPv6 requires a 16-byte address")
    var address = c_uint(0)
    var status = external_call["inet_pton", Int32](
        Int32(address_family), src.unsafe_ptr(), Pointer(to=address)
    )
    if status != 1:
        raise Error("Invalid IPv4 address")
    return address


def _socket(domain: c_int, type: c_int, protocol: c_int) -> c_int:
    """Libc POSIX `socket` function.

    Args:
        domain: Address Family see AF_ aliases.
        type: Socket Type see SOCK_ aliases.
        protocol: The protocol to use.

    Returns:
        A File Descriptor or -1 in case of failure.

    #### C Function
    ```c
    int socket(int domain, int type, int protocol)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/socket.3p.html.
    """
    return external_call["socket", c_int](domain, type, protocol)


def socket(domain: c_int, type: c_int, protocol: c_int) raises -> c_int:
    """Libc POSIX `socket` function.

    Args:
        domain: Address Family see AF_ aliases.
        type: Socket Type see SOCK_ aliases.
        protocol: The protocol to use.

    Returns:
        A File Descriptor or -1 in case of failure.

    Raises:
        SocketError: If an error occurs while creating the socket.
        EACCES: Permission to create a socket of the specified type and/or protocol is denied.
        EAFNOSUPPORT: The implementation does not support the specified address family.
        EINVAL: Invalid flags in type, Unknown protocol, or protocol family not available.
        EMFILE: The per-process limit on the number of open file descriptors has been reached.
        ENFILE: The system-wide limit on the total number of open files has been reached.
        ENOBUFS or ENOMEM: Insufficient memory is available. The socket cannot be created until sufficient resources are freed.
        EPROTONOSUPPORT: The protocol type or the specified protocol is not supported within this domain.

    #### C Function
    ```c
    int socket(int domain, int type, int protocol)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/socket.3p.html.
    """
    var fd = _socket(domain, type, protocol)
    if fd == -1:
        var errno = Int(get_errno())
        if errno == EACCES:
            raise Error(
                "SocketError (EACCES): Permission to create a socket of the"
                " specified type and/or protocol is denied."
            )
        elif errno == EAFNOSUPPORT:
            raise Error(
                "SocketError (EAFNOSUPPORT): The implementation does not"
                " support the specified address family."
            )
        elif errno == EINVAL:
            raise Error(
                "SocketError (EINVAL): Invalid flags in type, Unknown protocol,"
                " or protocol family not available."
            )
        elif errno == EMFILE:
            raise Error(
                "SocketError (EMFILE): The per-process limit on the number of"
                " open file descriptors has been reached."
            )
        elif errno == ENFILE:
            raise Error(
                "SocketError (ENFILE): The system-wide limit on the total"
                " number of open files has been reached."
            )
        elif Int(errno) in [ENOBUFS, ENOMEM]:
            raise Error(
                "SocketError (ENOBUFS or ENOMEM): Insufficient memory is"
                " available. The socket cannot be created until sufficient"
                " resources are freed."
            )
        elif errno == EPROTONOSUPPORT:
            raise Error(
                "SocketError (EPROTONOSUPPORT): The protocol type or the"
                " specified protocol is not supported within this domain."
            )
        else:
            raise Error(
                "SocketError: An error occurred while creating the socket."
                " Error code: "
                + String(errno)
            )

    return fd


def _setsockopt[
    origin: Origin
](
    socket: c_int,
    level: c_int,
    option_name: c_int,
    option_value: Pointer[c_void, origin],
    option_len: socklen_t,
) -> c_int:
    """Libc POSIX `setsockopt` function.

    Args:
        socket: A File Descriptor.
        level: The protocol level.
        option_name: The option to set.
        option_value: A Pointer to the value to set.
        option_len: The size of the value.

    Returns:
        0 on success, -1 on error.

    #### C Function
    ```c
    int setsockopt(int socket, int level, int option_name, const void *option_value, socklen_t option_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/setsockopt.3p.html.
    """
    return external_call["setsockopt", c_int](
        socket, level, option_name, option_value, option_len
    )


def setsockopt(
    socket: c_int,
    level: c_int,
    option_name: c_int,
    option_value: c_void,
) raises:
    """Libc POSIX `setsockopt` function. Manipulate options for the socket referred to by the file descriptor, `socket`.

    Args:
        socket: A File Descriptor.
        level: The protocol level.
        option_name: The option to set.
        option_value: A UnsafePointer to the value to set.

    Raises:
        Error: If an error occurs while setting the socket option.
        EBADF: The argument `socket` is not a valid descriptor.
        EFAULT: The argument `option_value` points outside the process's allocated address space.
        EINVAL: The argument `option_len` is invalid. Can sometimes occur when `option_value` is invalid.
        ENOPROTOOPT: The option is unknown at the level indicated.
        ENOTSOCK: The argument `socket` is not a socket.

    #### C Function
    ```c
    int setsockopt(int socket, int level, int option_name, const void *option_value, socklen_t option_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/setsockopt.3p.html.
    """
    var result = _setsockopt(
        socket,
        level,
        option_name,
        Pointer(to=option_value),
        socklen_t(size_of[Int]()),
    )
    if result == -1:
        var errno = Int(get_errno())
        if errno == EBADF:
            raise Error(
                "setsockopt: The argument `socket` is not a valid descriptor."
            )
        elif errno == EFAULT:
            raise Error(
                "setsockopt: The argument `option_value` points outside the"
                " process's allocated address space."
            )
        elif errno == EINVAL:
            raise Error(
                "setsockopt: The argument `option_len` is invalid. Can"
                " sometimes occur when `option_value` is invalid."
            )
        elif errno == ENOPROTOOPT:
            raise Error(
                "setsockopt [InvalidProtocol]: The option is unknown at the"
                " level indicated."
            )
        elif errno == ENOTSOCK:
            raise Error("setsockopt: The argument `socket` is not a socket.")
        else:
            raise Error(
                "setsockopt: An error occurred while setting the socket option."
                " Error code: "
                + String(errno)
            )


def _getsockopt[
    len_origin: Origin
](
    socket: c_int,
    level: c_int,
    option_name: c_int,
    option_value: CPointer[c_void],
    option_len: Pointer[socklen_t, len_origin],
) -> c_int:
    """Libc POSIX `setsockopt` function.

    Args:
        socket: A File Descriptor.
        level: The protocol level.
        option_name: The option to set.
        option_value: A Pointer to the value to set.
        option_len: The size of the value.

    Returns:
        0 on success, -1 on error.

    #### C Function
    ```c
    int getsockopt(int socket, int level, int option_name, const void *option_value, socklen_t option_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/setsockopt.3p.html.
    """
    return external_call["getsockopt", c_int](
        socket, level, option_name, option_value, option_len
    )


def getsockopt(
    socket: c_int,
    level: c_int,
    option_name: c_int,
) raises -> Int:
    """Libc POSIX `getsockopt` function. Manipulate options for the socket referred to by the file descriptor, `socket`.

    Args:
        socket: A File Descriptor.
        level: The protocol level.
        option_name: The option to set.

    Returns:
        The value of the option.

    Raises:
        Error: If an error occurs while setting the socket option.
        EBADF: The argument `socket` is not a valid descriptor.
        EFAULT: The argument `option_value` points outside the process's allocated address space.
        EINVAL: The argument `option_len` is invalid. Can sometimes occur when `option_value` is invalid.
        ENOPROTOOPT: The option is unknown at the level indicated.
        ENOTSOCK: The argument `socket` is not a socket.

    #### C Function
    ```c
    int getsockopt(int sockfd, int level, int optname, void optval[restrict *.optlen], socklen_t *restrict optlen);
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/getsockopt.3p.html.
    """
    var option_value = stack_allocation[1, c_void]()
    var option_len = socklen_t(size_of[Int32]())
    var result = _getsockopt(
        socket, level, option_name, option_value, Pointer(to=option_len)
    )
    if result == -1:
        var errno = Int(get_errno())
        if errno == EBADF:
            raise Error(
                "getsockopt: The argument `socket` is not a valid descriptor."
            )
        elif errno == EFAULT:
            raise Error(
                "getsockopt: The argument `option_value` points outside the"
                " process's allocated address space."
            )
        elif errno == EINVAL:
            raise Error(
                "getsockopt: The argument `option_len` is invalid. Can"
                " sometimes occur when `option_value` is invalid."
            )
        elif errno == ENOPROTOOPT:
            raise Error(
                "getsockopt: The option is unknown at the level indicated."
            )
        elif errno == ENOTSOCK:
            raise Error("getsockopt: The argument `socket` is not a socket.")
        else:
            raise Error(
                "getsockopt: An error occurred while setting the socket option."
                " Error code: "
                + String(errno)
            )

    return option_value.unsafe_bitcast[Int]().unsafe_take_pointee()


def _getsockname[
    origin: Origin
](
    socket: c_int,
    address: CPointer[sockaddr],
    address_len: Pointer[socklen_t, origin],
) -> c_int:
    """Libc POSIX `getsockname` function.

    Args:
        socket: A File Descriptor.
        address: A UnsafePointer to a buffer to store the address of the peer.
        address_len: A UnsafePointer to the size of the buffer.

    Returns:
        0 on success, -1 on error.

    #### C Function
    ```c
    int getsockname(int socket, struct sockaddr *restrict address, socklen_t *restrict address_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/getsockname.3p.html.
    """
    return external_call["getsockname", c_int](socket, address, address_len)


def getsockname[
    origin: Origin
](
    socket: c_int,
    address: CPointer[sockaddr],
    address_len: Pointer[socklen_t, origin],
) raises:
    """Libc POSIX `getsockname` function.

    Args:
        socket: A File Descriptor.
        address: A UnsafePointer to a buffer to store the address of the peer.
        address_len: A UnsafePointer to the size of the buffer.

    Raises:
        Error: If an error occurs while getting the socket name.
        EBADF: The argument `socket` is not a valid descriptor.
        EFAULT: The `address` argument points to memory not in a valid part of the process address space.
        EINVAL: `address_len` is invalid (e.g., is negative).
        ENOBUFS: Insufficient resources were available in the system to perform the operation.
        ENOTSOCK: The argument `socket` is not a socket, it is a file.

    #### C Function
    ```c
    int getsockname(int socket, struct sockaddr *restrict address, socklen_t *restrict address_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/getsockname.3p.html.
    """
    var result = _getsockname(socket, address, address_len)
    if result == -1:
        var errno = Int(get_errno())
        if errno == EBADF:
            raise Error(
                "getsockname: The argument `socket` is not a valid descriptor."
            )
        elif errno == EFAULT:
            raise Error(
                "getsockname: The `address` argument points to memory not in a"
                " valid part of the process address space."
            )
        elif errno == EINVAL:
            raise Error(
                "getsockname: `address_len` is invalid (e.g., is negative)."
            )
        elif errno == ENOBUFS:
            raise Error(
                "getsockname: Insufficient resources were available in the"
                " system to perform the operation."
            )
        elif errno == ENOTSOCK:
            raise Error(
                "getsockname: The argument `socket` is not a socket, it is a"
                " file."
            )
        else:
            raise Error(
                "getsockname: An error occurred while getting the socket name."
                " Error code: "
                + String(errno)
            )


def _getpeername[
    origin: Origin
](
    sockfd: c_int,
    addr: CPointer[sockaddr],
    address_len: Pointer[socklen_t, origin],
) -> c_int:
    """Libc POSIX `getpeername` function.

    Args:
        sockfd: A File Descriptor.
        addr: A UnsafePointer to a buffer to store the address of the peer.
        address_len: A UnsafePointer to the size of the buffer.

    Returns:
        0 on success, -1 on error.

    #### C Function
    ```c
    int getpeername(int socket, struct sockaddr *restrict addr, socklen_t *restrict address_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man2/getpeername.2.html.
    """
    return external_call["getpeername", c_int](sockfd, addr, address_len)


def getpeername(file_descriptor: c_int) raises -> sockaddr_in:
    """Libc POSIX `getpeername` function.

    Args:
        file_descriptor: A File Descriptor.

    Raises:
        Error: If an error occurs while getting the socket name.
        EBADF: The argument `socket` is not a valid descriptor.
        EFAULT: The `addr` argument points to memory not in a valid part of the process address space.
        EINVAL: `address_len` is invalid (e.g., is negative).
        ENOBUFS: Insufficient resources were available in the system to perform the operation.
        ENOTCONN: The socket is not connected.
        ENOTSOCK: The argument `socket` is not a socket, it is a file.

    #### C Function
    ```c
    int getpeername(int socket, struct sockaddr *restrict addr, socklen_t *restrict address_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man2/getpeername.2.html.
    """
    var remote_address = stack_allocation[1, sockaddr]()
    var result = _getpeername(
        file_descriptor,
        remote_address,
        Pointer(to=socklen_t(size_of[sockaddr]())),
    )
    if result == -1:
        var errno = Int(get_errno())
        if errno == EBADF:
            raise Error(
                "getpeername: The argument `socket` is not a valid descriptor."
            )
        elif errno == EFAULT:
            raise Error(
                "getpeername: The `addr` argument points to memory not in a"
                " valid part of the process address space."
            )
        elif errno == EINVAL:
            raise Error(
                "getpeername: `address_len` is invalid (e.g., is negative)."
            )
        elif errno == ENOBUFS:
            raise Error(
                "getpeername: Insufficient resources were available in the"
                " system to perform the operation."
            )
        elif errno == ENOTCONN:
            raise Error("getpeername: The socket is not connected.")
        elif errno == ENOTSOCK:
            raise Error(
                "getpeername: The argument `socket` is not a socket, it is a"
                " file."
            )
        else:
            raise Error(
                "getpeername: An error occurred while getting the socket name."
                " Error code: "
                + String(errno)
            )

    # Cast sockaddr struct to sockaddr_in
    return remote_address.unsafe_bitcast[sockaddr_in]().unsafe_take_pointee()


def _bind[
    origin: MutOrigin
](
    socket: c_int, address: Pointer[sockaddr_in, origin], address_len: socklen_t
) -> c_int:
    """Libc POSIX `bind` function.

    Args:
        socket: A File Descriptor.
        address: A UnsafePointer to the address to bind to.
        address_len: The size of the address.

    Returns:
        0 on success, -1 on error.

    #### C Function
    ```c
    int bind(int socket, const struct sockaddr *address, socklen_t address_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/bind.3p.html.
    """
    return external_call["bind", c_int](socket, address, address_len)


def bind(socket: c_int, mut address: sockaddr_in) raises:
    """Libc POSIX `bind` function.

    Args:
        socket: A File Descriptor.
        address: A UnsafePointer to the address to bind to.

    Raises:
        Error: If an error occurs while binding the socket.
        EACCES: The address, `address`, is protected, and the user is not the superuser.
        EADDRINUSE: The given address is already in use.
        EBADF: `socket` is not a valid descriptor.
        EINVAL: The socket is already bound to an address.
        ENOTSOCK: `socket` is a descriptor for a file, not a socket.

        # The following errors are specific to UNIX domain (AF_UNIX) sockets
        EACCES: Search permission is denied on a component of the path prefix. (See also path_resolution(7).)
        EADDRNOTAVAIL: A nonexistent interface was requested or the requested address was not local.
        EFAULT: `address` points outside the user's accessible address space.
        EINVAL: The `address_len` is wrong, or the socket was not in the AF_UNIX family.
        ELOOP: Too many symbolic links were encountered in resolving addr.
        ENAMETOOLONG: `address` is too long.
        ENOENT: The file does not exist.
        ENOMEM: Insufficient kernel memory was available.
        ENOTDIR: A component of the path prefix is not a directory.
        EROFS: The socket inode would reside on a read-only file system.

    #### C Function
    ```c
    int bind(int socket, const struct sockaddr *address, socklen_t address_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/bind.3p.html.
    """
    var result = _bind(
        socket, Pointer(to=address), socklen_t(size_of[sockaddr_in]())
    )
    if result == -1:
        var errno = Int(get_errno())
        if errno == EACCES:
            raise Error(
                "bind: The address, `address`, is protected, and the user is"
                " not the superuser."
            )
        elif errno == EADDRINUSE:
            raise Error("bind: The given address is already in use.")
        elif errno == EBADF:
            raise Error("bind: `socket` is not a valid descriptor.")
        elif errno == EINVAL:
            raise Error("bind: The socket is already bound to an address.")
        elif errno == ENOTSOCK:
            raise Error(
                "bind: `socket` is a descriptor for a file, not a socket."
            )

        # The following errors are specific to UNIX domain (AF_UNIX) sockets. TODO: Pass address_family when unix sockets supported.
        # if address_family == AF_UNIX:
        #     if errno == EACCES:
        #         raise Error("bind: Search permission is denied on a component of the path prefix. (See also path_resolution(7).)")
        #     elif errno == EADDRNOTAVAIL:
        #         raise Error("bind: A nonexistent interface was requested or the requested address was not local.")
        #     elif errno == EFAULT:
        #         raise Error("bind: `address` points outside the user's accessible address space.")
        #     elif errno == EINVAL:
        #         raise Error("bind: The `address_len` is wrong, or the socket was not in the AF_UNIX family.")
        #     elif errno == ELOOP:
        #         raise Error("bind: Too many symbolic links were encountered in resolving addr.")
        #     elif errno == ENAMETOOLONG:
        #         raise Error("bind: `address` is too long.")
        #     elif errno == ENOENT:
        #         raise Error("bind: The file does not exist.")
        #     elif errno == ENOMEM:
        #         raise Error("bind: Insufficient kernel memory was available.")
        #     elif errno == ENOTDIR:
        #         raise Error("bind: A component of the path prefix is not a directory.")
        #     elif errno == EROFS:
        #         raise Error("bind: The socket inode would reside on a read-only file system.")

        raise Error(
            "bind: An error occurred while binding the socket. Error code: "
            + String(errno)
        )


def _listen(socket: c_int, backlog: c_int) -> c_int:
    """Libc POSIX `listen` function.

    Args:
        socket: A File Descriptor.
        backlog: The maximum length of the queue of pending connections.

    Returns:
        0 on success, -1 on error.

    #### C Function
    ```c
    int listen(int socket, int backlog)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/listen.3p.html.
    """
    return external_call["listen", c_int](socket, backlog)


def listen(socket: c_int, backlog: c_int) raises:
    """Libc POSIX `listen` function.

    Args:
        socket: A File Descriptor.
        backlog: The maximum length of the queue of pending connections.

    Raises:
        Error: If an error occurs while listening on the socket.
        EADDRINUSE: Another socket is already listening on the same port.
        EBADF: `socket` is not a valid descriptor.
        ENOTSOCK: `socket` is a descriptor for a file, not a socket.
        EOPNOTSUPP: The socket is not of a type that supports the `listen()` operation.

    #### C Function
    ```c
    int listen(int socket, int backlog)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/listen.3p.html.
    """
    var result = _listen(socket, backlog)
    if result == -1:
        var errno = Int(get_errno())
        if errno == EADDRINUSE:
            raise Error(
                "listen: Another socket is already listening on the same port."
            )
        elif errno == EBADF:
            raise Error("listen: `socket` is not a valid descriptor.")
        elif errno == ENOTSOCK:
            raise Error(
                "listen: `socket` is a descriptor for a file, not a socket."
            )
        elif errno == EOPNOTSUPP:
            raise Error(
                "listen: The socket is not of a type that supports the"
                " `listen()` operation."
            )
        else:
            raise Error(
                "listen: An error occurred while listening on the socket. Error"
                " code: "
                + String(errno)
            )


def _accept[
    address_origin: MutOrigin, len_origin: Origin
](
    socket: c_int,
    address: Pointer[sockaddr, address_origin],
    address_len: Pointer[socklen_t, len_origin],
) -> c_int:
    """Libc POSIX `accept` function.

    Args:
        socket: A File Descriptor.
        address: A UnsafePointer to a buffer to store the address of the peer.
        address_len: A UnsafePointer to the size of the buffer.

    Returns:
        A File Descriptor or -1 in case of failure.

    #### C Function
    ```c
    int accept(int socket, struct sockaddr *restrict address, socklen_t *restrict address_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/accept.3p.html.
    """
    return external_call["accept", c_int](socket, address, address_len)


def accept(socket: c_int) raises -> c_int:
    """Libc POSIX `accept` function.

    Args:
        socket: A File Descriptor.

    Raises:
        Error: If an error occurs while listening on the socket.
        EAGAIN or EWOULDBLOCK: The socket is marked nonblocking and no connections are present to be accepted. POSIX.1-2001 allows either error to be returned for this case, and does not require these constants to have the same value, so a portable application should check for both possibilities.
        EBADF: `socket` is not a valid descriptor.
        ECONNABORTED: `socket` is not a valid descriptor.
        EFAULT: The `address` argument is not in a writable part of the user address space.
        EINTR: The system call was interrupted by a signal that was caught before a valid connection arrived; see `signal(7)`.
        EINVAL: Socket is not listening for connections, or `addr_length` is invalid (e.g., is negative).
        EMFILE: The per-process limit of open file descriptors has been reached.
        ENFILE: The system limit on the total number of open files has been reached.
        ENOBUFS or ENOMEM: Not enough free memory. This often means that the memory allocation is limited by the socket buffer limits, not by the system memory.
        ENOTSOCK: `socket` is a descriptor for a file, not a socket.
        EOPNOTSUPP: The referenced socket is not of type `SOCK_STREAM`.
        EPROTO: Protocol error.

        # Linux specific errors
        EPERM: Firewall rules forbid connection.

    #### C Function
    ```c
    int accept(int socket, struct sockaddr *restrict address, socklen_t *restrict address_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/accept.3p.html.
    """
    var remote_address = sockaddr()
    var result = _accept(
        socket,
        Pointer(to=remote_address),
        Pointer(to=socklen_t(size_of[socklen_t]())),
    )
    if result == -1:
        var errno = Int(get_errno())
        if Int(errno) in [EAGAIN, EWOULDBLOCK]:
            raise Error(
                "accept: The socket is marked nonblocking and no connections"
                " are present to be accepted. POSIX.1-2001 allows either error"
                " to be returned for this case, and does not require these"
                " constants to have the same value, so a portable application"
                " should check for both possibilities.."
            )
        elif errno == EBADF:
            raise Error("accept: `socket` is not a valid descriptor.")
        elif errno == ECONNABORTED:
            raise Error("accept: `socket` is not a valid descriptor.")
        elif errno == EFAULT:
            raise Error(
                "accept: The `address` argument is not in a writable part of"
                " the user address space."
            )
        elif errno == EINTR:
            raise Error(
                "accept: The system call was interrupted by a signal that was"
                " caught before a valid connection arrived; see `signal(7)`."
            )
        elif errno == EINVAL:
            raise Error(
                "accept: Socket is not listening for connections, or"
                " `addr_length` is invalid (e.g., is negative)."
            )
        elif errno == EMFILE:
            raise Error(
                "accept: The per-process limit of open file descriptors has"
                " been reached."
            )
        elif errno == ENFILE:
            raise Error(
                "accept: The system limit on the total number of open files has"
                " been reached."
            )
        elif Int(errno) in [ENOBUFS, ENOMEM]:
            raise Error(
                "accept: Not enough free memory. This often means that the"
                " memory allocation is limited by the socket buffer limits, not"
                " by the system memory."
            )
        elif errno == ENOTSOCK:
            raise Error(
                "accept: `socket` is a descriptor for a file, not a socket."
            )
        elif errno == EOPNOTSUPP:
            raise Error(
                "accept: The referenced socket is not of type `SOCK_STREAM`."
            )
        elif errno == EPROTO:
            raise Error("accept: Protocol error.")

        comptime if os_is_linux():
            if errno == EPERM:
                raise Error("accept: Firewall rules forbid connection.")
        raise Error(
            "accept: An error occurred while listening on the socket. Error"
            " code: "
            + String(errno)
        )

    return result


def _connect[
    origin: Origin
](
    socket: c_int, address: Pointer[sockaddr_in, origin], address_len: socklen_t
) -> c_int:
    """Libc POSIX `connect` function.

    Args: socket: A File Descriptor.
        address: A UnsafePointer to the address to connect to.
        address_len: The size of the address.
    Returns: 0 on success, -1 on error.

    #### C Function
    ```c
    int connect(int socket, const struct sockaddr *address, socklen_t address_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/connect.3p.html.
    """
    return external_call["connect", c_int](socket, address, address_len)


def connect(socket: c_int, address: sockaddr_in) raises:
    """Libc POSIX `connect` function.

    Args:
        socket: A File Descriptor.
        address: The address to connect to.

    Raises:
        Error: If an error occurs while connecting to the socket.
        EACCES: For UNIX domain sockets, which are identified by pathname: Write permission is denied on the socket file, or search permission is denied for one of the directories in the path prefix. (See also path_resolution(7)).
        EADDRINUSE: Local address is already in use.
        EAGAIN: No more free local ports or insufficient entries in the routing cache.
        EALREADY: The socket is nonblocking and a previous connection attempt has not yet been completed.
        EBADF: The file descriptor is not a valid index in the descriptor table.
        ECONNREFUSED: No-one listening on the remote address.
        EFAULT: The socket structure address is outside the user's address space.
        EINPROGRESS: The socket is nonblocking and the connection cannot be completed immediately. It is possible to select(2) or poll(2) for completion by selecting the socket for writing. After select(2) indicates writability, use getsockopt(2) to read the SO_ERROR option at level SOL_SOCKET to determine whether connect() completed successfully (SO_ERROR is zero) or unsuccessfully (SO_ERROR is one of the usual error codes listed here, explaining the reason for the failure).
        EINTR: The system call was interrupted by a signal that was caught.
        EISCONN: The socket is already connected.
        ENETUNREACH: Network is unreachable.
        ENOTSOCK: The file descriptor is not associated with a socket.
        EAFNOSUPPORT: The passed address didn't have the correct address family in its `sa_family` field.
        ETIMEDOUT: Timeout while attempting connection. The server may be too busy to accept new connections.

    #### C Function
    ```c
    int connect(int socket, const struct sockaddr *address, socklen_t address_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/connect.3p.html.
    """
    var result = _connect(
        socket, Pointer(to=address), socklen_t(size_of[sockaddr_in]())
    )
    if result == -1:
        var errno = Int(get_errno())
        if errno == EACCES:
            raise Error(
                "connect: For UNIX domain sockets, which are identified by"
                " pathname: Write permission is denied on the socket file, or"
                " search permission is denied for one of the directories in the"
                " path prefix. (See also path_resolution(7))."
            )
        elif errno == EADDRINUSE:
            raise Error("connect: Local address is already in use.")
        elif errno == EAGAIN:
            raise Error(
                "connect: No more free local ports or insufficient entries in"
                " the routing cache."
            )
        elif errno == EALREADY:
            raise Error(
                "connect: The socket is nonblocking and a previous connection"
                " attempt has not yet been completed."
            )
        elif errno == EBADF:
            raise Error(
                "connect: The file descriptor is not a valid index in the"
                " descriptor table."
            )
        elif errno == ECONNREFUSED:
            raise Error("connect: No-one listening on the remote address.")
        elif errno == EFAULT:
            raise Error(
                "connect: The socket structure address is outside the user's"
                " address space."
            )
        elif errno == EINPROGRESS:
            raise Error(
                "connect: The socket is nonblocking and the connection cannot"
                " be completed immediately. It is possible to select(2) or"
                " poll(2) for completion by selecting the socket for writing."
                " After select(2) indicates writability, use getsockopt(2) to"
                " read the SO_ERROR option at level SOL_SOCKET to determine"
                " whether connect() completed successfully (SO_ERROR is zero)"
                " or unsuccessfully (SO_ERROR is one of the usual error codes"
                " listed here, explaining the reason for the failure)."
            )
        elif errno == EINTR:
            raise Error(
                "connect: The system call was interrupted by a signal that was"
                " caught."
            )
        elif errno == EISCONN:
            raise Error("connect: The socket is already connected.")
        elif errno == ENETUNREACH:
            raise Error("connect: Network is unreachable.")
        elif errno == ENOTSOCK:
            raise Error(
                "connect: The file descriptor is not associated with a socket."
            )
        elif errno == EAFNOSUPPORT:
            raise Error(
                "connect: The passed address didn't have the correct address"
                " family in its `sa_family` field."
            )
        elif errno == ETIMEDOUT:
            raise Error(
                "connect: Timeout while attempting connection. The server may"
                " be too busy to accept new connections."
            )
        else:
            raise Error(
                "connect: An error occurred while connecting to the socket."
                " Error code: "
                + String(errno)
            )


def _recv(
    socket: c_int,
    buffer: Pointer[UInt8, _],
    length: c_size_t,
    flags: c_int,
) -> c_ssize_t:
    """Libc POSIX `recv` function.

    Args:
        socket: A File Descriptor.
        buffer: A UnsafePointer to the buffer to store the received data.
        length: The size of the buffer.
        flags: Flags to control the behaviour of the function.

    Returns:
        The number of bytes received or -1 in case of failure.

    #### C Function
    ```c
    ssize_t recv(int socket, void *buffer, size_t length, int flags)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/recv.3p.html.
    """
    return external_call["recv", c_ssize_t](socket, buffer, length, flags)


def recv(
    socket: c_int,
    buffer: Pointer[UInt8, _],
    length: c_size_t,
    flags: c_int,
) raises -> c_ssize_t:
    """Libc POSIX `recv` function.

    Args:
        socket: A File Descriptor.
        buffer: A UnsafePointer to the buffer to store the received data.
        length: The size of the buffer.
        flags: Flags to control the behaviour of the function.

    Returns:
        The number of bytes received.

    #### C Function
    ```c
    ssize_t recv(int socket, void *buffer, size_t length, int flags)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/recv.3p.html.
    """
    var result = _recv(socket, buffer, length, flags)
    if result == -1:
        var errno = Int(get_errno())
        if Int(errno) in [EAGAIN, EWOULDBLOCK]:
            raise Error(
                "ReceiveError: The socket is marked nonblocking and the receive"
                " operation would block, or a receive timeout had been set and"
                " the timeout expired before data was received."
            )
        elif errno == EBADF:
            raise Error(
                "ReceiveError: The argument `socket` is an invalid descriptor."
            )
        elif errno == ECONNREFUSED:
            raise Error(
                "ReceiveError: The remote host refused to allow the network"
                " connection (typically because it is not running the requested"
                " service)."
            )
        elif errno == EFAULT:
            raise Error(
                "ReceiveError: `buffer` points outside the process's address"
                " space."
            )
        elif errno == EINTR:
            raise Error(
                "ReceiveError: The receive was interrupted by delivery of a"
                " signal before any data were available."
            )
        elif errno == ENOTCONN:
            raise Error("ReceiveError: The socket is not connected.")
        elif errno == ENOTSOCK:
            raise Error(
                "ReceiveError: The file descriptor is not associated with a"
                " socket."
            )
        else:
            raise Error(
                "ReceiveError: An error occurred while attempting to receive"
                " data from the socket. Error code: "
                + String(errno)
            )

    return result


def _recvfrom[
    origin: Origin
](
    socket: c_int,
    buffer: CPointer[c_void],
    length: c_size_t,
    flags: c_int,
    address: CPointer[sockaddr],
    address_len: Pointer[socklen_t, origin],
) -> c_ssize_t:
    """Libc POSIX `recvfrom` function.

    Args:
        socket: Specifies the socket file descriptor.
        buffer: Points to the buffer where the message should be stored.
        length: Specifies the length in bytes of the buffer pointed to by the buffer argument.
        flags: Specifies the type of message reception.
        address: A null pointer, or points to a sockaddr structure in which the sending address is to be stored.
        address_len: Either a null pointer, if address is a null pointer, or a pointer to a socklen_t object which on input specifies the length of the supplied sockaddr structure, and on output specifies the length of the stored address.

    Returns:
        The number of bytes received or -1 in case of failure.

    #### C Function
    ```c
    ssize_t recvfrom(int socket, void *restrict buffer, size_t length,
        int flags, struct sockaddr *restrict address,
        socklen_t *restrict address_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/recvfrom.3p.html.
    * Valid Flags:
        * `MSG_PEEK`: Peeks at an incoming message. The data is treated as unread and the next recvfrom() or similar function shall still return this data.
        * `MSG_OOB`: Requests out-of-band data. The significance and semantics of out-of-band data are protocol-specific.
        * `MSG_WAITALL`: On SOCK_STREAM sockets this requests that the function block until the full amount of data can be returned. The function may return the smaller amount of data if the socket is a message-based socket, if a signal is caught, if the connection is terminated, if MSG_PEEK was specified, or if an error is pending for the socket.

    """
    return external_call["recvfrom", c_ssize_t](
        socket, buffer, length, flags, address, address_len
    )


def recvfrom(
    socket: c_int,
    buffer: CPointer[c_void],
    length: c_size_t,
    flags: c_int,
    address: CPointer[sockaddr],
) raises -> c_size_t:
    """Libc POSIX `recvfrom` function.

    Args:
        socket: Specifies the socket file descriptor.
        buffer: Points to the buffer where the message should be stored.
        length: Specifies the length in bytes of the buffer pointed to by the buffer argument.
        flags: Specifies the type of message reception.
        address: A null pointer, or points to a sockaddr structure in which the sending address is to be stored.

    Returns:
        The number of bytes received.

    #### C Function
    ```c
    ssize_t recvfrom(int socket, void *restrict buffer, size_t length,
        int flags, struct sockaddr *restrict address,
        socklen_t *restrict address_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/recvfrom.3p.html.
    * Valid Flags:
        * `MSG_PEEK`: Peeks at an incoming message. The data is treated as unread and the next recvfrom() or similar function shall still return this data.
        * `MSG_OOB`: Requests out-of-band data. The significance and semantics of out-of-band data are protocol-specific.
        * `MSG_WAITALL`: On SOCK_STREAM sockets this requests that the function block until the full amount of data can be returned. The function may return the smaller amount of data if the socket is a message-based socket, if a signal is caught, if the connection is terminated, if MSG_PEEK was specified, or if an error is pending for the socket.

    """
    var address_length = socklen_t(size_of[sockaddr]())
    var result = _recvfrom(
        socket,
        buffer,
        length,
        flags,
        address,
        Pointer(to=address_length),
    )
    if result == -1:
        var errno = Int(get_errno())
        if Int(errno) in [EAGAIN, EWOULDBLOCK]:
            raise "ReceiveError: The socket's file descriptor is marked `O_NONBLOCK` and no data is waiting to be received; or MSG_OOB is set and no out-of-band data is available and either the socket's file descriptor is marked `O_NONBLOCK` or the socket does not support blocking to await out-of-band data."
        elif errno == EBADF:
            raise "ReceiveError: The socket argument is not a valid file descriptor."
        elif errno == ECONNRESET:
            raise "ReceiveError: A connection was forcibly closed by a peer."
        elif errno == EINTR:
            raise "ReceiveError: A signal interrupted `recvfrom()` before any data was available."
        elif errno == EINVAL:
            raise "ReceiveError: The `MSG_OOB` flag is set and no out-of-band data is available."
        elif errno == ENOTCONN:
            raise "ReceiveError: A receive is attempted on a connection-mode socket that is not connected."
        elif errno == ENOTSOCK:
            raise "ReceiveError: The socket argument does not refer to a socket."
        elif errno == EOPNOTSUPP:
            raise "ReceiveError: The specified flags are not supported for this socket type."
        elif errno == ETIMEDOUT:
            raise "ReceiveError: The connection timed out during connection establishment, or due to a transmission timeout on active connection."
        elif errno == EIO:
            raise "ReceiveError: An I/O error occurred while reading from or writing to the file system."
        elif errno == ENOBUFS:
            raise "ReceiveError: Insufficient resources were available in the system to perform the operation."
        elif errno == ENOMEM:
            raise "ReceiveError: Insufficient memory was available to fulfill the request."
        else:
            raise "ReceiveError: An error occurred while attempting to receive data from the socket. Error code: " + String(
                errno
            )

    return result


def _send(
    socket: c_int, buffer: CPointer[c_void], length: c_size_t, flags: c_int
) -> c_ssize_t:
    """Libc POSIX `send` function.

    Args:
        socket: A File Descriptor.
        buffer: A UnsafePointer to the buffer to send.
        length: The size of the buffer.
        flags: Flags to control the behaviour of the function.

    Returns:
        The number of bytes sent or -1 in case of failure.

    #### C Function
    ```c
    ssize_t send(int socket, const void *buffer, size_t length, int flags)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/send.3p.html.
    """
    return external_call["send", c_ssize_t](socket, buffer, length, flags)


def send(
    socket: c_int, buffer: CPointer[c_void], length: c_size_t, flags: c_int
) raises -> c_size_t:
    """Libc POSIX `send` function.

    Args:
        socket: A File Descriptor.
        buffer: A UnsafePointer to the buffer to send.
        length: The size of the buffer.
        flags: Flags to control the behaviour of the function.

    Returns:
        The number of bytes sent.

    Raises:
        Error: If an error occurs while attempting to receive data from the socket.
        EAGAIN or EWOULDBLOCK: The socket is marked nonblocking and the receive operation would block, or a receive timeout had been set and the timeout expired before data was received.
        EBADF: The argument `socket` is an invalid descriptor.
        ECONNRESET: Connection reset by peer.
        EDESTADDRREQ: The socket is not connection-mode, and no peer address is set.
        ECONNREFUSED: The remote host refused to allow the network connection (typically because it is not running the requested service).
        EFAULT: `buffer` points outside the process's address space.
        EINTR: The receive was interrupted by delivery of a signal before any data were available.
        EINVAL: Invalid argument passed.
        EISCONN: The connection-mode socket was connected already but a recipient was specified.
        EMSGSIZE: The socket type requires that message be sent atomically, and the size of the message to be sent made this impossible.
        ENOBUFS: The output queue for a network interface was full. This generally indicates that the interface has stopped sending, but may be caused by transient congestion.
        ENOMEM: No memory available.
        ENOTCONN: The socket is not connected.
        ENOTSOCK: The file descriptor is not associated with a socket.
        EOPNOTSUPP: Some bit in the flags argument is inappropriate for the socket type.
        EPIPE: The local end has been shut down on a connection oriented socket. In this case the process will also receive a SIGPIPE unless MSG_NOSIGNAL is set.

    #### C Function
    ```c
    ssize_t send(int socket, const void *buffer, size_t length, int flags)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/send.3p.html.
    """
    var result = _send(socket, buffer, length, flags)
    if result == -1:
        var errno = Int(get_errno())
        if Int(errno) in [EAGAIN, EWOULDBLOCK]:
            raise Error(
                "SendError: The socket is marked nonblocking and the receive"
                " operation would block, or a receive timeout had been set and"
                " the timeout expired before data was received."
            )
        elif errno == EBADF:
            raise Error(
                "SendError: The argument `socket` is an invalid descriptor."
            )
        elif errno == EAGAIN:
            raise Error(
                "SendError: No more free local ports or insufficient entries in"
                " the routing cache."
            )
        elif errno == ECONNRESET:
            raise Error("SendError: Connection reset by peer.")
        elif errno == EDESTADDRREQ:
            raise Error(
                "SendError: The socket is not connection-mode, and no peer"
                " address is set."
            )
        elif errno == ECONNREFUSED:
            raise Error(
                "SendError: The remote host refused to allow the network"
                " connection (typically because it is not running the requested"
                " service)."
            )
        elif errno == EFAULT:
            raise Error(
                "SendError: `buffer` points outside the process's address"
                " space."
            )
        elif errno == EINTR:
            raise Error(
                "SendError: The receive was interrupted by delivery of a signal"
                " before any data were available."
            )
        elif errno == EINVAL:
            raise Error("SendError: Invalid argument passed.")
        elif errno == EISCONN:
            raise Error(
                "SendError: The connection-mode socket was connected already"
                " but a recipient was specified."
            )
        elif errno == EMSGSIZE:
            raise Error(
                "SendError: The socket type requires that message be sent"
                " atomically, and the size of the message to be sent made this"
                " impossible.."
            )
        elif errno == ENOBUFS:
            raise Error(
                "SendError: The output queue for a network interface was full."
                " This generally indicates that the interface has stopped"
                " sending, but may be caused by transient congestion."
            )
        elif errno == ENOMEM:
            raise Error("SendError: No memory available.")
        elif errno == ENOTCONN:
            raise Error("SendError: The socket is not connected.")
        elif errno == ENOTSOCK:
            raise Error(
                "SendError: The file descriptor is not associated with a"
                " socket."
            )
        elif errno == EOPNOTSUPP:
            raise Error(
                "SendError: Some bit in the flags argument is inappropriate for"
                " the socket type."
            )
        elif errno == EPIPE:
            raise Error(
                "SendError: The local end has been shut down on a connection"
                " oriented socket. In this case the process will also receive a"
                " SIGPIPE unless MSG_NOSIGNAL is set."
            )
        else:
            raise Error(
                "SendError: An error occurred while attempting to receive data"
                " from the socket. Error code: "
                + String(errno)
            )

    return result


def _sendto(
    socket: c_int,
    message: Pointer[mut=False, c_void, ImmUntrackedOrigin],
    length: c_size_t,
    flags: c_int,
    dest_addr: CPointer[sockaddr],
    dest_len: socklen_t,
) -> c_ssize_t:
    """Libc POSIX `sendto` function

    Args:
        socket: Specifies the socket file descriptor.
        message: Points to a buffer containing the message to be sent.
        length: Specifies the size of the message in bytes.
        flags: Specifies the type of message transmission.
        dest_addr: Points to a sockaddr structure containing the destination address.
        dest_len: Specifies the length of the sockaddr.

    Returns:
        The number of bytes sent or -1 in case of failure.

    #### C Function
    ```c
    ssize_t sendto(int socket, const void *message, size_t length,
    int flags, const struct sockaddr *dest_addr,
    socklen_t dest_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/sendto.3p.html.
    * Valid Flags:
        * `MSG_EOR`: Terminates a record (if supported by the protocol).
        * `MSG_OOB`: Sends out-of-band data on sockets that support out-of-band data. The significance and semantics of out-of-band data are protocol-specific.
        * `MSG_NOSIGNAL`: Requests not to send the SIGPIPE signal if an attempt to send is made on a stream-oriented socket that is no longer connected. The [EPIPE] error shall still be returned.
    """
    return external_call["sendto", c_ssize_t](
        socket, message, length, flags, dest_addr, dest_len
    )


def sendto(
    socket: c_int,
    message: CPointer[c_void],
    length: c_size_t,
    flags: c_int,
    dest_addr: CPointer[sockaddr],
) raises -> c_size_t:
    """Libc POSIX `sendto` function.

    Args:
        socket: Specifies the socket file descriptor.
        message: Points to a buffer containing the message to be sent.
        length: Specifies the size of the message in bytes.
        flags: Specifies the type of message transmission.
        dest_addr: Points to a sockaddr structure containing the destination address.

    Raises:
        Error: If an error occurs while attempting to send data to the socket.
        EAFNOSUPPORT: Addresses in the specified address family cannot be used with this socket.
        EAGAIN or EWOULDBLOCK: The socket's file descriptor is marked `O_NONBLOCK` and the requested operation would block.
        EBADF: The socket argument is not a valid file descriptor.
        ECONNRESET: A connection was forcibly closed by a peer.
        EINTR: A signal interrupted `sendto()` before any data was transmitted.
        EMSGSIZE: The message is too large to be sent all at once, as the socket requires.
        ENOTCONN: The socket is connection-mode but is not connected.
        ENOTSOCK: The socket argument does not refer to a socket.
        EPIPE: The socket is shut down for writing, or the socket is connection-mode and is no longer connected.
        EACCES: Search permission is denied for a component of the path prefix; or write access to the named socket is denied.
        EDESTADDRREQ: The socket is not connection-mode and does not have its peer address set, and no destination address was specified.
        EHOSTUNREACH: The destination host cannot be reached (probably because the host is down or a remote router cannot reach it).
        EINVAL: The `dest_len` argument is not a valid length for the address family.
        EIO: An I/O error occurred while reading from or writing to the file system.
        ENETDOWN: The local network interface used to reach the destination is down.
        ENETUNREACH: No route to the network is present.
        ENOBUFS: Insufficient resources were available in the system to perform the operation.
        ENOMEM: Insufficient memory was available to fulfill the request.
        ELOOP: More than `SYMLOOP_MAX` symbolic links were encountered during resolution of the pathname in the socket address.
        ENAMETOOLONG: The length of a pathname exceeds `PATH_MAX`, or pathname resolution of a symbolic link produced an intermediate result with a length that exceeds `PATH_MAX`.

    #### C Function
    ```c
    ssize_t sendto(int socket, const void *message, size_t length,
    int flags, const struct sockaddr *dest_addr,
    socklen_t dest_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/sendto.3p.html.
    * Valid Flags:
        * `MSG_EOR`: Terminates a record (if supported by the protocol).
        * `MSG_OOB`: Sends out-of-band data on sockets that support out-of-band data. The significance and semantics of out-of-band data are protocol-specific.
        * `MSG_NOSIGNAL`: Requests not to send the SIGPIPE signal if an attempt to send is made on a stream-oriented socket that is no longer connected. The [EPIPE] error shall still be returned.

    """
    var result = _sendto(
        socket,
        message,
        length,
        flags,
        dest_addr,
        socklen_t(size_of[sockaddr]()),
    )
    if result == -1:
        var errno = Int(get_errno())
        if errno == EAFNOSUPPORT:
            raise "SendToError (EAFNOSUPPORT): Addresses in the specified address family cannot be used with this socket."
        elif Int(errno) in [EAGAIN, EWOULDBLOCK]:
            raise "SendToError (EAGAIN/EWOULDBLOCK): The socket's file descriptor is marked `O_NONBLOCK` and the requested operation would block."
        elif errno == EBADF:
            raise "SendToError (EBADF): The socket argument is not a valid file descriptor."
        elif errno == ECONNRESET:
            raise "SendToError (ECONNRESET): A connection was forcibly closed by a peer."
        elif errno == EINTR:
            raise "SendToError (EINTR): A signal interrupted `sendto()` before any data was transmitted."
        elif errno == EMSGSIZE:
            raise "SendToError (EMSGSIZE): The message is too large to be sent all at once, as the socket requires."
        elif errno == ENOTCONN:
            raise "SendToError (ENOTCONN): The socket is connection-mode but is not connected."
        elif errno == ENOTSOCK:
            raise "SendToError (ENOTSOCK): The socket argument does not refer to a socket."
        elif errno == EPIPE:
            raise "SendToError (EPIPE): The socket is shut down for writing, or the socket is connection-mode and is no longer connected."
        elif errno == EACCES:
            raise "SendToError (EACCES): Search permission is denied for a component of the path prefix; or write access to the named socket is denied."
        elif errno == EDESTADDRREQ:
            raise "SendToError (EDESTADDRREQ): The socket is not connection-mode and does not have its peer address set, and no destination address was specified."
        elif errno == EHOSTUNREACH:
            raise "SendToError (EHOSTUNREACH): The destination host cannot be reached (probably because the host is down or a remote router cannot reach it)."
        elif errno == EINVAL:
            raise "SendToError (EINVAL): The dest_len argument is not a valid length for the address family."
        elif errno == EIO:
            raise "SendToError (EIO): An I/O error occurred while reading from or writing to the file system."
        elif errno == EISCONN:
            raise "SendToError (EISCONN): A destination address was specified and the socket is already connected."
        elif errno == ENETDOWN:
            raise "SendToError (ENETDOWN): The local network interface used to reach the destination is down."
        elif errno == ENETUNREACH:
            raise "SendToError (ENETUNREACH): No route to the network is present."
        elif errno == ENOBUFS:
            raise "SendToError (ENOBUFS): Insufficient resources were available in the system to perform the operation."
        elif errno == ENOMEM:
            raise "SendToError (ENOMEM): Insufficient memory was available to fulfill the request."
        elif errno == ELOOP:
            raise "SendToError (ELOOP): More than `SYMLOOP_MAX` symbolic links were encountered during resolution of the pathname in the socket address."
        elif errno == ENAMETOOLONG:
            raise "SendToError (ENAMETOOLONG): The length of a pathname exceeds `PATH_MAX`, or pathname resolution of a symbolic link produced an intermediate result with a length that exceeds `PATH_MAX`."
        else:
            raise "SendToError: An error occurred while attempting to send data to the socket. Error code: " + String(
                errno
            )

    return result


def _shutdown(socket: c_int, how: c_int) -> c_int:
    """Libc POSIX `shutdown` function.

    Args:
        socket: A File Descriptor.
        how: How to shutdown the socket.

    Returns:
        0 on success, -1 on error.

    #### C Function
    ```c
    int shutdown(int socket, int how)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/shutdown.3p.html.
    """
    return external_call["shutdown", c_int](socket, how)


def dup(fd: c_int) -> c_int:
    """Libc POSIX `dup2` function.

    Args:
        fd: The file descriptor to duplicate.

    Returns:
        The new file descriptor, -1 on error.

    #### C Function
    ```c
    int dup(int oldfd);
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man2/dup.2.html.
    """
    return external_call["dup", c_int](fd)


comptime ShutdownInvalidDescriptorError = (
    "ShutdownError (EBADF): The argument `socket` is an invalid descriptor."
)
comptime ShutdownInvalidArgumentError = (
    "ShutdownError (EINVAL): Invalid argument passed."
)
comptime ShutdownNotConnectedError = (
    "ShutdownError (ENOTCONN): The socket is not connected."
)
comptime ShutdownNotSocketError = (
    "ShutdownError (ENOTSOCK): The file descriptor is not associated with a"
    " socket."
)


def shutdown(socket: c_int, how: c_int) raises:
    """Libc POSIX `shutdown` function.

    Args:
        socket: A File Descriptor.
        how: How to shutdown the socket.

    Raises:
        Error: If an error occurs while attempting to receive data from the socket.
        EBADF: The argument `socket` is an invalid descriptor.
        EINVAL: Invalid argument passed.
        ENOTCONN: The socket is not connected.
        ENOTSOCK: The file descriptor is not associated with a socket.

    #### C Function
    ```c
    int shutdown(int socket, int how)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/shutdown.3p.html.
    """
    var result = _shutdown(socket, how)
    if result == -1:
        var errno = Int(get_errno())
        if errno == EBADF:
            raise ShutdownInvalidDescriptorError
        elif errno == EINVAL:
            raise ShutdownInvalidArgumentError
        elif errno == ENOTCONN:
            raise ShutdownNotConnectedError
        elif errno == ENOTSOCK:
            raise ShutdownNotSocketError
        else:
            raise Error(
                "ShutdownError: An error occurred while attempting to receive"
                " data from the socket. Error code: "
                + String(errno)
            )


def gai_strerror(ecode: c_int) -> CPointer[c_char]:
    """Libc POSIX `gai_strerror` function.

    Args:
        ecode: The error code.

    Returns:
        A UnsafePointer to a string describing the error.

    #### C Function
    ```c
    const char *gai_strerror(int ecode)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/gai_strerror.3p.html.
    """
    return external_call["gai_strerror", CPointer[c_char]](ecode)


# --- ( File Related Syscalls & Structs )---------------------------------------
comptime O_NONBLOCK = 4 if os_is_macos() else 2048
comptime O_ACCMODE = 3
comptime O_CLOEXEC = 524288


def _close(fildes: c_int) -> c_int:
    """Libc POSIX `close` function.

    Args:
        fildes: A File Descriptor to close.

    Returns:
        Upon successful completion, 0 shall be returned; otherwise, -1
        shall be returned and errno set to indicate the error.

    #### C Function
    ```c
    int close(int fildes).
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/close.3p.html.
    """
    return external_call["close", c_int](fildes)


comptime CloseInvalidDescriptorError = (
    "CloseError (EBADF): The file_descriptor argument is not a valid open file"
    " descriptor."
)
comptime CloseInterruptedError = (
    "CloseError (EINTR): The close() function was interrupted by a signal."
)
comptime CloseRWError = (
    "CloseError (EIO): An I/O error occurred while reading from or writing to"
    " the file system."
)
comptime CloseOutOfSpaceError = (
    "CloseError (ENOSPC or EDQUOT): On NFS, these errors are not normally"
    " reported against the first write which exceeds the available storage"
    " space, but instead against a subsequent write(2), fsync(2), or close()."
)


def close(file_descriptor: c_int) raises:
    """Libc POSIX `close` function.

    Args:
        file_descriptor: A File Descriptor to close.

    Raises:
        SocketError: If an error occurs while creating the socket.
        EACCES: Permission to create a socket of the specified type and/or protocol is denied.
        EAFNOSUPPORT: The implementation does not support the specified address family.
        EINVAL: Invalid flags in type, Unknown protocol, or protocol family not available.
        EMFILE: The per-process limit on the number of open file descriptors has been reached.
        ENFILE: The system-wide limit on the total number of open files has been reached.
        ENOBUFS or ENOMEM: Insufficient memory is available. The socket cannot be created until sufficient resources are freed.
        EPROTONOSUPPORT: The protocol type or the specified protocol is not supported within this domain.

    #### C Function
    ```c
    int close(int fildes)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/close.3p.html.
    """
    if _close(file_descriptor) == -1:
        var errno = Int(get_errno())
        if errno == EBADF:
            raise CloseInvalidDescriptorError
        elif errno == EINTR:
            raise CloseInterruptedError
        elif errno == EIO:
            raise CloseRWError
        elif Int(errno) in [ENOSPC, EDQUOT]:
            raise CloseOutOfSpaceError
        else:
            raise Error(
                "SocketError: An error occurred while creating the socket."
                " Error code: "
                + String(errno)
            )


def get_errno() -> c_int:
    """Get a copy of the current value of the `errno` global variable for
    the current thread.

    Returns:
        A copy of the current value of `errno` for the current thread.
    """

    comptime if os_is_windows():
        var errno = stack_allocation[1, c_int]()
        _ = external_call["_get_errno", c_void](errno)
        return errno[]
    else:
        comptime loc = "__error" if os_is_macos() else "__errno_location"
        return external_call[loc, CPointer[c_int]]()[]
