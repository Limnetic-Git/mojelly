"""Parse HTTP and WebSocket authorities without confusing IPv6 and ports.

Bracketed IPv6 literals, user information, omitted paths and query strings
are separated before DNS lookup. Invalid ports and raw control characters
are rejected rather than truncated by later integer or C-string conversion.
"""

# This code is taken from a publicly available repository distributed under the terms of the MIT license:
# https://github.com/msaelices/mojo-websockets/blob/main/LICENSE
from std.collections import Optional
from std.collections.string import StringSpan
from std.utils import Variant

from mojelly.websockets.aliases import Bytes
from mojelly.websockets.utils.string import (
    HTTP,
    HTTP10,
    HTTP11,
    HTTPS,
    WSS,
    SLASH,
)


@fieldwise_init
struct URI(Copyable, Movable):
    var _original_path: String
    var _hash: String
    var scheme: String
    var path: String
    var query_string: String
    var host: String

    var full_uri: String
    var request_uri: String

    var username: String
    var password: String

    @staticmethod
    def parse(uri: String) raises -> URI:
        for byte in uri.as_bytes():
            if byte <= 32 or byte == 127:
                raise Error("InvalidURI: space or control character")
        if "#" in uri:
            raise Error("InvalidURI: fragments are not allowed")
        var scheme = String("")
        var start = 0
        var separator = uri.find("://")
        if separator >= 0:
            scheme = String(uri[byte=:separator]).lower()
            if scheme not in ("ws", "wss", "http", "https"):
                raise Error("InvalidURI: unsupported scheme")
            start = separator + 3
        var end = uri.byte_length()
        for i in range(start, uri.byte_length()):
            if uri.as_bytes()[i] == 47 or uri.as_bytes()[i] == 63:
                end = i
                break
        var host = String(uri[byte=start:end])
        var target = String(uri[byte=end:])
        if not host:
            raise Error("InvalidURI: missing host")
        if not target or target.startswith("?"):
            target = "/" + target
        var query = target.find("?")
        var path = String(target[byte=:query]) if query >= 0 else target
        var result = URI(
            _original_path=path,
            _hash="",
            scheme=scheme,
            path=path,
            query_string=String(target[byte = query + 1 :]) if query
            >= 0 else "",
            host=host,
            full_uri=uri,
            request_uri=target,
            username="",
            password="",
        )
        _ = result.get_hostname()
        _ = result.get_port()
        return result^

    def __init__(
        out self,
        uri: String = "",
    ):
        self._original_path = "/"
        self._hash = ""
        self.scheme = ""
        self.path = "/"
        self.query_string = ""
        self.host = ""
        self.full_uri = uri
        self.request_uri = ""
        self.username = ""
        self.password = ""

    def is_https(self) -> Bool:
        return self.scheme == HTTPS

    def is_http(self) -> Bool:
        return self.scheme == HTTP or self.scheme.byte_length() == 0

    def is_wss(self) -> Bool:
        return self.scheme == WSS

    def get_path(self) -> String:
        return self.request_uri

    def get_hostname(self) raises -> String:
        var authority = String(self.host[byte = self.host.rfind("@") + 1 :])
        if authority.startswith("["):
            var end = authority.find("]")
            if end <= 1:
                raise Error("InvalidURI: invalid IPv6 host")
            var tail = String(authority[byte = end + 1 :])
            if tail and not tail.startswith(":"):
                raise Error("InvalidURI: invalid authority")
            return String(authority[byte=1:end])
        var colon = authority.find(":")
        if not authority or colon == 0 or "[" in authority or "]" in authority:
            raise Error("InvalidURI: invalid host")
        if colon >= 0 and authority.find(":", start=colon + 1) >= 0:
            raise Error("InvalidURI: IPv6 requires brackets")
        return String(authority[byte=:colon]) if colon >= 0 else authority

    def get_port(self) raises -> Int:
        var authority = String(self.host[byte = self.host.rfind("@") + 1 :])
        var start = authority.find("]") + 1 if authority.startswith("[") else 0
        var colon = authority.find(":", start=start)
        if colon < 0:
            return 443 if self.is_https() or self.is_wss() else 80
        var value = String(authority[byte = colon + 1 :])
        if not value:
            raise Error("InvalidURI: empty port")
        var port = 0
        for byte in value.as_bytes():
            if byte < 48 or byte > 57:
                raise Error("InvalidURI: invalid port")
            port = port * 10 + Int(byte) - 48
            if port > 65535:
                raise Error("InvalidURI: port out of range")
        if port == 0:
            raise Error("InvalidURI: port out of range")
        return port

    def get_user_info(self) raises -> Optional[Tuple[String, String]]:
        var end = self.host.rfind("@")
        if end < 0:
            return None
        var credentials = String(self.host[byte=:end])
        var colon = credentials.find(":")
        if colon < 0:
            return (decode_user_info(credentials), String(""))
        # Passwords may contain colons, so split only at the first colon
        return (
            decode_user_info(String(credentials[byte=:colon])),
            decode_user_info(String(credentials[byte = colon + 1 :])),
        )

    def __eq__(self, other: URI) -> Bool:
        return self.full_uri == other.full_uri


def decode_user_info(encoded: String) raises -> String:
    """Decode URL escapes before constructing an HTTP Basic credential."""
    var data = encoded.as_bytes()
    var result = Bytes()
    var i = 0
    while i < len(data):
        if data[i] != 37:
            result.append(data[i])
        else:
            if i + 2 >= len(data):
                raise Error("InvalidURI: incomplete percent escape")
            var value = 0
            for j in range(1, 3):
                var byte = Int(data[i + j])
                var digit = (
                    byte - 48 if 48
                    <= byte
                    <= 57 else byte - 65 + 10 if 65
                    <= byte
                    <= 70 else byte - 97 + 10 if 97
                    <= byte
                    <= 102 else -1
                )
                if digit < 0:
                    raise Error("InvalidURI: invalid percent escape")
                value = value * 16 + digit
            result.append(Byte(value))
            i += 2
        i += 1
    return String(from_utf8=result[:])
