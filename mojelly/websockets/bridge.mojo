"""C ABI adapters; libuv owns connection lifetimes and outbound buffers.

Nullable addresses cross the ABI as UInt64 scalars on Linux x86-64. Mojo's
Optional values are kept inside Mojo; C never interprets their representation.
"""

from std.ffi import external_call
from std.memory.alloc import alloc, dealloc, Layout, ThinAllocation
from mojelly.core.router_handlers import RouterHandlers
from mojelly.http.request import HTTPRequest
from mojelly.websockets.aliases import Bytes, CPointer
from mojelly.websockets.connection import WebSocket, WebSocketHandler
from mojelly.websockets.frames import Frame, OpCode
from mojelly.websockets.http import HTTPRequest as HandshakeRequest
from mojelly.websockets.protocol import OPEN, CLOSING
from mojelly.websockets.protocol.base import receive_data, fail


@fieldwise_init
struct WebSocketState(Movable):
    var socket: WebSocket
    var handler: WebSocketHandler


def _read_text(data: CPointer[UInt8], length: UInt64) -> String:
    return String(
        from_utf8_lossy=Span[UInt8](unsafe_ptr=data, length=Int(length))
    )


def _copy_output(
    data: Bytes,
    out_data: CPointer[UInt64],
    out_len: CPointer[UInt64],
):
    out_len[] = UInt64(len(data))
    out_data[] = 0
    if len(data) == 0:
        return
    var address = external_call["ws_alloc", UInt64, UInt64](UInt64(len(data)))
    if address == 0:
        return
    var ptr = CPointer[UInt8](unsafe_from_address=Int(address))
    for i in range(len(data)):
        ptr.unsafe_offset(i)[] = data[i]
    out_data[] = address


def websocket_open(
    router: CPointer[RouterHandlers],
    url: CPointer[UInt8],
    url_len: UInt64,
    method: CPointer[UInt8],
    method_len: UInt64,
    headers: CPointer[UInt8],
    headers_len: UInt64,
    major: Int32,
    minor: Int32,
    max_size: UInt64,
    max_header_size: UInt64,
    out_data: CPointer[UInt64],
    out_len: CPointer[UInt64],
) abi("C") -> UInt64:
    out_data[] = 0
    out_len[] = 0
    var request = HTTPRequest(
        url=_read_text(url, url_len), method=_read_text(method, method_len)
    )
    request._headers_raw = _read_text(headers, headers_len)
    var socket = WebSocket(
        request^, max_size=Int(max_size), max_header_size=Int(max_header_size)
    )
    try:
        var handler = router[].match_websocket(socket.request)
        if not handler:
            var response = socket.protocol.reject(
                404, "Not Found", "WebSocket route not found"
            )
            socket.protocol.send_response(response)
            _copy_output(socket.protocol.data_to_send(), out_data, out_len)
            return 0
        var raw = (
            socket.request.method
            + " "
            + socket.request.url
            + " HTTP/"
            + String(major)
            + "."
            + String(minor)
            + "\r\n"
            + socket.request._headers_raw
            + "\r\n"
        )
        var data = Bytes(raw.as_bytes())
        receive_data(socket.protocol, data)
        var events = socket.protocol.events_received()
        if len(events) != 1 or not events[0].isa[HandshakeRequest]():
            raise Error("Incomplete WebSocket handshake")
        var response = socket.protocol.accept(events[0][HandshakeRequest])
        socket.protocol.send_response(response)
        _copy_output(socket.protocol.data_to_send(), out_data, out_len)
        if response.status_code != 101 or out_data[] == 0:
            return 0
        var allocation = alloc(Layout[WebSocketState].single())
        var state = allocation^.unsafe_leak()
        state.unsafe_write(WebSocketState(socket^, handler.value()))
        return UInt64(Int(state))
    except:
        try:
            var response = socket.protocol.reject(
                400, "Bad Request", "Invalid WebSocket handshake"
            )
            socket.protocol.send_response(response)
            _copy_output(socket.protocol.data_to_send(), out_data, out_len)
        except:
            pass
        return 0


def websocket_receive(
    opaque: CPointer[NoneType],
    data: CPointer[UInt8],
    length: UInt64,
    out_data: CPointer[UInt64],
    out_len: CPointer[UInt64],
    out_close: CPointer[Int32],
) abi("C"):
    var pointer = opaque.unsafe_bitcast[WebSocketState]()
    ref state = pointer[]
    out_close[] = 0
    try:
        receive_data(
            state.socket.protocol,
            Bytes(Span[UInt8](unsafe_ptr=data, length=Int(length))),
        )
        var events = state.socket.protocol.events_received()
        if not state.socket.protocol.get_parser_exc():
            for event in events:
                if not event.isa[Frame]() or not event[Frame].is_data():
                    continue
                if event[Frame].opcode != OpCode.OP_CONT:
                    state.socket.message_opcode = event[Frame].opcode
                state.socket.message.extend(event[Frame].data[:])
                if event[Frame].fin:
                    var message = state.socket.message.copy()
                    state.socket.message.clear()
                    state.handler(state.socket, message)
                    if state.socket.protocol.get_state() != OPEN:
                        break
    except:
        try:
            if state.socket.protocol.get_state() == OPEN:
                fail(state.socket.protocol, 1011, "WebSocket handler failed")
        except:
            pass
        out_close[] = 1
    _copy_output(state.socket.protocol.data_to_send(), out_data, out_len)
    if out_close[] == 0 and state.socket.protocol.get_state() == CLOSING:
        out_close[] = 2
    if state.socket.protocol.get_eof_sent():
        out_close[] = 1


def websocket_free(opaque: CPointer[NoneType]) abi("C"):
    var pointer = opaque.unsafe_bitcast[WebSocketState]()
    _ = pointer.unsafe_take_pointee()
    dealloc(
        ThinAllocation(unsafe_owned_ptr=pointer).unsafe_with_layout(
            Layout[WebSocketState].single()
        )
    )
