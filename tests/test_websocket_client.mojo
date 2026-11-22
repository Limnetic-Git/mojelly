"""Exercise the standalone client against the integrated HTTP server."""

from std.testing import assert_equal
from mojelly.websockets.sync.client import connect
from mojelly.websockets.aliases import Bytes


def main() raises:
    with connect("ws://127.0.0.1:8080/ws") as client:
        client.send_text("Mojo client")
        assert_equal(client.recv_text(), "Mojo client")
        var payload: Bytes = [0, 128, 255]
        client.send_binary(payload)
        assert_equal(client.recv(), payload)
    print("Standalone WebSocket client passed!")
