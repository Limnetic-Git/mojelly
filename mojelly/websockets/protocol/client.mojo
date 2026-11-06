# This code is taken from a publicly available repository distributed under the terms of the MIT license:
# https://github.com/msaelices/mojo-websockets/blob/main/LICENSE
from mojelly.websockets.aliases import CPointer
from std.memory import Pointer
from std.base64 import b64encode
from std.collections import Optional
from mojelly.websockets.aliases import (
    Bytes,
    DEFAULT_MAX_REQUEST_BODY_SIZE,
    DEFAULT_BUFFER_SIZE,
    MAGIC_CONSTANT,
)
from mojelly.websockets.http import (
    build_host_header,
    build_authorization_basic,
    get_date_timestamp,
    encode,
    Header,
    Headers,
    HTTPRequest,
    HTTPResponse,
)
from mojelly.websockets.frames import Frame, Close
from mojelly.websockets.protocol import (
    CONNECTING,
    CLIENT,
    OPEN,
    Protocol,
    Event,
)
from mojelly.websockets.protocol.base import (
    discard,
    parse_buffer,
    receive_data,
    receive_frame,
    send_eof,
)
from mojelly.websockets.streams import StreamReader
from mojelly.websockets.utils.bytes import (
    b64decode,
    gen_token,
    str_to_bytes,
    gen_mask,
)
from mojelly.websockets.utils.handshake import ws_accept_key
from mojelly.websockets.utils.uri import URI


struct ClientProtocol(Copyable, Movable, Protocol):
    """
    Sans-I/O implementation of a WebSocket client connection.
    """

    comptime side = CLIENT

    var key: String
    var wsuri: URI
    var origin: Optional[String]
    var reader: StreamReader
    var events: List[Event]
    var writes: Bytes
    var state: Int
    var expect_cont_frame: Bool
    var parser_exc: Optional[Error]
    var handshake_exc: Optional[Error]
    var curr_size: Optional[Int]
    # Close code and reason, set when a close frame is sent or received.
    var close_rcvd: Optional[Close]
    var close_sent: Optional[Close]
    var close_rcvd_then_sent: Optional[Bool]
    var eof_sent: Bool
    var discard_sent: Bool

    def __init__(
        out self,
        var uri: URI,
        var key: Optional[String] = None,
        var origin: Optional[String] = None,
    ):
        if not key:
            self.key = b64encode(gen_token(16))
        else:
            self.key = key.value()
        self.wsuri = uri.copy()
        self.origin = origin^
        self.reader = StreamReader()
        self.events = List[Event]()
        self.writes = Bytes(capacity=DEFAULT_BUFFER_SIZE)
        self.state = CONNECTING
        self.expect_cont_frame = False
        self.parser_exc = None
        self.handshake_exc = None
        self.curr_size = None

        self.close_rcvd = None
        self.close_sent = None
        self.close_rcvd_then_sent = None
        self.eof_sent = False
        self.discard_sent = False

    def __init__(out self, *, copy: ClientProtocol):
        self.key = copy.key
        self.wsuri = copy.wsuri.copy()
        self.origin = copy.origin

        self.reader = StreamReader()
        # This weirdly makes the copy to cause an error while binding the server socket
        # self.events = copy.events
        self.events = List[Event]()
        self.writes = Bytes(capacity=DEFAULT_BUFFER_SIZE)
        self.state = copy.state
        self.expect_cont_frame = copy.expect_cont_frame
        self.parser_exc = copy.parser_exc
        self.handshake_exc = copy.handshake_exc
        self.curr_size = copy.curr_size

        self.close_rcvd = copy.close_rcvd.copy()
        self.close_sent = copy.close_sent.copy()
        self.close_rcvd_then_sent = copy.close_rcvd_then_sent
        self.eof_sent = copy.eof_sent
        self.discard_sent = copy.discard_sent

    # ===-------------------------------------------------------------------=== #
    # Trait implementations
    # ===-------------------------------------------------------------------=== #

    def get_reader_ptr(ref self) -> Pointer[StreamReader, origin_of(self)]:
        """Get the reader of the protocol."""
        return Pointer(to=self.reader).unsafe_origin_cast[origin_of(self)]()

    def get_state(self) -> Int:
        """
        Get the current state of the connection.

        Returns:
            The current state of the connection.
        """
        return self.state

    def set_state(mut self, state: Int):
        """Set the state of the protocol.

        Args:
            state: The state of the protocol.
        """
        self.state = state

    def write_data(mut self, data: Bytes) -> None:
        """Write data to the protocol."""
        self.writes += data.copy()

    def events_received(mut self) -> List[Event]:
        """
        Fetch events generated from data received from the network.

        Call this method immediately after any of the ``receive_*()`` methods.

        Process resulting events, likely by passing them to the application.

        Returns:
            Events read from the connection.
        """
        var events = self.events^
        self.events = List[Event]()
        return events.copy()

    def add_event(mut self, event: Event) -> None:
        """
        Add an event to the list of events to return to the application.

        Call this method immediately after any of the ``receive_*()`` methods.

        Args:
            event: Event to add to the list of events.

        """
        self.events.append(event.copy())

    # Public method for getting outgoing data after receiving data or sending events.

    def data_to_send(mut self) -> Bytes:
        """
        Obtain data to send to the network.

        Call this method immediately after any of the `receive_*()`,
        `send_*()`, or `fail` methods.

        Write resulting data to the connection.

        The empty bytestring `websockets.protocol.SEND_EOF` signals
        the end of the data stream. When you receive it, half-close the TCP
        connection.

        Returns:
            Data to write to the connection.

        """
        # See https://github.com/python-websockets/websockets/blob/59d4dcf779fe7d2b0302083b072d8b03adce2f61/src/websockets/protocol.py#L494
        var writes = self.writes^
        self.writes = Bytes()
        return writes.copy()

    def expect_continuation_frame(self) -> Bool:
        """Check if a continuation frame is expected."""
        return self.expect_cont_frame

    def set_expect_continuation_frame(mut self, value: Bool) -> None:
        """Set the expectation of a continuation frame."""
        self.expect_cont_frame = value

    def get_curr_size(self) -> Optional[Int]:
        """Get the current size of the protocol."""
        return self.curr_size

    def set_curr_size(mut self, size: Optional[Int]) -> None:
        """Set the current size of the protocol."""
        self.curr_size = size

    def get_close_rcvd(self) -> Optional[Close]:
        """Get the close frame received."""
        return self.close_rcvd.copy()

    def set_close_rcvd(mut self, close: Optional[Close]) -> None:
        """Set the close frame received."""
        self.close_rcvd = close.copy()

    def get_close_sent(self) -> Optional[Close]:
        """Get the close frame sent."""
        return self.close_sent.copy()

    def set_close_sent(mut self, close: Optional[Close]) -> None:
        """Set the close frame sent."""
        self.close_sent = close.copy()

    def get_close_rcvd_then_sent(self) -> Optional[Bool]:
        """Check if the close frame was received then sent."""
        return self.close_rcvd_then_sent

    def set_close_rcvd_then_sent(mut self, value: Optional[Bool]) -> None:
        """Set if the close frame was received then sent."""
        self.close_rcvd_then_sent = value

    def get_eof_sent(self) -> Bool:
        """Check if the EOF was sent."""
        return self.eof_sent

    def set_eof_sent(mut self, value: Bool) -> None:
        """Set if the EOF was sent."""
        self.eof_sent = value

    def get_discard_sent(self) -> Bool:
        """Get the flag of discarding received data."""
        return self.discard_sent

    def set_discard_sent(mut self, value: Bool) -> None:
        """Set the flag of discarding received data."""
        self.discard_sent = value

    def get_parser_exc(self) -> Optional[Error]:
        """Get the parser exception."""
        return self.parser_exc

    def set_parser_exc(mut self, exc: Optional[Error]) -> None:
        """Set the parser exception."""
        self.parser_exc = exc

    def get_handshake_exc(self) -> Optional[Error]:
        """Get the handshake exception."""
        return self.handshake_exc

    def set_handshake_exc(mut self, exc: Optional[Error]) -> None:
        """Set the handshake exception."""
        self.handshake_exc = exc

    # ===-------------------------------------------------------------------=== #
    # Methods
    # ===-------------------------------------------------------------------=== #

    def connect(self) raises -> HTTPRequest:
        """
        Create a handshake request to open a connection.

        You must send the handshake request with :meth:`send_request`.

        You can modify it before sending it, for example to add HTTP headers.

        Returns:
            WebSocket handshake request event to send to the server.

        """
        var is_secure = self.wsuri.is_wss() or self.wsuri.is_https()
        var host_header = build_host_header(
            self.wsuri.get_hostname(), self.wsuri.get_port(), is_secure
        )

        var headers = Headers(
            Header("Host", host_header),
            Header("Upgrade", "websocket"),
            Header("Connection", "Upgrade"),
            Header("Sec-WebSocket-Key", self.key),
            Header("Sec-WebSocket-Version", "13"),
        )
        if self.origin:
            headers["Origin"] = self.origin.value()

        var opt_user_info = self.wsuri.get_user_info()
        if opt_user_info:
            var user_info = opt_user_info.value()
            headers["Authorization"] = build_authorization_basic(
                user_info[0], user_info[1]
            )

        # if self.available_extensions is not None:
        #     extensions_header = build_extension(
        #         [
        #             (extension_factory.name, extension_factory.get_request_params())
        #             for extension_factory in self.available_extensions
        #         ]
        #     )
        #     headers["Sec-WebSocket-Extensions"] = extensions_header
        #
        # if self.available_subprotocols is not None:
        #     protocol_header = build_subprotocol(self.available_subprotocols)
        #     headers["Sec-WebSocket-Protocol"] = protocol_header

        return HTTPRequest(self.wsuri, headers=headers)

    def send_request(mut self, request: HTTPRequest) raises -> None:
        """
        Send a handshake request to the server.

        Args:
            request: WebSocket handshake request event.
        """
        self.write_data(encode(request.copy()))

    def process_response(mut self, response: HTTPResponse) raises -> None:
        """Process the handshare response from the server."""
        comptime assert Self.side == CLIENT, (
            "Protocol.process_response() is only available for client"
            " connections."
        )

        if response.status_code != 101:
            raise Error("InvalidStatus: " + String(response.status_code))

        # TODO: Support for several "Connection" headers
        # See process_response in the Python implementation
        if "Connection" not in response.headers:
            raise Error('InvalidHeader: Missing "Connection" header')

        var connection = response.headers["Connection"]

        if connection.lower() != "upgrade":
            raise Error(
                'InvalidUpgrade: Response "Connection" header is not "Upgrade"'
            )

        if "Upgrade" not in response.headers:
            raise Error('InvalidHeader: Missing "Upgrade" header')

        # TODO: Support for several "Upgrade" headers
        # See process_response in the Python implementation
        var upgrade = response.headers["Upgrade"]

        if upgrade != "websocket":
            raise Error(
                'InvalidUpgrade: Response "Upgrade" header is not "websocket"'
            )

        if "Sec-WebSocket-Accept" not in response.headers:
            raise Error('InvalidHeader: Missing "Sec-WebSocket-Accept" header')

        var s_w_accept = response.headers["Sec-WebSocket-Accept"]
        if s_w_accept != ws_accept_key(self.key):
            raise Error(
                'InvalidHeader: "Sec-WebSocket-Accept" header is invalid'
            )

        self.set_state(OPEN)
