# This code is taken from a publicly available repository distributed under the terms of the MIT license:
# https://github.com/msaelices/mojo-websockets/blob/main/LICENSE
from std.memory import Pointer

# Указатель для границ FFI, где время жизни памяти контролирует вызывающий код
comptime CPointer[T: AnyType] = Pointer[mut=True, T, MutUntrackedOrigin]

comptime Bytes = List[Byte]
comptime Duration = Int
comptime DEFAULT_BUFFER_SIZE = 65536
comptime DEFAULT_MAX_REQUEST_BODY_SIZE = 10 * 1024 * 1024  # 10 MB
comptime DEFAULT_TCP_KEEP_ALIVE = Duration(
    15 * 1000 * 1000 * 1000
)  # 15 seconds

# It is a "magic" constant, see:
# https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API/Writing_WebSocket_servers#server_handshake_response
comptime MAGIC_CONSTANT = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

from std.sys import CompilationTarget

comptime os_is_linux = CompilationTarget.is_linux
comptime os_is_macos = CompilationTarget.is_macos


def os_is_windows() -> Bool:
    return False
