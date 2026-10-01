#!/usr/bin/env python3
"""E2E tests: HTTP/1.1 protocol behaviour (framing, keep-alive, pipelining,
fragmentation, large bodies, concurrent clients)."""

import threading
import time

from e2e_common import Reader, Suite, connect, get, request


def main():
    with Suite("HTTP protocol behaviour") as s:
        # ---- response framing -------------------------------------------
        r = get("/")
        s.check("status line is HTTP/1.1 200 OK", r.status == 200 and r.reason == "OK", (r.status, r.reason))
        s.check("Content-Length equals the body length",
                r.header("Content-Length") == str(len(r.body)), r.header("Content-Length"))
        s.check("plain text content type", r.header("Content-Type") == "text/plain", r.header("Content-Type"))
        for path, ctype in (("/json", "application/json"), ("/html", "text/html"),
                            ("/style.css", "text/css")):
            r = get(path)
            s.check(f"{path}: Content-Type and Content-Length",
                    r.header("Content-Type") == ctype
                    and r.header("Content-Length") == str(len(r.body)),
                    (r.header("Content-Type"), r.header("Content-Length"), len(r.body)))
        r = get("/does-not-exist")
        s.check("404: reason phrase and framing",
                r.status == 404 and r.reason == "Not Found"
                and r.header("Content-Length") == str(len(r.body)), (r.status, r.reason))
        r = get("/user/nope-nope", method="POST")
        s.check("404 on method mismatch keeps the connection usable", r.status == 404)

        # ---- keep-alive vs close ----------------------------------------
        sock = connect()
        rd = Reader(sock)
        sock.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        first = rd.read_response()
        sock.sendall(b"GET /json HTTP/1.1\r\nHost: x\r\n\r\n")
        second = rd.read_response()
        s.check("keep-alive: two requests on one connection",
                first.body == b"Hello, World" and b"nickname" in second.body)
        sock.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        third = rd.read_response()
        s.check("Connection: close request is answered", third.status == 200)
        s.check("server closes the connection after Connection: close", rd.closed_by_peer())
        sock.close()

        sock = connect()
        rd = Reader(sock)
        sock.sendall(b"GET / HTTP/1.0\r\nHost: x\r\n\r\n")
        r = rd.read_response()
        s.check("HTTP/1.0 request is answered", r.status == 200 and r.body == b"Hello, World")
        s.check("HTTP/1.0 connection is closed after the response", rd.closed_by_peer())
        sock.close()

        # ---- pipelining -------------------------------------------------
        sock = connect()
        rd = Reader(sock)
        sock.sendall(
            b"GET / HTTP/1.1\r\nHost: x\r\n\r\n"
            b"GET /user/5 HTTP/1.1\r\nHost: x\r\n\r\n"
            b"GET /json HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
        )
        bodies = [rd.read_response().body for _ in range(3)]
        s.check("pipelined requests are answered in order",
                bodies[0] == b"Hello, World" and bodies[1] == b"User ID: 5" and b"nickname" in bodies[2],
                bodies)
        sock.close()

        # ---- request bodies ---------------------------------------------
        r = get("/echo", method="POST", body=b"hello")
        s.check("POST body is delivered", r.body == b"5:hello", r.body)
        r = get("/echo", method="POST", body=b"")
        s.check("POST with an empty body", r.status == 200 and r.body == b"0:", r.body)

        payload = bytes(range(256)) * 4  # all byte values, includes NUL
        r = get("/echo", method="POST", body=payload)
        s.check("binary body (all byte values) is delivered intact",
                r.body[:5] == b"1024:" and len(r.body) == 5 + 1024, len(r.body))

        big = b"x" * (1024 * 1024)
        r = get("/echo", method="POST", body=big)
        s.check("1 MiB body is delivered",
                r.body.startswith(b"1048576:") and len(r.body) == len(b"1048576:") + len(big),
                r.body[:20])

        # body split across packets, with pauses
        sock = connect()
        rd = Reader(sock)
        sock.sendall(b"POST /echo HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Length: 10\r\n\r\nabc")
        time.sleep(0.3)
        sock.sendall(b"defg")
        time.sleep(0.3)
        sock.sendall(b"hij")
        r = rd.read_response()
        s.check("body arriving in three packets is reassembled", r.body == b"10:abcdefghij", r.body)
        sock.close()

        # header block split mid-line, one byte at a time
        sock = connect()
        rd = Reader(sock)
        raw = b"GET /user/77 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
        for i in range(len(raw)):
            sock.sendall(raw[i:i + 1])
        r = rd.read_response()
        s.check("request sent one byte at a time is parsed", r.body == b"User ID: 77", r.body)
        sock.close()

        # chunked request body
        sock = connect()
        rd = Reader(sock)
        sock.sendall(
            b"POST /echo HTTP/1.1\r\nHost: x\r\nConnection: close\r\n"
            b"Transfer-Encoding: chunked\r\n\r\n"
            b"5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
        )
        r = rd.read_response()
        s.check("chunked request body is decoded", r.body == b"11:hello world", r.body)
        sock.close()

        # ---- malformed input --------------------------------------------
        for name, raw in (
            ("garbage request line", b"NOT HTTP AT ALL\r\n\r\n"),
            ("bad HTTP version", b"GET / HTTP/9.9\r\nHost: x\r\n\r\n"),
            ("header without colon", b"GET / HTTP/1.1\r\nbroken header line\r\n\r\n"),
        ):
            try:
                r = request(raw)
                s.check(f"{name} -> 4xx", 400 <= r.status < 500, r.status)
            except EOFError:
                s.check(f"{name} -> connection closed", True)
        r = get("/")
        s.check("server still serves after malformed requests", r.status == 200)

        # ---- header edge cases ------------------------------------------
        r = get("/headers", headers={"X-Test-Request": "  padded  "})
        s.check("header value is trimmed", b"Header received: padded" == r.body, r.body)
        r = get("/headers", headers={"x-test-request": "lower"})
        s.check("lowercase header name is found", r.body == b"Header received: lower", r.body)
        r = get("/headers", headers={"X-TEST-REQUEST": "UPPER"})
        s.check("uppercase header name is found", r.body == b"Header received: UPPER", r.body)
        r = get("/headers", headers={"X-Test-Request": "a:b:c"})
        s.check("colons inside a header value are kept", r.body == b"Header received: a:b:c", r.body)
        r = get("/headers", headers={"X-Test-Request": "x" * 4000})
        s.check("a 4 KB header value is accepted", r.body == b"Header received: " + b"x" * 4000, len(r.body))
        r = get("/headers")
        s.check("custom response header is sent", r.header("X-Test-Response") == "MojellyOK", r.headers)

        # ---- concurrency ------------------------------------------------
        errors = []

        def worker(wid):
            try:
                sock = connect(timeout=10)
                rd = Reader(sock)
                for i in range(25):
                    n = wid * 1000 + i
                    sock.sendall(f"GET /user/{n} HTTP/1.1\r\nHost: x\r\n\r\n".encode())
                    got = rd.read_response().body
                    if got != f"User ID: {n}".encode():
                        errors.append((wid, i, got))
                        return
                sock.close()
            except Exception as exc:  # noqa: BLE001
                errors.append((wid, repr(exc)))

        threads = [threading.Thread(target=worker, args=(w,)) for w in range(40)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=60)
        s.check("40 concurrent keep-alive clients get their own answers", not errors, errors[:3])

        def churn(results):
            ok = 0
            for _ in range(50):
                try:
                    if get("/").body == b"Hello, World":
                        ok += 1
                except Exception:  # noqa: BLE001
                    pass
            results.append(ok)

        res = []
        threads = [threading.Thread(target=churn, args=(res,)) for _ in range(10)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=60)
        s.check("10 clients x 50 short-lived connections all succeed",
                sum(res) == 500, sum(res))

        s.finish()


if __name__ == "__main__":
    main()
