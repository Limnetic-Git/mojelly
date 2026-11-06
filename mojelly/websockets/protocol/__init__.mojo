# This code is taken from a publicly available repository distributed under the terms of the MIT license:
# https://github.com/msaelices/mojo-websockets/blob/main/LICENSE
from std.memory import Pointer
from std.collections import Optional
from std.utils import Variant

from mojelly.websockets.aliases import Bytes
from mojelly.websockets.frames import Frame, Close
from mojelly.websockets.http import HTTPRequest, HTTPResponse
from mojelly.websockets.streams import StreamReader

comptime SERVER = 0
comptime CLIENT = 1

comptime CONNECTING = 0
comptime OPEN = 1
comptime CLOSING = 2
comptime CLOSED = 3

comptime SEND_EOF = Bytes()
"""Sentinel signaling that the TCP connection must be half-closed."""

comptime Event = Variant[HTTPRequest, HTTPResponse, Frame, NoneType]


trait Protocol:
    comptime side: Int

    def get_reader_ptr(ref self) -> Pointer[StreamReader, origin_of(self)]:
        """Get the pointer to the reader of the protocol."""
        ...

    def get_state(self) -> Int:
        """Get the state of the protocol."""
        ...

    def set_state(mut self, state: Int):
        """Set the state of the protocol.

        Args:
            state: The state of the protocol.
        """
        ...

    def write_data(mut self, data: Bytes) -> None:
        """Write data to the protocol."""
        ...

    def events_received(mut self) -> List[Event]:
        """
        Fetch events generated from data received from the network.

        Call this method immediately after any of the ``receive_*()`` methods.

        Process resulting events, likely by passing them to the application.

        Returns:
            Events read from the connection.
        """
        ...

    def add_event(mut self, event: Event) -> None:
        """Add an event to the protocol."""
        ...

    def process_response(mut self, response: HTTPResponse) raises -> None:
        """Process the response from the server."""
        ...

    # Public method for getting outgoing data after receiving data or sending events.

    def data_to_send(mut self) -> Bytes:
        """
        Obtain data to send to the network.

        Call this method immediately after any of the ``receive_*()``,
        ``send_*()``, or `fail` methods.

        Write resulting data to the connection.

        The empty bytestring `~websockets.protocol.SEND_EOF` signals
        the end of the data stream. When you receive it, half-close the TCP
        connection.

        Returns:
            Data to write to the connection.
        """
        ...

    def expect_continuation_frame(self) -> Bool:
        """Check if a continuation frame is expected."""
        ...

    def set_expect_continuation_frame(mut self, value: Bool) -> None:
        """Set the expectation of a continuation frame."""
        ...

    def get_curr_size(self) -> Optional[Int]:
        """Get the current size of the protocol."""
        ...

    def set_curr_size(mut self, size: Optional[Int]) -> None:
        """Set the current size of the protocol."""
        ...

    def get_close_rcvd(self) -> Optional[Close]:
        """Get the close frame received."""
        ...

    def set_close_rcvd(mut self, close: Optional[Close]) -> None:
        """Set the close frame received."""
        ...

    def get_close_sent(self) -> Optional[Close]:
        """Get the close frame sent."""
        ...

    def set_close_sent(mut self, close: Optional[Close]) -> None:
        """Set the close frame sent."""
        ...

    def get_close_rcvd_then_sent(self) -> Optional[Bool]:
        """Check if the close frame was received then sent."""
        ...

    def set_close_rcvd_then_sent(mut self, value: Optional[Bool]) -> None:
        """Set if the close frame was received then sent."""
        ...

    def get_eof_sent(self) -> Bool:
        """Check if the EOF was sent."""
        ...

    def set_eof_sent(mut self, value: Bool) -> None:
        """Set if the EOF was sent."""
        ...

    def get_discard_sent(self) -> Bool:
        """Get the flag of discarding received data."""
        ...

    def set_discard_sent(mut self, value: Bool) -> None:
        """Set the flag of discarding received data."""
        ...

    def get_parser_exc(self) -> Optional[Error]:
        """Get the parser exception."""
        ...

    def set_parser_exc(mut self, exc: Optional[Error]) -> None:
        """Set the parser exception."""
        ...

    def get_handshake_exc(self) -> Optional[Error]:
        """Get the handshake exception."""
        ...

    def set_handshake_exc(mut self, exc: Optional[Error]) -> None:
        """Set the handshake exception."""
        ...
