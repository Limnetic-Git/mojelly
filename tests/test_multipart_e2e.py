#!/usr/bin/env python3
"""E2E tests for multipart/form-data handling.

Starts its own ./server (tiny body/parts limits) and exercises:
  - text fields (single, many, empty, unicode)
  - file uploads (single, many, binary, custom content-type)
  - mixed forms (text + files)
  - filename sanitization (path traversal)
  - limits (body size, number of parts)
  - 415 on non-upload routes
  - temp-file cleanup
"""

import glob
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
    "MOJELLY_MAX_HEADER_SIZE": "8192",
    "MOJELLY_MAX_BODY": "1048576",      # 1 MiB
    "MOJELLY_MAX_FILE_SIZE": "1048576", # 1 MiB
    "MOJELLY_MAX_FIELD_SIZE": "65536",  # 64 KiB
    "MOJELLY_MAX_PARTS": "100",
    "MOJELLY_IDLE_TIMEOUT": "2",
    "MOJELLY_REQUEST_TIMEOUT": "2",
}

BOUNDARY = b"----MojellyTestBoundary"


# ---------------------------------------------------------------- helpers

def connect(timeout=8.0):
    return socket.create_connection((HOST, PORT), timeout=timeout)


def read_until_close(s, limit_s=8.0):
    start = time.time()
    data = b""
    while time.time() - start < limit_s:
        try:
            chunk = s.recv(65536)
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


def body_of(data):
    sep = data.find(b"\r\n\r\n")
    return data[sep + 4:] if sep != -1 else b""


def get_root():
    s = connect()
    s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    data, _, _ = read_until_close(s)
    s.close()
    return data


def part_text(name, value):
    return (
        b"--" + BOUNDARY + b"\r\n"
        b'Content-Disposition: form-data; name="' + name + b'"\r\n'
        b"\r\n" + value + b"\r\n"
    )


def part_file(field, filename, content, content_type=b"application/octet-stream"):
    return (
        b"--" + BOUNDARY + b"\r\n"
        b'Content-Disposition: form-data; name="' + field +
        b'"; filename="' + filename + b'"\r\n'
        b"Content-Type: " + content_type + b"\r\n"
        b"\r\n" + content + b"\r\n"
    )


def multipart_request(parts, path=b"/upload"):
    body = b"".join(parts) + b"--" + BOUNDARY + b"--\r\n"
    req = (
        b"POST " + path + b" HTTP/1.1\r\n"
        b"Host: x\r\n"
        b"Connection: close\r\n"
        b"Content-Type: multipart/form-data; boundary=" + BOUNDARY + b"\r\n"
        b"Content-Length: " + str(len(body)).encode() + b"\r\n"
        b"\r\n" + body
    )
    s = connect()
    s.sendall(req)
    data, _, _ = read_until_close(s)
    s.close()
    return data


# ---------------------------------------------------------------- main

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

        print("\n🧪 Multipart form-data:\n")

        # ---------- 1. text fields (upload_handler format: form[K]=V) ----------
        data = multipart_request([part_text(b"username", b"alice")])
        b = body_of(data)
        check("single text field: status 200", status_of(data) == "200", data[:60])
        check("single text field: form_count=1", b"form_count=1" in b, b[:120])
        check("single text field: value", b"form[username]=alice" in b, b[:120])

        data = multipart_request([
            part_text(b"a", b"1"),
            part_text(b"b", b"2"),
            part_text(b"c", b"3"),
        ])
        b = body_of(data)
        check("three text fields: form_count=3", b"form_count=3" in b, b[:120])
        check("three text fields: all values",
              b"form[a]=1" in b and b"form[b]=2" in b and b"form[c]=3" in b,
              b[:120])

        data = multipart_request([
            part_text(b"username", b"alice"),
            part_text(b"age", b"30"),
        ])
        b = body_of(data)
        check("two named text fields: username", b"form[username]=alice" in b, b[:120])
        check("two named text fields: age", b"form[age]=30" in b, b[:120])

        data = multipart_request([part_text(b"empty", b"")])
        b = body_of(data)
        check("empty text field: form_count=1", b"form_count=1" in b, b[:120])
        check("empty text field: empty value", b"form[empty]=" in b, b[:120])

        data = multipart_request([part_text(b"username", "алиса".encode())])
        b = body_of(data)
        check("unicode text field: form_count=1", b"form_count=1" in b, b[:120])
        check("unicode text field: value",
              "form[username]=алиса".encode() in b, b[:120])

        # ---------- 2. files (upload_handler format: file[name=...,filename=...,size=...,content_type=...]) ----------
        content = b"hello world"
        data = multipart_request([
            part_file(b"avatar", b"test.txt", content, b"text/plain"),
        ])
        b = body_of(data)
        check("single file: status 200", status_of(data) == "200", data[:60])
        check("single file: file_count=1", b"file_count=1" in b, b[:120])
        check("single file: filename", b"filename=test.txt" in b, b[:120])
        check("single file: size", b"size=11" in b, b[:120])
        check("single file: content_type", b"content_type=text/plain" in b, b[:120])

        data = multipart_request([
            part_file(b"f1", b"a.txt", b"aaa"),
            part_file(b"f2", b"b.txt", b"bbbb"),
            part_file(b"f3", b"c.txt", b"ccccc"),
        ])
        b = body_of(data)
        check("three files: file_count=3", b"file_count=3" in b, b[:120])
        check("three files: all filenames",
              b"filename=a.txt" in b and b"filename=b.txt" in b
              and b"filename=c.txt" in b, b[:120])

        binary = b"A\x00B\x00C\x00"
        data = multipart_request([
            part_file(b"bin", b"bin.dat", binary, b"application/octet-stream"),
        ])
        b = body_of(data)
        check("binary file with NUL: size", b"size=6" in b, b[:120])

        data = multipart_request([
            part_file(b"img", b"photo.png", b"\x89PNG\r\n", b"image/png"),
        ])
        b = body_of(data)
        check("custom content-type preserved",
              b"content_type=image/png" in b, b[:120])

        # ---------- 3. mixed forms ----------
        data = multipart_request([
            part_text(b"username", b"alice"),
            part_file(b"avatar", b"a.txt", b"hello", b"text/plain"),
        ])
        b = body_of(data)
        check("mixed: form_count=1", b"form_count=1" in b, b[:120])
        check("mixed: file_count=1", b"file_count=1" in b, b[:120])
        check("mixed: text value", b"form[username]=alice" in b, b[:120])
        check("mixed: filename", b"filename=a.txt" in b, b[:120])

        # ---------- 4. filename sanitization ----------
        data = multipart_request([
            part_file(b"f", b"../../etc/passwd", b"x"),
        ])
        b = body_of(data)
        check("sanitize ../../etc/passwd -> passwd",
              b"filename=passwd" in b and b"../" not in b, b[:120])

        data = multipart_request([
            part_file(b"f", b"/etc/passwd", b"x"),
        ])
        b = body_of(data)
        check("sanitize /etc/passwd -> passwd",
              b"filename=passwd" in b, b[:120])

        # ---------- 5. limits ----------
        big = b"x" * (int(ENV["MOJELLY_MAX_BODY"]) + 1)
        data = multipart_request([part_file(b"f", b"big.bin", big)])
        check("oversized body -> 413", status_of(data) == "413", data[:60])

        many = [part_text(f"f{i}".encode(), b"v") for i in range(120)]
        data = multipart_request(many)
        check("too many parts -> 4xx/5xx",
              status_of(data) in ("400", "413", "500"), data[:60])

        # ---------- 6. 415 on non-upload route ----------
        data = multipart_request(
            [part_text(b"username", b"x")],
            path=b"/user",
        )
        check("multipart on non-upload route -> 415",
              status_of(data) == "415", data[:60])

        # ---------- 7. cleanup ----------
        leftover = glob.glob("/tmp/mojelly-upload-*")
        check("no leftover temp files", len(leftover) == 0, leftover[:3])

        # ---------- 8. server still alive ----------
        check("server survived the whole suite", proc.poll() is None,
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
