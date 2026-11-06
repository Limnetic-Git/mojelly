from std.collections import Span
from mojelly.websockets.aliases import Bytes
from mojelly.websockets.net import ListenConfig
from mojelly.websockets.sync.server import Server, WSConnection


def echo(mut conn: WSConnection, data: Span[Byte, _]) raises:
    conn.send_binary(Bytes(data))


def main() raises:
    var config = ListenConfig()
    var listener = config.listen("127.0.0.1", 0)
    print("READY", listener.addr().port, flush=True)
    var server = Server[echo]("127.0.0.1", 0)
    var conn = listener.accept()
    server.serve_connection(conn^)
