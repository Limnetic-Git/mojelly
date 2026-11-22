#!/usr/bin/env python3
"""End-to-end tests for Mojelly static file serving (uv_fs_sendfile)."""

import hashlib
import http.client
import os
import shutil
import signal
import socket
import subprocess
import sys
import time

HOST = "127.0.0.1"
PORT = 8080
PUBLIC_DIR = "static"
TEST_SUBDIR = os.path.join(PUBLIC_DIR, "__e2e_static__")
URL_PREFIX = "/static/__e2e_static__"


def wait_for_server(timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((HOST, PORT), timeout=0.2):
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError(f"Server did not start on {HOST}:{PORT} within {timeout}s")


def raw_request(payload: bytes, read_body: bool = True) -> tuple[int, dict[str, str], bytes]:
    with socket.create_connection((HOST, PORT), timeout=5.0) as sock:
        sock.sendall(payload)
        return _read_http_response(sock, read_body=read_body)


def _recv_until(sock: socket.socket, marker: bytes, buf: bytearray) -> bytes:
    while marker not in buf:
        chunk = sock.recv(65536)
        if not chunk:
            break
        buf.extend(chunk)
    idx = buf.find(marker)
    if idx == -1:
        data = bytes(buf)
        buf.clear()
        return data
    end = idx + len(marker)
    data = bytes(buf[:end])
    del buf[:end]
    return data


def _read_http_response(
    sock: socket.socket,
    buf: bytearray | None = None,
    read_body: bool = True,
) -> tuple[int, dict[str, str], bytes]:
    if buf is None:
        buf = bytearray()
    header_block = _recv_until(sock, b"\r\n\r\n", buf)
    assert header_block.endswith(b"\r\n\r\n"), f"Incomplete headers: {header_block!r}"

    lines = header_block[:-4].decode("iso-8859-1").split("\r\n")
    status_line = lines[0]
    status = int(status_line.split(" ")[1])

    headers: dict[str, str] = {}
    for line in lines[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()

    if not read_body:
        return status, headers, b""

    content_length = int(headers.get("content-length", "0"))
    while len(buf) < content_length:
        chunk = sock.recv(min(65536, content_length - len(buf)))
        if not chunk:
            break
        buf.extend(chunk)

    body = bytes(buf[:content_length])
    del buf[:content_length]
    return status, headers, body


def setup_fixtures() -> dict[str, bytes]:
    os.makedirs(os.path.join(TEST_SUBDIR, "nested"), exist_ok=True)

    fixtures = {
        "hello.txt": b"Hello from Mojelly sendfile!\n",
        "page.html": b"<!doctype html><h1>Static</h1>",
        "style.css": b"body { color: #6c5ce7; }",
        "app.js": b"console.log('mojelly');",
        "data.json": b'{"ok":true}',
        "unknown.binext": b"\x00\x01\x02\x03\xff",
        "hello world.txt": b"spaces work!",
        "empty.txt": b"",
        "nested/deep.txt": b"deep file content",
        "big.bin": os.urandom(3 * 1024 * 1024 + 12345),  # > 3 MB (multi-chunk)
    }

    for rel_path, data in fixtures.items():
        full_path = os.path.join(TEST_SUBDIR, rel_path)
        with open(full_path, "wb") as f:
            f.write(data)

    return fixtures


def test_basic_and_mime_types(fixtures: dict[str, bytes]) -> None:
    expected_mimes = {
        "hello.txt": "text/plain",
        "page.html": "text/html",
        "style.css": "text/css",
        "app.js": "application/javascript",
        "data.json": "application/json",
        "unknown.binext": "application/octet-stream",
        "nested/deep.txt": "text/plain",
    }

    conn = http.client.HTTPConnection(HOST, PORT, timeout=5)
    try:
        for rel_path, expected_ct in expected_mimes.items():
            conn.request("GET", f"{URL_PREFIX}/{rel_path}")
            resp = conn.getresponse()
            body = resp.read()
            assert resp.status == 200, f"{rel_path}: expected 200, got {resp.status}"
            ct = resp.getheader("Content-Type", "")
            assert ct.startswith(expected_ct), f"{rel_path}: expected {expected_ct}, got {ct}"
            assert body == fixtures[rel_path], f"{rel_path}: body mismatch"
    finally:
        conn.close()
    print("  ✔ Basic GET & MIME types")


def test_url_decode_and_query_string(fixtures: dict[str, bytes]) -> None:
    conn = http.client.HTTPConnection(HOST, PORT, timeout=5)
    try:
        conn.request("GET", f"{URL_PREFIX}/hello%20world.txt?v=42&cache=bust")
        resp = conn.getresponse()
        body = resp.read()
        assert resp.status == 200, f"expected 200, got {resp.status}"
        assert body == fixtures["hello world.txt"]
    finally:
        conn.close()
    print("  ✔ URL decoding & query string stripping")


def test_empty_file() -> None:
    conn = http.client.HTTPConnection(HOST, PORT, timeout=5)
    try:
        conn.request("GET", f"{URL_PREFIX}/empty.txt")
        resp = conn.getresponse()
        body = resp.read()
        assert resp.status == 200
        assert resp.getheader("Content-Length") == "0"
        assert body == b""
    finally:
        conn.close()
    print("  ✔ Empty (0-byte) file")


def test_head_request(fixtures: dict[str, bytes]) -> None:
    req = (
        f"HEAD {URL_PREFIX}/big.bin HTTP/1.1\r\n"
        f"Host: {HOST}:{PORT}\r\n"
        f"Connection: close\r\n\r\n"
    ).encode()
    status, headers, body = raw_request(req, read_body=False)
    assert status == 200, f"HEAD expected 200, got {status}"
    assert int(headers["content-length"]) == len(fixtures["big.bin"])
    assert body == b""
    print("  ✔ HEAD request")


def test_large_file_integrity(fixtures: dict[str, bytes]) -> None:
    expected = fixtures["big.bin"]
    conn = http.client.HTTPConnection(HOST, PORT, timeout=15)
    try:
        conn.request("GET", f"{URL_PREFIX}/big.bin")
        resp = conn.getresponse()
        body = resp.read()
        assert resp.status == 200
        assert len(body) == len(expected), f"size {len(body)} != {len(expected)}"
        assert hashlib.sha256(body).digest() == hashlib.sha256(expected).digest()
    finally:
        conn.close()
    print("  ✔ Large binary file (>3 MB, multi-chunk sendfile) SHA-256")


def test_404_and_directory() -> None:
    conn = http.client.HTTPConnection(HOST, PORT, timeout=5)
    try:
        for path in (f"{URL_PREFIX}/does-not-exist.txt", f"{URL_PREFIX}/nested"):
            conn.request("GET", path)
            resp = conn.getresponse()
            resp.read()
            assert resp.status == 404, f"{path}: expected 404, got {resp.status}"
    finally:
        conn.close()
    print("  ✔ 404 for missing file and directory")


def test_path_traversal_blocked() -> None:
    attacks = [
        "/static/../README.md",
        "/static/%2e%2e/README.md",
        "/static/%2E%2E%2FREADME.md",
        f"{URL_PREFIX}/../../README.md",
        f"{URL_PREFIX}/hello.txt%00.png",
    ]
    for path in attacks:
        req = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {HOST}:{PORT}\r\n"
            f"Connection: close\r\n\r\n"
        ).encode()
        status, _, body = raw_request(req)
        assert status == 403, f"Traversal {path!r}: expected 403, got {status} ({body!r})"
    print("  ✔ Path traversal & NUL-byte protection (403)")


def test_keep_alive_after_sendfile(fixtures: dict[str, bytes]) -> None:
    buf = bytearray()
    with socket.create_connection((HOST, PORT), timeout=10.0) as sock:
        # 1. Static file
        sock.sendall(
            f"GET {URL_PREFIX}/hello.txt HTTP/1.1\r\n"
            f"Host: {HOST}:{PORT}\r\n"
            f"Connection: keep-alive\r\n\r\n".encode()
        )
        status, _, body = _read_http_response(sock, buf)
        assert status == 200 and body == fixtures["hello.txt"]

        # 2. Dynamic Mojo route on the exact same TCP connection
        sock.sendall(
            f"GET /json HTTP/1.1\r\n"
            f"Host: {HOST}:{PORT}\r\n"
            f"Connection: keep-alive\r\n\r\n".encode()
        )
        status, _, body = _read_http_response(sock, buf)
        assert status == 200 and b"nickname" in body

        # 3. Another static file on the same connection
        sock.sendall(
            f"GET {URL_PREFIX}/nested/deep.txt HTTP/1.1\r\n"
            f"Host: {HOST}:{PORT}\r\n"
            f"Connection: close\r\n\r\n".encode()
        )
        status, _, body = _read_http_response(sock, buf)
        assert status == 200 and body == fixtures["nested/deep.txt"]
    print("  ✔ Keep-alive reuse (static -> dynamic -> static)")


def test_abrupt_client_disconnect(fixtures: dict[str, bytes]) -> None:
    # Закрываем сокет посреди скачивания большого файла и проверяем, что сервер жив
    with socket.create_connection((HOST, PORT), timeout=5.0) as sock:
        sock.sendall(
            f"GET {URL_PREFIX}/big.bin HTTP/1.1\r\n"
            f"Host: {HOST}:{PORT}\r\n"
            f"Connection: close\r\n\r\n".encode()
        )
        _ = sock.recv(4096)

    time.sleep(0.1)

    conn = http.client.HTTPConnection(HOST, PORT, timeout=5)
    try:
        conn.request("GET", f"{URL_PREFIX}/hello.txt")
        resp = conn.getresponse()
        body = resp.read()
        assert resp.status == 200 and body == fixtures["hello.txt"]
    finally:
        conn.close()
    print("  ✔ Server survives abrupt client disconnect mid-sendfile")


def main() -> int:
    public_existed = os.path.exists(PUBLIC_DIR)
    fixtures = setup_fixtures()

    proc = subprocess.Popen(
        ["./server"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    try:
        wait_for_server()
        test_basic_and_mime_types(fixtures)
        test_url_decode_and_query_string(fixtures)
        test_empty_file()
        test_head_request(fixtures)
        test_large_file_integrity(fixtures)
        test_404_and_directory()
        test_path_traversal_blocked()
        test_keep_alive_after_sendfile(fixtures)
        test_abrupt_client_disconnect(fixtures)
        print("All static file E2E tests passed!")
        return 0
    finally:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        shutil.rmtree(TEST_SUBDIR, ignore_errors=True)
        if not public_existed and os.path.isdir(PUBLIC_DIR) and not os.listdir(PUBLIC_DIR):
            os.rmdir(PUBLIC_DIR)


if __name__ == "__main__":
    sys.exit(main())
