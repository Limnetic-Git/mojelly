# This code is taken from a publicly available repository distributed under the terms of the MIT license:
# https://github.com/msaelices/mojo-websockets/blob/main/LICENSE
from std.collections import Optional
from mojelly.websockets.aliases import Bytes, DEFAULT_BUFFER_SIZE
from mojelly.websockets.utils.bytes import EOL


trait Streamable:
    def position(self) -> Int:
        ...

    def restore(mut self, position: Int):
        ...

    def feed_data(mut self, data: Bytes) raises -> None:
        """
        Write data to the stream.

        `feed_data` cannot be called after `feed_eof`.

        Args:
            data: Data to write.

        Raises:
            EOFError: If the stream has ended.

        """
        ...

    def feed_eof(mut self) raises -> None:
        """
        End the stream.

        `feed_eof` cannot be called more than once.

        Raises:
            EOFError: If the stream has ended.

        """
        ...

    def read_line(mut self, m: Int) raises -> Optional[Bytes]:
        """
        Read a LF-terminated line from the stream.

        The return value includes the LF character.

        Args:
            m: Maximum number bytes to read; this is a security limit.

        Raises:
            EOFError: If the stream ends without a LF.
            RuntimeError: If the stream ends in more than ``m`` bytes.
        """
        ...

    def read_exact(mut self, n: Int) raises -> Optional[Bytes]:
        """
        Read a given number of bytes from the stream.

        Args:
            n: How many bytes to read.

        Raises:
            EOFError: If the stream ends in less than `n` bytes.
        """
        ...

    def read_to_eof(mut self, m: Int) raises -> Optional[Bytes]:
        """
        Read all bytes from the stream.

        Args:
            m: Maximum number bytes to read; this is a security limit.

        Raises:
            RuntimeError: If the stream ends in more than `m` bytes.
        """
        ...

    def at_eof(self) -> Bool:
        """
        Tell whether the stream has ended and all data was read.
        """
        ...


struct StreamReader(Copyable, Movable, Streamable):
    """
    Stream reader.
    """

    var buffer: Bytes
    var eof: Bool
    var offset: Int

    def __init__(out self):
        self.buffer = Bytes(capacity=DEFAULT_BUFFER_SIZE)
        self.offset = 0
        self.eof = False

    def __init__(out self, *, deinit move: StreamReader):
        self.buffer = move.buffer^
        self.offset = move.offset
        self.eof = move.eof

    def position(self) -> Int:
        return self.offset

    def restore(mut self, position: Int):
        self.offset = position

    def feed_data(mut self, data: Bytes) raises -> None:
        """
        Write data to the stream.

        `feed_data` cannot be called after `feed_eof`.

        Args:
            data: Data to write.

        Raises:
            EOFError: If the stream has ended.

        """
        if self.eof:
            raise Error("EOFError: stream ended")
        self.buffer += data.copy()

    def advance(mut self, n: Int) -> None:
        """
        Advance `n` bytes of the buffer.

        Args:
            n: Number of bytes to advance.
        """
        self.offset += n

    def feed_eof(mut self) raises -> None:
        """
        End the stream.

        `feed_eof` cannot be called more than once.

        Raises:
            EOFError: If the stream has ended.

        """
        if self.eof:
            raise Error("EOFError: stream ended")
        self.eof = True

    def read_line(mut self, m: Int) raises -> Optional[Bytes]:
        """
        Read a LF-terminated line from the stream.

        The return value includes the LF character.

        Args:
            m: Maximum number bytes to read; this is a security limit.

        Raises:
            EOFError: If the stream ends without a LF.
            RuntimeError: If the stream ends in more than ``m`` bytes.
        """
        var n: Int  # number of bytes to read
        var p: Int  # number of bytes without a newline
        var found: Bool = False

        var start = self.offset
        for i in range(start, len(self.buffer)):
            if self.buffer[i] == EOL:
                found = True
                n = i + 1
                break
        else:  # no break in the for loop, so not found
            n = len(self.buffer)

        p = n - self.offset
        if p > m:
            raise Error(
                "RuntimeError: read "
                + String(p)
                + " bytes, expected no more than "
                + String(m)
                + " bytes"
            )
        if not found and self.eof:
            raise Error(
                "EOFError: stream ends after "
                + String(p)
                + " bytes, before end of line"
            )
        if n > m + self.offset:
            raise Error(
                "RuntimeError: read "
                + String(n)
                + " bytes, expected no more than "
                + String(m)
                + " bytes"
            )

        if not found:
            return None

        var result = self.buffer[self.offset : n]
        self.offset = n

        return Bytes(result)

    def read_exact(mut self, n: Int) raises -> Optional[Bytes]:
        """
        Read a given number of bytes from the stream.

        Args:
            n: How many bytes to read.

        Raises:
            EOFError: If the stream ends in less than `n` bytes.
        """
        var remaining = len(self.buffer) - self.offset
        if remaining < n:
            if self.eof:
                raise Error(
                    "EOFError: stream ends after "
                    + String(remaining)
                    + " bytes, expected "
                    + String(n)
                    + " bytes"
                )
            return None
        var result = self.buffer[self.offset : self.offset + n]
        self.offset += n
        return Bytes(result)

    def read_to_eof(mut self, m: Int) raises -> Optional[Bytes]:
        # Apply the limit to the remaining data both before and after EOF
        var remaining = len(self.buffer) - self.offset
        if remaining > m:
            raise Error(
                "RuntimeError: read ",
                remaining,
                " bytes, expected no more than ",
                m,
                " bytes",
            )
        if not self.eof:
            return None
        var result = Bytes(self.buffer[self.offset :])
        self.offset = len(self.buffer)
        return result^

    def at_eof(self) -> Bool:
        """
        Tell whether the stream has ended and all data was read.
        """
        if self.offset < len(self.buffer):
            return False
        if self.eof:
            return True
        # When all data was read but the stream hasn't ended, we can't
        # tell if until either feed_data() or feed_eof() is called.
        # TODO: This should be a generator so it would yield nothing
        # So the equivalent python code would be:
        # yield
        # See https://github.com/python-websockets/websockets/blob/d852df7dd6324eaee17fc848f029ada371678cbe/src/websockets/streams.py#L113
        return False

    def discard(mut self) -> None:
        """
        Discard all buffered data, but don't end the stream.
        """
        self.offset = len(self.buffer)
