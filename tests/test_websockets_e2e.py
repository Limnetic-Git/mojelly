"""Raw-socket integration tests for HTTP and WebSocket on the same port."""

import base64
import concurrent.futures
import hashlib
import os
import shutil
import socket
import struct
import subprocess
import time

from e2e_common import Reader, Suite, connect, get, request

KEY = "dGhlIHNhbXBsZSBub25jZQ=="
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def handshake(path="/ws", key=KEY, version="13", extra="", method="GET"):
    return (
        f"{method} {path} HTTP/1.1\r\nHost: localhost\r\n"
        "Upgrade: websocket\r\nConnection: keep-alive, Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: {version}\r\n"
        f"{extra}\r\n"
    ).encode()


def frame(opcode, data=b"", fin=True, masked=True):
    head = bytes([(0x80 if fin else 0) | opcode])
    flag = 0x80 if masked else 0
    length = len(data)
    if length < 126:
        head += bytes([flag | length])
    elif length < 65536:
        head += bytes([flag | 126]) + struct.pack("!H", length)
    else:
        head += bytes([flag | 127]) + struct.pack("!Q", length)
    if not masked:
        return head + data
    mask = b"\x12\x34\x56\x78"
    return head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data))


class Peer:
    def __init__(self, path="/ws", initial=b"", fragmented=False):
        self.sock = connect()
        self.reader = Reader(self.sock)
        raw = handshake(path)
        if fragmented:
            for byte in raw:
                self.sock.sendall(bytes([byte]))
        else:
            self.sock.sendall(raw + initial)
        response = self.reader.read_response()
        assert response.status == 101, response.status
        proof = base64.b64encode(hashlib.sha1((KEY + GUID).encode()).digest()).decode()
        assert response.header("Sec-WebSocket-Accept") == proof
        assert response.header("Upgrade").lower() == "websocket"

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.sock.close()

    def read(self, n):
        while len(self.reader.buf) < n:
            self.reader._fill()
        result, self.reader.buf = self.reader.buf[:n], self.reader.buf[n:]
        return result

    def recv(self):
        first, second = self.read(2)
        assert first & 0x80, "Server must send complete frames"
        assert not second & 0x80, "Server frames must not be masked"
        length = second & 127
        if length == 126:
            length = struct.unpack("!H", self.read(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", self.read(8))[0]
        return first & 15, self.read(length)

    def send(self, opcode, data=b"", **options):
        self.sock.sendall(frame(opcode, data, **options))


def check(suite, name, operation):
    try:
        operation()
    except Exception as error:
        suite.check(name, False, repr(error))
    else:
        suite.check(name, True)


def echo(payload=b"hello", opcode=1):
    with Peer() as peer:
        peer.send(opcode, payload)
        assert peer.recv() == (opcode, payload)


def combined_upgrade():
    with Peer(initial=frame(1, b"first")) as peer:
        assert peer.recv() == (1, b"first")
        peer.send(1, b"second")
        assert peer.recv() == (1, b"second")


def split_frame():
    with Peer(fragmented=True) as peer:
        for byte in frame(1, "split 🌍".encode()):
            peer.sock.sendall(bytes([byte]))
        assert peer.recv() == (1, "split 🌍".encode())


def fragmentation():
    with Peer() as peer:
        peer.send(1, b"hel", fin=False)
        peer.send(9, b"ping")
        assert peer.recv() == (10, b"ping")
        peer.send(0, b"lo")
        assert peer.recv() == (1, b"hello")


def close_handshake():
    with Peer() as peer:
        data = struct.pack("!H", 1000) + b"done"
        peer.send(8, data)
        assert peer.recv() == (8, data)
        assert peer.reader.closed_by_peer()


def protocol_error(payload, code):
    with Peer() as peer:
        peer.sock.sendall(payload)
        opcode, data = peer.recv()
        assert opcode == 8 and struct.unpack("!H", data[:2])[0] == code, (opcode, data)


def room():
    with Peer("/ws/mojo?token=abc") as peer:
        peer.send(1, b"hello")
        assert peer.recv() == (1, b"mojo:hello")
        assert get("/").body == b"Hello, World"
        assert get("/static/test.txt").status == 200


def pipeline_upgrade():
    with connect() as sock:
        reader = Reader(sock)
        sock.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        assert reader.read_response().status == 200
        sock.sendall(handshake() + frame(1, b"after HTTP"))
        assert reader.read_response().status == 101
        peer = Peer.__new__(Peer)
        peer.sock, peer.reader = sock, reader
        assert peer.recv() == (1, b"after HTTP")


def server_close():
    with Peer("/ws/control") as peer:
        peer.send(1, b"close")
        assert peer.recv() == (8, struct.pack("!H", 1000) + b"done")
        peer.send(8, struct.pack("!H", 1000))
        assert peer.reader.closed_by_peer()


def callback_error():
    with Peer("/ws/control") as peer:
        peer.send(1, b"error")
        opcode, data = peer.recv()
        assert opcode == 8 and struct.unpack("!H", data[:2])[0] == 1011
        assert peer.reader.closed_by_peer()
    assert get("/").status == 200


def server_ping():
    with Peer("/ws/control") as peer:
        peer.send(1, b"ping")
        assert peer.recv() == (9, b"ping")
        peer.send(10, b"ping")
        peer.send(1, b"close")
        assert peer.recv()[0] == 8


def multiple_messages():
    with Peer() as peer:
        peer.sock.sendall(frame(1, b"one") + frame(2, b"two"))
        assert peer.recv() == (1, b"one")
        assert peer.recv() == (2, b"two")


def fragmented_limit():
    with Peer() as peer:
        peer.send(2, b"x" * 40, fin=False)
        peer.send(0, b"x" * 40)
        opcode, data = peer.recv()
        assert opcode == 8 and struct.unpack("!H", data[:2])[0] == 1009


def request_timeout_after_upgrade():
    with Peer() as peer:
        time.sleep(2.2)
        peer.send(1, b"still open")
        assert peer.recv() == (1, b"still open")


def close_timeout():
    with Peer("/ws/control") as peer:
        peer.send(1, b"close")
        assert peer.recv()[0] == 8
        assert peer.reader.closed_by_peer(wait=7.0)


def idle_timeout():
    with Peer() as peer:
        assert peer.reader.closed_by_peer(wait=5.0)


def concurrent_clients():
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
        list(pool.map(lambda i: echo(f"client {i}".encode()), range(48)))


def standalone_client():
    pixi = shutil.which("pixi") or os.path.expanduser("~/.pixi/bin/pixi")
    result = subprocess.run(
        [pixi, "run", "mojo", "build", "-I.", "tests/test_websocket_client.mojo",
         "-o", "build/test_websocket_client",
         "-Xlinker", "-L./lib", "-Xlinker", "-lmojelly"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=90,
    )
    assert result.returncode == 0, result.stdout
    result = subprocess.run(["build/test_websocket_client"], capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stdout + result.stderr


def standalone_server():
    pixi = shutil.which("pixi") or os.path.expanduser("~/.pixi/bin/pixi")
    result = subprocess.run(
        [pixi, "run", "mojo", "build", "-I.", "tests/test_websocket_transport.mojo",
         "-o", "build/test_websocket_transport",
         "-Xlinker", "-L./lib", "-Xlinker", "-lmojelly"],
        capture_output=True, text=True, timeout=90,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    subprocess.run(["build/test_websocket_transport"], check=True, capture_output=True, timeout=10)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    process = subprocess.Popen(["build/test_websocket_transport", str(port)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        for _ in range(50):
            try:
                sock = socket.create_connection(("127.0.0.1", port), timeout=1)
                break
            except OSError:
                assert process.poll() is None, "Standalone server exited"
                time.sleep(0.1)
        else:
            raise AssertionError("Standalone server did not start")
        with sock:
            reader = Reader(sock)
            sock.sendall(handshake() + frame(1, b"standalone"))
            assert reader.read_response().status == 101
            peer = Peer.__new__(Peer)
            peer.sock, peer.reader = sock, reader
            assert peer.recv() == (1, b"standalone")
            peer.send(8, struct.pack("!H", 1000))
            assert peer.recv()[0] == 8
    finally:
        process.terminate()
        process.wait(timeout=5)


def main():
    with Suite("WebSocket integration", env={"MOJELLY_THREADS": "2"}) as suite:
        check(suite, "text echo", echo)
        check(suite, "binary echo with NUL and non-UTF8", lambda: echo(bytes(range(256)), 2))
        check(suite, "empty message", lambda: echo(b""))
        check(suite, "64-bit payload length", lambda: echo(b"x" * 70000, 2))
        check(suite, "handshake and frame in one packet", combined_upgrade)
        check(suite, "fragmented TCP reads", split_frame)
        check(suite, "fragmented message with interleaved ping", fragmentation)
        check(suite, "close handshake", close_handshake)
        check(suite, "server-initiated close", server_close)
        check(suite, "callback error is isolated", callback_error)
        check(suite, "server-initiated ping", server_ping)
        check(suite, "multiple messages in one packet", multiple_messages)
        check(suite, "unmasked frame rejected", lambda: protocol_error(frame(1, b"bad", masked=False), 1002))
        check(suite, "invalid UTF8 rejected", lambda: protocol_error(frame(1, b"\xff"), 1007))
        check(suite, "dynamic route and HTTP coexistence", room)
        check(suite, "upgrade after HTTP keep-alive", pipeline_upgrade)
        check(suite, "concurrent connections", concurrent_clients)
        check(suite, "standalone Mojo client", standalone_client)
        check(suite, "standalone epoll server and C transport", standalone_server)
        for name, raw, status in [
            ("unknown route", handshake("/unknown"), 404),
            ("invalid key", handshake(key="bad"), 400),
            ("unsupported version", handshake(version="12"), 400),
            ("handshake body", handshake(extra="Content-Length: 1\r\n") + b"x", 400),
            ("wrong method", handshake(method="POST"), 404),
            ("missing Host", handshake().replace(b"Host: localhost\r\n", b""), 400),
            ("duplicate key", handshake(extra=f"Sec-WebSocket-Key: {KEY}\r\n"), 400),
            ("HTTP 1.0", handshake().replace(b"HTTP/1.1", b"HTTP/1.0"), 400),
        ]:
            def rejection(raw=raw, status=status):
                response = request(raw)
                assert response.status == status, response.status
            check(suite, name, rejection)
        suite.check("plain HTTP requires upgrade", get("/ws").status == 426)
        suite.check("ordinary HTTP still works", get("/").status == 200)
        suite.check("server survived the whole suite", suite.proc.poll() is None)
        passed, failed = suite.passed, suite.failed

    with Suite("WebSocket limits and close deadlines", env={
        "MOJELLY_THREADS": "2", "MOJELLY_MAX_BODY": "64",
        "MOJELLY_MAX_HEADER_SIZE": "512", "MOJELLY_IDLE_TIMEOUT": "0",
        "MOJELLY_REQUEST_TIMEOUT": "1",
    }) as suite:
        check(suite, "message size limit", lambda: protocol_error(frame(2, b"x" * 65), 1009))
        check(suite, "fragmented message size limit", fragmented_limit)
        check(suite, "HTTP request timeout ends at upgrade", request_timeout_after_upgrade)
        check(suite, "server close deadline", close_timeout)
        response = request(handshake(extra="X-Padding: " + "x" * 512 + "\r\n"))
        suite.check("upgrade header size limit", response.status == 431)
        suite.check("server survived limit violations", get("/").status == 200)
        passed += suite.passed
        failed += suite.failed

    with Suite("WebSocket idle timeout", env={
        "MOJELLY_THREADS": "1", "MOJELLY_IDLE_TIMEOUT": "1",
    }) as suite:
        check(suite, "idle upgraded connection closes", idle_timeout)
        suite.passed += passed
        suite.failed += failed
        suite.finish()


if __name__ == "__main__":
    main()
