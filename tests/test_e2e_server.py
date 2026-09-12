#!/usr/bin/env python3
"""End-to-End integration test suite for Mojelly HTTP Server."""

import json
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

SERVER_HOST = "127.0.0.1"
SERVER_PORT = 8080
SERVER_URL = f"http://{SERVER_HOST}:{SERVER_PORT}"


def wait_for_server(url, timeout=5.0):
    start = time.time()
    while time.time() - start < timeout:
        try:
            with urllib.request.urlopen(url, timeout=0.5) as resp:
                if resp.status == 200:
                    return True
        except Exception:
            time.sleep(0.1)
    return False


def run_tests():
    # 1. Build server if not built
    if not os.path.exists("./server"):
        print("🔨 Building server binary...")
        build_res = subprocess.run(["bash", "build.sh"], capture_output=True, text=True)
        if build_res.returncode != 0:
            print("❌ Build failed:\n", build_res.stderr)
            sys.exit(1)

    print("🚀 Starting Mojelly server for integration tests...")
    server_proc = subprocess.Popen(
        ["./server"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        preexec_fn=os.setsid,
    )

    passed = 0
    failed = 0

    def assert_test(name, condition, details=""):
        nonlocal passed, failed
        if condition:
            passed += 1
            print(f"  ✅ {name}")
        else:
            failed += 1
            print(f"  ❌ {name}: {details}")

    try:
        if not wait_for_server(SERVER_URL):
            print("❌ Server failed to start within timeout!")
            sys.exit(1)

        print("\n🧪 Running Integration Tests:\n")

        # 1. GET /
        req = urllib.request.Request(f"{SERVER_URL}/")
        with urllib.request.urlopen(req) as resp:
            assert_test("GET / returns 200 OK", resp.status == 200)
            body = resp.read().decode("utf-8")
            assert_test("GET / body matches 'Hello, World'", body == "Hello, World")
            assert_test(
                "GET / Content-Type is text/plain",
                resp.headers.get("Content-Type") == "text/plain",
            )

        # 2. GET /json
        req = urllib.request.Request(f"{SERVER_URL}/json")
        with urllib.request.urlopen(req) as resp:
            assert_test("GET /json returns 200 OK", resp.status == 200)
            assert_test(
                "GET /json Content-Type is application/json",
                resp.headers.get("Content-Type") == "application/json",
            )
            data = json.loads(resp.read().decode("utf-8"))
            assert_test(
                "GET /json payload contains expected fields",
                data.get("nickname") == "Limnetic" and data.get("age") == 17,
            )

        # 3. GET /html
        req = urllib.request.Request(f"{SERVER_URL}/html")
        with urllib.request.urlopen(req) as resp:
            assert_test("GET /html returns 200 OK", resp.status == 200)
            assert_test(
                "GET /html Content-Type is text/html",
                resp.headers.get("Content-Type") == "text/html",
            )
            body = resp.read().decode("utf-8")
            assert_test("GET /html contains HTML tags", "<!DOCTYPE html>" in body)

        # 4. GET /style.css
        req = urllib.request.Request(f"{SERVER_URL}/style.css")
        with urllib.request.urlopen(req) as resp:
            assert_test("GET /style.css returns 200 OK", resp.status == 200)
            assert_test(
                "GET /style.css Content-Type is text/css",
                resp.headers.get("Content-Type") == "text/css",
            )
            body = resp.read().decode("utf-8")
            assert_test("GET /style.css contains css body rule", "body {" in body)

        # 5. GET /headers (Custom request and response headers)
        req = urllib.request.Request(
            f"{SERVER_URL}/headers",
            headers={"X-Test-Request": "MyCustomValue123"},
        )
        with urllib.request.urlopen(req) as resp:
            assert_test("GET /headers returns 200 OK", resp.status == 200)
            body = resp.read().decode("utf-8")
            assert_test(
                "GET /headers echoes incoming header",
                body == "Header received: MyCustomValue123",
            )
            assert_test(
                "GET /headers sets outgoing X-Test-Response header",
                resp.headers.get("X-Test-Response") == "MojellyOK",
            )

        # 6. GET /query with query parameters
        req = urllib.request.Request(f"{SERVER_URL}/query?foo=alpha&bar=beta")
        with urllib.request.urlopen(req) as resp:
            assert_test("GET /query returns 200 OK", resp.status == 200)
            body = resp.read().decode("utf-8")
            assert_test(
                "GET /query parsed path and query_string",
                body == "Path: /query, Query: foo=alpha&bar=beta",
            )

        # 7. GET /json with query string (verifying existing routes match with query)
        req = urllib.request.Request(f"{SERVER_URL}/json?cache=false")
        with urllib.request.urlopen(req) as resp:
            assert_test("GET /json?cache=false returns 200 OK", resp.status == 200)

        # 8. POST /user (Valid adult DTO)
        data = json.dumps({"nickname": "Alice", "age": 25}).encode("utf-8")
        req = urllib.request.Request(
            f"{SERVER_URL}/user",
            data=data,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req) as resp:
            assert_test("POST /user adult returns 200 OK", resp.status == 200)
            body = resp.read().decode("utf-8")
            assert_test(
                "POST /user adult response body",
                body == "Aliceis adult",
            )

        # 9. POST /user (Valid underage DTO)
        data = json.dumps({"nickname": "Charlie", "age": 15}).encode("utf-8")
        req = urllib.request.Request(
            f"{SERVER_URL}/user",
            data=data,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req) as resp:
            assert_test("POST /user minor returns 200 OK", resp.status == 200)
            body = resp.read().decode("utf-8")
            assert_test(
                "POST /user minor response body",
                body == "Charlieis not adult",
            )

        # 10. POST /user (Invalid JSON body)
        req = urllib.request.Request(
            f"{SERVER_URL}/user",
            data=b"not a valid json {",
            headers={"Content-Type": "application/json"},
        )
        try:
            urllib.request.urlopen(req)
            assert_test("POST /user invalid JSON returns 400", False, "Expected HTTPError")
        except urllib.error.HTTPError as e:
            assert_test("POST /user invalid JSON returns 400", e.code == 400)
            body = e.read().decode("utf-8")
            assert_test("POST /user invalid JSON body text", body == "Invalid JSON body")

        # 11. 404 Not Found on missing route
        try:
            urllib.request.urlopen(f"{SERVER_URL}/nonexistent_endpoint")
            assert_test("GET /nonexistent returns 404", False, "Expected 404")
        except urllib.error.HTTPError as e:
            assert_test("GET /nonexistent returns 404", e.code == 404)
            assert_test("GET /nonexistent reason is Not Found", e.reason == "Not Found")

        # 12. 404 on HTTP method mismatch (POST to a GET route)
        req = urllib.request.Request(f"{SERVER_URL}/html", data=b"data")
        try:
            urllib.request.urlopen(req)
            assert_test("POST /html (method mismatch) returns 404", False)
        except urllib.error.HTTPError as e:
            assert_test("POST /html (method mismatch) returns 404", e.code == 404)

        # 13. Large Body Streaming (10KB JSON payload)
        large_nick = "Alice" * 2000
        data = json.dumps({"nickname": large_nick, "age": 28}).encode("utf-8")
        req = urllib.request.Request(
            f"{SERVER_URL}/user",
            data=data,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req) as resp:
            assert_test("Large 10KB payload POST returns 200 OK", resp.status == 200)
            body = resp.read().decode("utf-8")
            assert_test(
                "Large 10KB payload response body preserved",
                body.startswith("AliceAlice") and body.endswith("is adult"),
            )

        # 14. Fragmented TCP delivery over raw socket
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.connect((SERVER_HOST, SERVER_PORT))
        parts = [
            b"GET /headers HTTP/1.1\r\n",
            b"Host: localhost:8080\r\n",
            b"X-Test-Request: Frag",
            b"mentedStream\r\n",
            b"\r\n",
        ]
        for p in parts:
            s.sendall(p)
            time.sleep(0.02)
        raw_resp = s.recv(4096).decode("utf-8")
        s.close()
        assert_test(
            "Fragmented TCP request assembled correctly",
            "HTTP/1.1 200 OK" in raw_resp
            and "Header received: FragmentedStream" in raw_resp,
        )

        # 15. HTTP Keep-Alive (5 requests on single persistent connection)
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.connect((SERVER_HOST, SERVER_PORT))
        keep_alive_ok = True
        for i in range(5):
            req_data = (
                f"GET /query?req={i} HTTP/1.1\r\n"
                f"Host: localhost:8080\r\n\r\n"
            ).encode("utf-8")
            s.sendall(req_data)
            resp_buf = b""
            while b"Path: /query" not in resp_buf:
                chunk = s.recv(1024)
                if not chunk:
                    keep_alive_ok = False
                    break
                resp_buf += chunk
            if f"Query: req={i}" not in resp_buf.decode("utf-8"):
                keep_alive_ok = False
                break
        s.close()
        assert_test("HTTP Keep-Alive 5-request pipelining succeeds", keep_alive_ok)

        # 16. Malformed HTTP Syntax handling
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.connect((SERVER_HOST, SERVER_PORT))
        s.sendall(b"INVALID_HTTP_COMMAND_LINE\r\n\r\n")
        err_resp = s.recv(1024).decode("utf-8")
        s.close()
        assert_test(
            "Malformed HTTP syntax returns 400 Bad Request",
            "HTTP/1.1 400 Bad Request" in err_resp,
        )

    finally:
        print("\n🛑 Stopping server...")
        try:
            os.killpg(os.getpgid(server_proc.pid), signal.SIGTERM)
            server_proc.wait(timeout=2.0)
        except Exception:
            pass

    print(f"\n==========================================")
    print(f"Results: {passed} passed, {failed} failed")
    print(f"==========================================")
    if failed > 0:
        sys.exit(1)


if __name__ == "__main__":
    run_tests()
