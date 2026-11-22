from std.testing import assert_equal, assert_true, assert_false
from mojelly.core.router_handlers import RouterHandlers
from mojelly.http.request import HTTPRequest
from mojelly.http.response import HTTPResponse
from mojelly.websockets import WebSocket, Bytes
from mojelly.websockets.utils.handshake import ws_accept_key
from mojelly.websockets.protocol import OPEN
from generator import (
    extract_handlers,
    generate_routes_code,
    generate_dto_wrappers_code,
)


def echo(mut socket: WebSocket, data: Bytes) raises:
    socket.send_binary(data)


def plain(mut request: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(200, "HTTP")


def test_routes() raises:
    var router = RouterHandlers()
    router.websocket("/ws", echo)
    router.websocket("/rooms/:room", echo)
    router.websocket("/files/*path", echo)
    router.get("/ws", plain)
    var request = HTTPRequest(url="/ws?token=abc")
    assert_true(Bool(router.match_websocket(request)))
    assert_equal(request.get_query("token"), "abc")
    assert_equal(router.handle(request).status, 200)
    var dynamic = HTTPRequest(url="/rooms/mojo")
    assert_true(Bool(router.match_websocket(dynamic)))
    assert_equal(dynamic.get_param("room"), "mojo")
    assert_equal(router.handle(dynamic).status, 426)
    var wildcard = HTTPRequest(url="/files/a/b")
    assert_true(Bool(router.match_websocket(wildcard)))
    assert_equal(wildcard.get_param("path"), "a/b")
    var missing = HTTPRequest(url="/unknown")
    assert_false(Bool(router.match_websocket(missing)))
    var post = HTTPRequest(url="/ws", method="POST")
    assert_false(Bool(router.match_websocket(post)))


def test_generator() raises:
    var source = """
def main():
    router.get("/", index)
    router.websocket("/ws", echo)
    router.websocket("/rooms/:room", echo)
"""
    var routes = extract_handlers(source)
    assert_equal(routes.get("WEBSOCKET:/ws", ""), "echo")
    assert_equal(routes.get("WEBSOCKET:/rooms/:room", ""), "echo")
    var dtos = Dict[String, String]()
    dtos["echo"] = "Bytes"
    var code = generate_routes_code(routes, dtos)
    assert_true('router_ptr[].websocket("/ws", echo)' in code)
    assert_true('router_ptr[].add("GET", "/", index)' in code)
    assert_equal(generate_dto_wrappers_code(routes, dtos), "")


def test_protocol() raises:
    assert_equal(
        ws_accept_key("dGhlIHNhbXBsZSBub25jZQ=="),
        "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
    )
    var socket = WebSocket(HTTPRequest(url="/ws"))
    socket.protocol.set_state(OPEN)
    socket.send_text("hello")
    var output = socket.protocol.data_to_send()
    var expected_text: Bytes = [129, 5, 104, 101, 108, 108, 111]
    assert_equal(output, expected_text)
    socket.send_binary([0, 255])
    var expected_binary: Bytes = [130, 2, 0, 255]
    assert_equal(socket.protocol.data_to_send(), expected_binary)


def main() raises:
    test_routes()
    test_generator()
    test_protocol()
    print("All WebSocket unit tests passed!")
