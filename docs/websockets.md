# WebSocket on Mojo 1.1.0

Import the package as `mojelly.websockets`. The compiler version is pinned in `pixi.toml`; import the standard library through `std`.

The implementation uses ordinary POSIX sockets through Mojo FFI. It requires no separate C source files or specialized WebSocket libraries. It supports synchronous `ws://` connections over IPv4. TLS for `wss://`, IPv6 transport, and an asynchronous server are not implemented.

## Client

```mojo
from mojelly.websockets.sync.client import connect


def main() raises:
    with connect("ws://127.0.0.1:8080/echo")^ as client:
        client.send_text("Hello")
        print(client.recv_text())
```

`^` transfers ownership of the client to the context manager. The returned session borrows the client with a tracked lifetime. The connection closes when the block exits. Both the client and server connections use move semantics without implicitly copying sockets.

For binary messages, use `send_binary(Bytes(...))` and `recv()`. The `recv()` method assembles fragments until the message is complete and handles control frames between fragments. `recv_text()` also validates UTF-8.

## Server

```mojo
from std.collections import Span
from mojelly.websockets.aliases import Bytes
from mojelly.websockets.sync.server import serve, WSConnection


def echo(mut conn: WSConnection, data: Span[Byte, _]) raises:
    conn.send_binary(Bytes(data))


def main() raises:
    with serve[echo]("127.0.0.1", 8080)^ as server:
        server.serve_forever()
```

The handler accepts `mut conn` because sending data changes the protocol state. Data is passed as a borrowed `Span`; create `Bytes(data)` to retain it after the handler returns. The handler receives the assembled message payload. This server handles connections sequentially.

The socket closes when its owner is destroyed. Explicitly copying a low-level `Socket` duplicates its descriptor through `dup`; normal connection transfers use move semantics.

## Tests

Run only the unit tests from the project root:

```sh
pixi run test-unit
```

The 46 named Mojo tests in `tests/unit/websockets.mojo` cover UTF-8 and integer conversion, base64, SHA-1, the handshake key, URIs, buffers, HTTP headers, masking, frames, and connection closure. Their inputs are fixed; they require no network connections, server processes, current time, or random masks.

`tests/test_websockets_unit.py` compiles the test executable once and runs each function separately through Python's standard `unittest` module. The output shows the result of each test. To run the same checks directly with Mojo:

```sh
pixi run mojo run -I . tests/unit/websockets.mojo
```

Run all unit tests and the existing interoperability checks with one command:

```sh
pixi run test
```

The full run also includes four checks from `tests/test_websockets.py`: package and public API checks, a Mojo server communicating with a Python client, rejection of an unmasked frame, and a Mojo client communicating with a Python server. The network checks cover partial handshakes, zero bytes, large and fragmented messages, ping/pong, and close frames.

These tests check component behavior and interoperability; they are not a complete RFC 6455 conformance suite or a load test suite.

## Migration changes

The removed `fn`, `alias`, and `@value` constructs have been replaced with `def`, `comptime`, and current constructors. `Writer`, collections, string indexing, and pointer operations have been updated. Buffers use public `List` methods; internal pointers retain their owner's origin. Nullable libc pointers use `OptionalPointer`.

The handshake key is computed from the binary SHA-1 digest without an intermediate UTF-8 conversion. Client keys and masks use random bytes from the OS. An incomplete frame is retained until the next read, and partial writes continue until the entire buffer has been sent.

Each file in `mojelly/websockets` starts with the following attribution:

```text
# This code is taken from a publicly available repository distributed under the terms of the MIT license:
# https://github.com/msaelices/mojo-websockets/blob/main/LICENSE
```
