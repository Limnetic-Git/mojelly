"""
WebSocket building blocks for Mojo 1.2 on Linux.

The protocol modules consume and produce bytes without touching the network.
The sync server drives that protocol through epoll; the sync client exposes
bounded blocking operations over the same nonblocking C transport.
"""

# This code is taken from a publicly available repository distributed under the terms of the MIT license:
# https://github.com/msaelices/mojo-websockets/blob/main/LICENSE

from mojelly.websockets.aliases import Bytes
from mojelly.websockets.connection import WebSocket, WebSocketHandler
