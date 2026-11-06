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
    def parse(uri: String) -> URI:
        var proto_str = String(HTTP11)
        var proto_end = uri.find("://")
        var remainder_uri: String
        if proto_end >= 0:
            proto_str = String(uri[byte=:proto_end])
            remainder_uri = String(uri[byte = proto_end + 3 :])
        else:
            remainder_uri = uri

        var path_start = remainder_uri.find("/")
        var host_and_port: String
        var request_uri: String
        var host: String
        if path_start >= 0:
            host_and_port = String(remainder_uri[byte=:path_start])
            request_uri = String(remainder_uri[byte=path_start:])
            host = String(host_and_port[byte=:path_start])
        else:
            host_and_port = remainder_uri
            request_uri = SLASH
            host = host_and_port

        var scheme = proto_str

        var n = request_uri.find("?")
        var original_path: String
        var query_string: String
        if n >= 0:
            original_path = String(request_uri[byte=:n])
            query_string = String(request_uri[byte = n + 1 :])
        else:
            original_path = request_uri
            query_string = ""

        return URI(
            _original_path=original_path,
            scheme=scheme,
            path=original_path,
            query_string=query_string,
            _hash="",
            host=host,
            full_uri=uri,
            request_uri=request_uri,
            username="",
            password="",
        )

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
        # TODO: Remove try-catch when .format() does not raise
        if self.query_string:
            return self.path + "?" + self.query_string
        return self.path

    def get_hostname(self) -> String:
        # A colon in the credentials does not delimit the port
        var start = self.host.rfind("@") + 1
        var end = self.host.find(":", start=start)
        if end < 0:
            end = self.host.byte_length()
        return String(self.host[byte=start:end])

    def get_port(self) raises -> Int:
        var start = self.host.rfind("@") + 1
        var colon = self.host.find(":", start=start)
        if colon < 0:
            return 443 if self.is_https() or self.is_wss() else 80
        return Int(String(self.host[byte = colon + 1 :]))

    def get_user_info(self) -> Optional[Tuple[String, String]]:
        var end = self.host.rfind("@")
        if end < 0:
            return None
        var credentials = String(self.host[byte=:end])
        var colon = credentials.find(":")
        if colon < 0:
            return (credentials, String(""))
        # Passwords may contain colons, so split only at the first colon
        return (
            String(credentials[byte=:colon]),
            String(credentials[byte = colon + 1 :]),
        )

    def __eq__(self, other: URI) -> Bool:
        return self.full_uri == other.full_uri
