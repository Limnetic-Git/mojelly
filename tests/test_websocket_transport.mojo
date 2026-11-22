"""Test the C transport and expose a standalone server for Python E2E tests."""

from std.sys import argv
from std.testing import assert_equal, assert_true
from mojelly.websockets.aliases import Bytes
from mojelly.websockets.transport import Transport, Poller
from mojelly.websockets.sync.server import WSConnection, serve


def echo(mut socket: WSConnection, data: Span[Byte, _]) raises:
    if socket.is_text():
        socket.send_text(String(from_utf8_lossy=data))
    else:
        socket.send_binary(Bytes(data))


def test_transport() raises:
    var listener = Transport()
    listener.listen("127.0.0.1", 0)
    assert_true(listener.port() > 0)
    assert_equal(listener.accept(), -2)
    var poller = Poller()
    poller.watch(1, listener.fd, 17)
    var client = Transport()
    client.connect("127.0.0.1", listener.port(), 1000)
    assert_true(poller.wait(1000) > 0)
    assert_equal(poller.ids[0], 17)
    var peer = Transport(listener.accept())
    var received = Bytes()
    assert_equal(peer.try_read(received), -2)
    var payload: Bytes = [0, 128, 255]
    assert_equal(client.write(payload, 1000), 3)
    assert_equal(peer.read(received, 1000), 3)
    assert_equal(received, payload)
    client.close()
    assert_equal(peer.read(received, 1000), 0)
    peer.close()
    poller.watch(2, listener.fd, 17)
    listener.close()
    assert_true(listener.is_closed())


def main() raises:
    var args = argv()
    if len(args) > 1:
        var server = serve[echo]("127.0.0.1", Int(args[1]))
        server.serve_forever()
        return
    test_transport()
    print("WebSocket transport tests passed!")
