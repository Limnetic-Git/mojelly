#!/usr/bin/env python3
"""E2E tests for request limits, timeouts and malformed-request handling.

Starts its own ./server with tiny limits so the tests run in a few seconds.
"""

import os
import signal
import socket
import subprocess
import sys
import time

HOST, PORT = "127.0.0.1", 8080

ENV = {
    **os.environ,
    "MOJELLY_THREADS": "2",
    "MOJELLY_MAX_HEADER_SIZE": "4096",
    "MOJELLY_MAX_BODY": "1024",
    "MOJELLY_IDLE_TIMEOUT": "2",
    "MOJELLY_REQUEST_TIMEOUT": "2",
}


def connect(timeout=8.0):
    s = socket.create_connection((HOST, PORT), timeout=timeout)
    return s


def read_until_close(s, limit_s=8.0):
    """Read until the peer closes; returns (data, closed_by_peer, seconds)."""
    start = time.time()
    data = b""
    while time.time() - start < limit_s:
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            continue
        except ConnectionError:
            return data, True, time.time() - start
        if not chunk:
            return data, True, time.time() - start
        data += chunk
    return data, False, time.time() - start


def status_of(data):
    return data.split(b" ", 2)[1].decode() if data.startswith(b"HTTP/") else None


def get_root():
    s = connect()
    s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    data, _, _ = read_until_close(s)
    s.close()
    return data


def main():
    if not os.path.exists("./server"):
        print("❌ ./server not built")
        sys.exit(1)

    proc = subprocess.Popen(
        ["./server"],
        env=ENV,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        preexec_fn=os.setsid,
    )
    passed = failed = 0

    def check(name, cond, details=""):
        nonlocal passed, failed
        if cond:
            passed += 1
            print(f"  ✅ {name}")
        else:
            failed += 1
            print(f"  ❌ {name}: {details}")

    try:
        for _ in range(50):
            try:
                if status_of(get_root()) == "200":
                    break
            except OSError:
                time.sleep(0.1)
        else:
            print("❌ server did not start")
            sys.exit(1)

        print("\n🧪 Limits, timeouts and malformed requests:\n")

        # Malformed request: 400, and the server must survive it.
        s = connect()
        s.sendall(b"GARBAGE\r\n\r\n")
        data, closed, _ = read_until_close(s)
        s.close()
        check("malformed request gets 400", status_of(data) == "400", data[:60])
        time.sleep(0.3)
        check("server still alive after malformed request",
              proc.poll() is None and status_of(get_root()) == "200",
              f"exit={proc.poll()}")

        # Header block over the limit -> 431.
        s = connect()
        s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nX-Big: " + b"a" * 5000 + b"\r\n\r\n")
        data, closed, _ = read_until_close(s)
        s.close()
        check("oversized headers get 431", status_of(data) == "431", data[:60])
        check("connection closed after 431", closed)

        # Content-Length over the limit -> 413 without sending the body.
        s = connect()
        s.sendall(b"POST /user HTTP/1.1\r\nHost: x\r\nContent-Length: 2000\r\n\r\n")
        data, closed, _ = read_until_close(s)
        s.close()
        check("Content-Length over limit gets 413", status_of(data) == "413", data[:60])

        # Chunked body over the limit -> 413.
        s = connect()
        chunk = b"b" * 600
        body = b"".join(b"%x\r\n" % len(chunk) + chunk + b"\r\n" for _ in range(3))
        s.sendall(b"POST /user HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
                  + body + b"0\r\n\r\n")
        data, closed, _ = read_until_close(s)
        s.close()
        check("chunked body over limit gets 413", status_of(data) == "413", data[:60])

        # Idle connection is closed by the idle timeout (2 s, swept every 1 s).
        s = connect()
        data, closed, secs = read_until_close(s, limit_s=8.0)
        s.close()
        check("idle connection is closed", closed and 1.0 <= secs <= 5.0,
              f"closed={closed} after {secs:.1f}s")

        # Slowloris: bytes keep arriving (never idle) but the request never
        # completes, so the request timeout must close it.
        s = connect(timeout=0.5)
        s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n")
        start = time.time()
        closed = False
        while time.time() - start < 8.0:
            try:
                s.sendall(b"X-A: b\r\n")
            except OSError:
                closed = True
                break
            try:
                if s.recv(1) == b"":
                    closed = True
                    break
            except socket.timeout:
                pass
            except OSError:
                closed = True
                break
        secs = time.time() - start
        s.close()
        check("slow request is closed by request timeout", closed and secs <= 6.0,
              f"closed={closed} after {secs:.1f}s")

        # A busy keep-alive connection is not killed by the idle timeout.
        s = connect()
        ok = True
        for _ in range(3):
            s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
            data = s.recv(4096)
            ok = ok and status_of(data) == "200"
            time.sleep(1.0)
        s.close()
        check("active keep-alive connection survives", ok)

        check("server survived all of the above", proc.poll() is None,
              f"exit={proc.poll()}")
    finally:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            proc.wait(timeout=2.0)
        except Exception:
            pass

    print("\n==========================================")
    print(f"Results: {passed} passed, {failed} failed")
    print("==========================================")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
