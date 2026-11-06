"""Mojo 1.1 checks and WebSocket interoperability tests with independent TCP peers"""

import base64
import hashlib
import os
from pathlib import Path
import select
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]


def read_exact(stream, size):
    data = stream.read(size)
    if len(data) != size:
        raise AssertionError(f"Unexpected EOF: expected {size}, received {len(data)}")
    return data


def encode_frame(payload, opcode=2, masked=True, final=True):
    size = len(payload)
    header = bytes([opcode | (128 if final else 0), (128 if masked else 0) | (size if size < 126 else 126 if size < 65536 else 127)])
    if size >= 126:
        header += struct.pack("!H" if size < 65536 else "!Q", size)
    if masked:
        key = b"abcd"
        return header + key + bytes(value ^ key[i % 4] for i, value in enumerate(payload))
    return header + payload


def read_frame(stream):
    first, second = read_exact(stream, 2)
    size = second & 127
    if size == 126:
        size = struct.unpack("!H", read_exact(stream, 2))[0]
    elif size == 127:
        size = struct.unpack("!Q", read_exact(stream, 8))[0]
    key = read_exact(stream, 4) if second & 128 else None
    payload = read_exact(stream, size)
    if key:
        payload = bytes(value ^ key[i % 4] for i, value in enumerate(payload))
    return first & 15, payload


def read_headers(stream):
    result = b""
    while not result.endswith(b"\r\n\r\n"):
        result += read_exact(stream, 1)
        if len(result) > 65536:
            raise AssertionError("HTTP headers exceed the limit")
    return result


class WebSocketTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="mojelly-ws-tests-")
        cls.addClassCleanup(cls.directory.cleanup)
        cls.bin_dir = Path(cls.directory.name)
        sdk = ROOT / ".pixi/envs/default"
        compiler = str(sdk / "bin/mojo") if (sdk / "bin/mojo").exists() else shutil.which("mojo")
        if not compiler:
            raise RuntimeError("Install the project environment with pixi install")
        cls.environment = os.environ.copy()
        if (sdk / "share/max/modular.cfg").exists():
            cls.environment["MODULAR_HOME"] = str(sdk / "share/max")
            cls.environment["PATH"] = str(sdk / "bin") + os.pathsep + cls.environment.get("PATH", "")
        # Compiling the entire package also checks modules not exercised by integration tests
        cls.compile(["precompile", "-I", str(ROOT), str(ROOT / "mojelly/websockets"), "-o", str(cls.bin_dir / "websockets.mojoc")], compiler)
        for source, output in [("test_websockets.mojo", "unit"), ("websocket_server_fixture.mojo", "server"), ("websocket_client_fixture.mojo", "client")]:
            cls.compile(["build", "-I", str(ROOT), str(ROOT / "tests" / source), "-o", str(cls.bin_dir / output)], compiler)

    @classmethod
    def compile(cls, arguments, compiler):
        result = subprocess.run([compiler, *arguments], cwd=ROOT, env=cls.environment, capture_output=True, text=True, errors="replace", timeout=90)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def test_protocol_and_utilities(self):
        result = subprocess.run([str(self.bin_dir / "unit")], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def start_server(self):
        process = subprocess.Popen([str(self.bin_dir / "server")], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.stop_server, process)
        self.assertTrue(select.select([process.stdout], [], [], 10)[0], "Server startup timed out")
        line = process.stdout.readline()
        self.assertTrue(line.startswith("READY "), line)
        connection = socket.create_connection(("127.0.0.1", int(line.split()[1])), timeout=5)
        self.addCleanup(connection.close)
        stream = connection.makefile("rb")
        self.addCleanup(stream.close)
        return process, connection, stream

    @staticmethod
    def stop_server(process):
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        process.stdout.close()
        process.stderr.close()

    def handshake(self, connection, stream, suffix=b""):
        request = b"GET /echo HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
        connection.sendall(request + suffix)
        headers = read_headers(stream)
        self.assertIn(b"101 Switching Protocols", headers)
        self.assertIn(b"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", headers)

    def test_python_client_mojo_server(self):
        process, connection, stream = self.start_server()
        # Send the first frame with the handshake, then check payload sizes and zero bytes
        self.handshake(connection, stream, encode_frame(b"pipeline\x00"))
        self.assertEqual(read_frame(stream), (2, b"pipeline\x00"))
        for payload in [b"", "Привет 🌍".encode(), bytes(range(256)), bytes(range(256)) * 256 + b"\x00"]:
            connection.sendall(encode_frame(payload))
            self.assertEqual(read_frame(stream), (2, payload))
        connection.sendall(encode_frame(b"hello", 1, final=False) + encode_frame(b" world", 0))
        self.assertEqual(read_frame(stream), (2, b"hello world"))
        connection.sendall(encode_frame(b"ping", 9))
        self.assertEqual(read_frame(stream), (10, b"ping"))
        connection.sendall(encode_frame(struct.pack("!H", 1000), 8))
        self.assertEqual(read_frame(stream), (8, struct.pack("!H", 1000)))
        self.assertEqual(stream.read(1), b"")
        self.assertEqual(process.wait(timeout=5), 0, process.stderr.read())

    def test_reject_unmasked_client_frame(self):
        process, connection, stream = self.start_server()
        self.handshake(connection, stream)
        connection.sendall(encode_frame(b"invalid", masked=False))
        opcode, payload = read_frame(stream)
        self.assertEqual(opcode, 8)
        self.assertEqual(struct.unpack("!H", payload[:2])[0], 1002)
        self.assertEqual(process.wait(timeout=5), 0, process.stderr.read())

    def test_mojo_client_python_server(self):
        errors = []
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        listener.settimeout(10)
        self.addCleanup(listener.close)
        port = listener.getsockname()[1]

        def server():
            try:
                with listener.accept()[0] as connection:
                    connection.settimeout(5)
                    with connection.makefile("rb") as stream:
                        header = read_headers(stream)
                        key = next(line.split(b":", 1)[1].strip() for line in header.split(b"\r\n") if line.lower().startswith(b"sec-websocket-key:"))
                        accept = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
                        reply = b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n"
                        for byte in reply:
                            connection.sendall(bytes([byte]))
                        opcode, payload = read_frame(stream)
                        if opcode != 2:
                            raise AssertionError("Expected a binary client frame")
                        # Interleave a ping with fragments of a binary message
                        connection.sendall(encode_frame(b"ping", 9, False) + encode_frame(payload[:4], 2, False, False) + encode_frame(payload[4:], 0, False))
                        if read_frame(stream) != (10, b"ping") or read_frame(stream)[0] != 8:
                            raise AssertionError("Expected pong and close frames")
            except BaseException as error:
                errors.append(error)

        thread = threading.Thread(target=server, daemon=True)
        thread.start()
        result = subprocess.run([str(self.bin_dir / "client"), f"ws://127.0.0.1:{port}/echo"], capture_output=True, text=True, timeout=15)
        thread.join(timeout=10)
        self.assertFalse(thread.is_alive(), "Python server did not finish")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(errors, errors)


if __name__ == "__main__":
    unittest.main(verbosity=2)
