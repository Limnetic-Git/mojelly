# This code is taken from a publicly available repository distributed under the terms of the MIT license:
# https://github.com/msaelices/mojo-websockets/blob/main/LICENSE
from std.base64 import b64encode
from std.collections import Dict, Optional
from std.collections import Span
from std.collections.string import StringSpan

from mojelly.websockets.aliases import Bytes, Duration, DEFAULT_BUFFER_SIZE
from mojelly.websockets.libc import AF_INET6
from mojelly.websockets.logger import logger
from mojelly.websockets.utils.bytes import byte, bytes
from mojelly.websockets.utils.string import (
    ByteReader,
    ByteWriter,
    BytesConstant,
    is_newline,
    is_space,
    LINE_BREAK,
    N_CHAR,
    R_CHAR,
    HTTP11,
    SLASH,
    to_string,
    WHITESPACE,
)
from mojelly.websockets.utils.time import now
from mojelly.websockets.utils.uri import URI
from mojelly.websockets.net import (
    TCPAddr,
    TCPConnection,
    get_address_info,
    addrinfo_macos,
    addrinfo_unix,
)


struct HeaderKey(Copyable, Movable):
    comptime CONNECTION = "connection"
    comptime CONTENT_TYPE = "content-type"
    comptime CONTENT_LENGTH = "content-length"
    comptime CONTENT_ENCODING = "content-encoding"
    comptime TRANSFER_ENCODING = "transfer-encoding"
    comptime DATE = "date"
    comptime LOCATION = "location"
    comptime HOST = "host"
    comptime SERVER = "server"
    comptime SET_COOKIE = "set-cookie"
    comptime COOKIE = "cookie"


struct StatusCode(Copyable, Movable):
    comptime OK = 200
    comptime MOVED_PERMANENTLY = 301
    comptime FOUND = 302
    comptime TEMPORARY_REDIRECT = 307
    comptime PERMANENT_REDIRECT = 308
    comptime NOT_FOUND = 404
    comptime INTERNAL_ERROR = 500


@fieldwise_init
struct Header(Copyable, Movable, Writable):
    var key: String
    var value: String

    def __str__(self) -> String:
        return String(self)

    def write_to[T: Writer, //](self, mut writer: T):
        writer.write(self.key + ": ", self.value, LINE_BREAK)


@inline(.always)
def write_header[W: Writer](mut writer: W, key: String, value: String):
    writer.write(key + ": ", value, LINE_BREAK)


@inline(.always)
def write_header(mut writer: ByteWriter, key: String, mut value: String):
    var k = key + ": "
    writer.write(k)
    writer.write(value)
    writer.write(LINE_BREAK)


@inline(.always)
def encode(var req: HTTPRequest) -> Bytes:
    return req^.encode()


@inline(.always)
def encode(var res: HTTPResponse) -> Bytes:
    return res^.encode()


def get_date_timestamp() -> String:
    """
    Get the UTC String for the Date HTTP header.
    """
    # TODO: Return a UTC string valid in Date HTTP header, like "Thu, 02 Jan 2025 22:16:23 GMT"
    # See https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Date
    try:
        return now(utc=True).__str__()
    except e:
        return String(e)


def build_host_header(host: String, port: Int, secure: Bool) raises -> String:
    """
    Build a `Host` HTTP header.
    """
    # https://datatracker.ietf.org/doc/html/rfc3986#section-3.2.2
    # IPv6 addresses must be enclosed in brackets.
    var host_header = host
    if ":" in host and not host.startswith("["):
        host_header = "[" + host + "]"

    if port != (443 if secure else 80):
        host_header = host_header + ":" + String(port)

    return host_header


def build_authorization_basic(
    username: String, password: String
) raises -> String:
    """
    Build an `Authorization` header for HTTP Basic Auth.
    """
    # https://datatracker.ietf.org/doc/html/rfc7617#section-2
    var user_pass = username + ":" + password
    var basic_credentials = b64encode(user_pass)
    return "Basic " + basic_credentials


@fieldwise_init
struct Headers(Copyable, Equatable, Movable, Writable):
    """Represents the header key/values in an http request/response.

    Header keys are normalized to lowercase
    """

    var _inner: Dict[String, String]

    def __init__(out self):
        self._inner = Dict[String, String]()

    def __init__(out self, var *headers: Header):
        self._inner = Dict[String, String]()
        for header in headers:
            self[header.key.lower()] = header.value

    def __eq__(self, other: Headers) -> Bool:
        if len(self._inner) != len(other._inner):
            return False
        for item in self._inner.items():
            var key = item.key
            var value = item.value
            if key not in other._inner or other._inner.get(key) != value:
                return False
        return True

    def __ne__(self, other: Self) -> Bool:
        return not (self == other)

    @inline(.always)
    def __contains__(self, key: String) -> Bool:
        return key.lower() in self._inner

    @inline(.always)
    def __getitem__(self, key: String) raises -> String:
        return self._inner[key.lower()]

    @inline(.always)
    def __setitem__(mut self, key: String, value: String):
        self._inner[key.lower()] = value

    def __str__(self) -> String:
        return String(self)

    @inline(.always)
    def empty(self) -> Bool:
        return len(self._inner) == 0

    @inline(.always)
    def get(self, key: String) -> Optional[String]:
        return self._inner.get(key.lower())

    def content_length(self) -> Int:
        try:
            return Int(self[HeaderKey.CONTENT_LENGTH])
        except:
            return 0

    def parse_raw(
        mut self, mut r: ByteReader
    ) raises -> Tuple[String, String, String]:
        var first_byte = r.peek()
        if not first_byte:
            raise Error(
                "Headers.parse_raw: Failed to read first byte from response"
                " header"
            )

        var first = r.read_word()
        if not r.available():
            raise Error("Failed to read first word from request line")
        r.increment()
        var second = r.read_word()
        if not r.available():
            raise Error("Failed to read second word from request line")
        r.increment()
        var third = r.read_line()

        while r.available() and not is_newline(r.peek()):
            var key = r.read_until(BytesConstant.COLON)
            r.increment()
            if is_space(r.peek()):
                r.increment()
            var value = r.read_line()
            var k = to_string(key).lower()
            if k == HeaderKey.SET_COOKIE:
                continue

            self._inner[k] = to_string(value)
        if r.available():
            _ = r.read_line()
        return (to_string(first), to_string(second), to_string(third))

    def write_to[T: Writer, //](self, mut writer: T):
        for header in self._inner.items():
            write_header(writer, header.key, header.value)

    def remove(mut self, key: String) raises -> None:
        _ = self._inner.pop(key.lower())


@fieldwise_init
struct HTTPRequest(Copyable, Movable, Writable):
    var headers: Headers
    var uri: URI
    var body_raw: Bytes

    var method: String
    var protocol: String

    var timeout: Duration

    def __init__(
        out self,
        uri: URI,
        headers: Headers = Headers(),
        method: String = "GET",
        protocol: String = HTTP11,
        body: Bytes = Bytes(),
        timeout: Duration = Duration(),
    ):
        self.headers = headers.copy()
        self.method = method
        self.protocol = protocol
        self.uri = uri.copy()
        self.body_raw = body.copy()
        self.timeout = timeout
        if HeaderKey.CONNECTION not in self.headers:
            self.headers[HeaderKey.CONNECTION] = "keep-alive"
        if HeaderKey.HOST not in self.headers and uri.host:
            self.headers[HeaderKey.HOST] = uri.host

    def __str__(self) -> String:
        return String(self)

    def __eq__(self, other: Self) raises -> Bool:
        return (
            self.method == other.method
            and self.uri == other.uri
            and self.protocol == other.protocol
            and self.headers == other.headers
            and StringSpan(unsafe_from_utf8=Span(self.body_raw))
            == StringSpan(unsafe_from_utf8=Span(other.body_raw))
        )

    def __ne__(self, other: Self) raises -> Bool:
        return not (self == other)

    def get_body(self) -> StringSpan[origin_of(self.body_raw)]:
        return StringSpan(unsafe_from_utf8=Span(self.body_raw))

    def set_connection_close(mut self):
        self.headers[HeaderKey.CONNECTION] = "close"

    def set_content_length(mut self, l: Int):
        self.headers[HeaderKey.CONTENT_LENGTH] = String(l)

    def connection_close(self) -> Bool:
        var result = self.headers.get(HeaderKey.CONNECTION)
        if not result:
            return False
        return result.value() == "close"

    @inline(.always)
    def read_body(
        mut self, mut r: ByteReader, content_length: Int, max_body_size: Int
    ) raises -> None:
        if content_length > max_body_size:
            raise Error("Request body too large")

        self.body_raw = Bytes(r.read_bytes(content_length))

    def write_to[T: Writer, //](self, mut writer: T):
        var path = self.uri.path if self.uri.path.byte_length() > 1 else SLASH
        if self.uri.query_string.byte_length() > 0:
            path.write("?", self.uri.query_string)

        writer.write(
            self.method,
            WHITESPACE,
            path,
            WHITESPACE,
            self.protocol,
            LINE_BREAK,
            self.headers,
            LINE_BREAK,
            to_string(self.body_raw),
        )

    def encode(var self) -> Bytes:
        """Encodes request as bytes.

        This method consumes the data in this request and it should
        no longer be considered valid.
        """
        var path = self.uri.path if self.uri.path.byte_length() > 1 else SLASH
        if self.uri.query_string.byte_length() > 0:
            path.write("?", self.uri.query_string)

        var writer = ByteWriter()
        writer.write(
            self.method,
            WHITESPACE,
            path,
            WHITESPACE,
            self.protocol,
            LINE_BREAK,
            self.headers,
            LINE_BREAK,
        )
        writer.write_bytes(self.body_raw[:])
        return writer.consume()

    @staticmethod
    def from_bytes(
        addr: String, max_body_size: Int, b: Span[Byte, _]
    ) raises -> Tuple[HTTPRequest, Int]:
        var reader = ByteReader(b)
        var headers = Headers()
        var method: String
        var protocol: String
        var uri: String
        try:
            var rest = headers.parse_raw(reader)
            method, uri, protocol = rest[0], rest[1], rest[2]
        except e:
            raise Error(
                "HTTPRequest.from_bytes: Failed to parse request headers: "
                + String(e)
            )

        var content_length = headers.content_length()
        if (
            content_length > 0
            and max_body_size > 0
            and content_length > max_body_size
        ):
            raise Error("HTTPRequest.from_bytes: Request body too large.")

        var request = HTTPRequest(
            URI.parse(addr + uri),
            headers=headers,
            method=method,
            protocol=protocol,
        )
        try:
            request.read_body(reader, content_length, max_body_size)
        except e:
            raise Error(
                "HTTPRequest.from_bytes: Failed to read request body: "
                + String(e)
            )

        return request.copy(), reader.read_pos


@fieldwise_init
struct HTTPResponse(Copyable, Movable, Writable):
    var headers: Headers
    var body_raw: Bytes

    var status_code: Int
    var status_text: String
    var protocol: String

    def __init__(
        out self,
        status_code: Int,
        status_text: String,
        headers: Headers,
        body_bytes: Span[Byte, _],
        protocol: String = HTTP11,
    ):
        self.headers = headers.copy()
        self.status_code = status_code
        self.status_text = status_text
        self.protocol = protocol
        self.body_raw = Bytes(body_bytes)

    def __init__(
        out self,
        mut reader: ByteReader,
        headers: Headers = Headers(),
        status_code: Int = 200,
        status_text: String = "OK",
        protocol: String = HTTP11,
    ) raises:
        self.headers = headers.copy()
        self.status_code = status_code
        self.status_text = status_text
        self.protocol = protocol
        self.body_raw = Bytes(reader.read_bytes())

    def __str__(self) -> String:
        return String(self)

    def get_body(self) -> StringSpan[origin_of(self.body_raw)]:
        return StringSpan(unsafe_from_utf8=Span(self.body_raw))

    @inline(.always)
    def set_connection_close(mut self):
        self.headers[HeaderKey.CONNECTION] = "close"

    def connection_close(self) -> Bool:
        var result = self.headers.get(HeaderKey.CONNECTION)
        if not result:
            return False
        return result.value() == "close"

    @inline(.always)
    def set_connection_keep_alive(mut self):
        self.headers[HeaderKey.CONNECTION] = "keep-alive"

    @inline(.always)
    def set_content_length(mut self, l: Int):
        self.headers[HeaderKey.CONTENT_LENGTH] = String(l)

    @inline(.always)
    def content_length(self) -> Int:
        try:
            return Int(self.headers[HeaderKey.CONTENT_LENGTH])
        except:
            return 0

    @inline(.always)
    def is_redirect(self) -> Bool:
        return (
            self.status_code == StatusCode.MOVED_PERMANENTLY
            or self.status_code == StatusCode.FOUND
            or self.status_code == StatusCode.TEMPORARY_REDIRECT
            or self.status_code == StatusCode.PERMANENT_REDIRECT
        )

    @inline(.always)
    def read_body(mut self, mut r: ByteReader) raises -> None:
        self.body_raw = Bytes(r.read_bytes(self.content_length()))
        self.set_content_length(len(self.body_raw))

    def read_chunks(mut self, chunks: Span[Byte, _]) raises:
        var reader = ByteReader(chunks)
        while True:
            var size = atol(StringSpan(unsafe_from_utf8=reader.read_line()), 16)
            if size == 0:
                break
            var data = reader.read_bytes(size)
            reader.skip_carriage_return()
            self.set_content_length(self.content_length() + len(data))
            self.body_raw += Bytes(data)

    def write_to[T: Writer](self, mut writer: T):
        writer.write(
            self.protocol,
            WHITESPACE,
            self.status_code,
            WHITESPACE,
            self.status_text,
            LINE_BREAK,
        )
        writer.write(self.headers, LINE_BREAK, to_string(self.body_raw))

    def encode(var self) -> Bytes:
        """Encodes response as bytes.

        This method consumes the data in this request and it should
        no longer be considered valid.
        """
        var writer = ByteWriter()
        writer.write(
            self.protocol,
            WHITESPACE,
            String(self.status_code),
            WHITESPACE,
            self.status_text,
            LINE_BREAK,
        )
        if HeaderKey.DATE not in self.headers:
            try:
                write_header(writer, HeaderKey.DATE, String(now(utc=True)))
            except:
                pass
        writer.write(self.headers, LINE_BREAK)
        writer.write_bytes(self.body_raw[:])
        return writer.consume()

    @staticmethod
    def from_bytes(b: Span[Byte, _]) raises -> HTTPResponse:
        var reader = ByteReader(b)
        var headers = Headers()
        var protocol: String
        var status_code: String
        var status_text: String

        try:
            var properties = headers.parse_raw(reader)
            protocol, status_code, status_text = (
                properties[0],
                properties[1],
                properties[2],
            )
        except e:
            raise Error("Failed to parse response headers: " + String(e))

        try:
            return HTTPResponse(
                reader=reader,
                headers=headers,
                protocol=protocol,
                status_code=Int(status_code),
                status_text=status_text,
            )
        except e:
            logger.error(e)
            raise Error("Failed to read request body")

    @staticmethod
    def from_bytes(
        b: Span[Byte, _], conn: TCPConnection
    ) raises -> HTTPResponse:
        var reader = ByteReader(b)
        var headers = Headers()
        var protocol: String
        var status_code: String
        var status_text: String

        try:
            var properties = headers.parse_raw(reader)
            protocol, status_code, status_text = (
                properties[0],
                properties[1],
                properties[2],
            )
            reader.skip_carriage_return()
        except e:
            raise Error("Failed to parse response headers: " + String(e))

        var response = HTTPResponse(
            status_code=Int(status_code),
            status_text=status_text,
            headers=headers,
            body_bytes=Bytes(),
            protocol=protocol,
        )

        var transfer_encoding = response.headers.get(
            HeaderKey.TRANSFER_ENCODING
        )
        if transfer_encoding and transfer_encoding.value() == "chunked":
            var b = Bytes(reader.read_bytes())
            var buff = Bytes(capacity=DEFAULT_BUFFER_SIZE)
            try:
                while conn.read(buff) > 0:
                    b += buff.copy()

                    if (
                        buff[-5] == byte("0")
                        and buff[-4] == byte("\r")
                        and buff[-3] == byte("\n")
                        and buff[-2] == byte("\r")
                        and buff[-1] == byte("\n")
                    ):
                        break

                    buff.shrink(0)
                response.read_chunks(b)
                return response.copy()
            except e:
                logger.error(e)
                raise Error("Failed to read chunked response.")

        try:
            response.read_body(reader)
            return response.copy()
        except e:
            logger.error(e)
            raise Error("Failed to read request body: ")
