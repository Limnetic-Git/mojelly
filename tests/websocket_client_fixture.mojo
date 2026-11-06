from std.sys import argv
from std.testing import assert_equal
from mojelly.websockets.aliases import Bytes
from mojelly.websockets.sync.client import connect
from mojelly.websockets.utils.bytes import str_to_bytes


def main() raises:
    var args = argv()
    with connect(args[1])^ as client:
        var payload = str_to_bytes("Привет 🌍")
        payload.append(0)
        client.send_binary(payload)
        assert_equal(client.recv(), payload)
    print("Mojo -> Python integration passed")
