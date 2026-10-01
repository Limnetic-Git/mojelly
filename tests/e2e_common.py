"""Shared helpers for the end-to-end test suites.

Every suite starts its own ./server (port 8080), speaks HTTP over raw
sockets (so header case, pipelining and fragmentation are under the
test's control) and reports `Results: N passed, M failed`.
"""

import os
import signal
import socket
import subprocess
import sys
import time

HOST, PORT = "127.0.0.1", 8080


class Response:
    def __init__(self, status, reason, headers, body):
        self.status = status
        self.reason = reason
        self.headers = headers  # list of (name, value), as received
        self.body = body

    def header(self, name):
        """First header with this name (case-insensitive) or None."""
        for k, v in self.headers:
            if k.lower() == name.lower():
                return v
        return None

    def all_headers(self, name):
        return [v for k, v in self.headers if k.lower() == name.lower()]


def connect(timeout=5.0):
    return socket.create_connection((HOST, PORT), timeout=timeout)


class Reader:
    """Incremental HTTP response reader over one socket."""

    def __init__(self, sock):
        self.sock = sock
        self.buf = b""

    def _fill(self):
        chunk = self.sock.recv(65536)
        if not chunk:
            raise EOFError("connection closed")
        self.buf += chunk

    def read_response(self):
        while b"\r\n\r\n" not in self.buf:
            self._fill()
        head, _, rest = self.buf.partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        _, status, reason = (lines[0].split(" ", 2) + [""])[:3]
        headers = []
        for line in lines[1:]:
            name, _, value = line.partition(":")
            headers.append((name.strip(), value.strip()))
        length = 0
        for k, v in headers:
            if k.lower() == "content-length":
                length = int(v)
        self.buf = rest
        while len(self.buf) < length:
            self._fill()
        body, self.buf = self.buf[:length], self.buf[length:]
        return Response(int(status), reason, headers, body)

    def closed_by_peer(self, wait=2.0):
        """True if the peer closes the connection within `wait` seconds."""
        self.sock.settimeout(wait)
        try:
            return self.sock.recv(1) == b""
        except socket.timeout:
            return False
        except ConnectionError:
            return True


def request(raw, timeout=5.0):
    """Send raw bytes on a fresh connection, return the first Response."""
    sock = connect(timeout)
    try:
        sock.sendall(raw)
        return Reader(sock).read_response()
    finally:
        sock.close()


def get(path, headers=None, method="GET", body=b""):
    lines = [f"{method} {path} HTTP/1.1", "Host: x", "Connection: close"]
    for k, v in (headers or {}).items():
        lines.append(f"{k}: {v}")
    if body:
        lines.append(f"Content-Length: {len(body)}")
    return request(("\r\n".join(lines) + "\r\n\r\n").encode() + body)


class Suite:
    """Starts ./server with an optional env, collects check() results."""

    def __init__(self, title, env=None):
        self.title = title
        self.env = {**os.environ, **(env or {})}
        self.passed = 0
        self.failed = 0
        self.proc = None

    def check(self, name, cond, details=""):
        if cond:
            self.passed += 1
            print(f"  ✅ {name}")
        else:
            self.failed += 1
            print(f"  ❌ {name}: {details}")

    def __enter__(self):
        if not os.path.exists("./server"):
            print("❌ ./server not built")
            sys.exit(1)
        self.proc = subprocess.Popen(
            ["./server"],
            env=self.env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            preexec_fn=os.setsid,
        )
        for _ in range(50):
            try:
                if get("/").status == 200:
                    break
            except OSError:
                time.sleep(0.1)
        else:
            print("❌ server did not start")
            self.__exit__(None, None, None)
            sys.exit(1)
        print(f"\n🧪 {self.title}\n")
        return self

    def __exit__(self, *exc):
        try:
            os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
            self.proc.wait(timeout=2.0)
        except Exception:
            pass
        return False

    def finish(self):
        alive = self.proc.poll() is None
        self.check("server survived the whole suite", alive,
                   f"exit={self.proc.poll()}")
        print("\n==========================================")
        print(f"Results: {self.passed} passed, {self.failed} failed")
        print("==========================================")
        sys.exit(1 if self.failed else 0)
