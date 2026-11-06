# This code is taken from a publicly available repository distributed under the terms of the MIT license:
# https://github.com/msaelices/mojo-websockets/blob/main/LICENSE
# Code adapted from lightbug_http
from std.sys.defines import get_defined_string


struct LogLevel(Copyable, Movable):
    comptime FATAL = 0
    comptime ERROR = 1
    comptime WARN = 2
    comptime INFO = 3
    comptime DEBUG = 4


def get_log_level() -> Int:
    """Returns the log level based on the parameter environment variable `LOG_LEVEL`.

    Returns:
        The log level.
    """
    comptime level = get_defined_string["LOG_LEVEL", default="INFO"]()
    if level == "INFO":
        return LogLevel.INFO
    elif level == "WARN":
        return LogLevel.WARN
    elif level == "ERROR":
        return LogLevel.ERROR
    elif level == "DEBUG":
        return LogLevel.DEBUG
    elif level == "FATAL":
        return LogLevel.FATAL
    else:
        return LogLevel.INFO


comptime LOG_LEVEL = get_log_level()
"""Logger level determined by the `LOG_LEVEL` param environment variable.

When building or running the application, you can set `LOG_LEVEL` by providing the the following option:

```bash
mojo build ... -D LOG_LEVEL=DEBUG
# or
mojo ... -D LOG_LEVEL=DEBUG
```
"""


@fieldwise_init
struct Logger[level: Int](ImplicitlyCopyable, Movable):
    comptime STDOUT = FileDescriptor(1)
    comptime STDERR = FileDescriptor(2)

    def _log_message[event_level: Int](self, message: String):
        comptime if Self.level >= event_level:
            comptime if event_level < LogLevel.WARN:
                # Write to stderr if FATAL or ERROR
                print(message, file=Self.STDERR)
            else:
                print(message)

    def info[*Ts: Writable](self, *messages: *Ts):
        var msg = String("\033[36mINFO\033[0m  - ")

        comptime for i in range(messages.__len__()):
            msg.write(messages[i], " ")
        self._log_message[LogLevel.INFO](msg)

    def warn[*Ts: Writable](self, *messages: *Ts):
        var msg = String("\033[33mWARN\033[0m  - ")

        comptime for i in range(messages.__len__()):
            msg.write(messages[i], " ")
        self._log_message[LogLevel.WARN](msg)

    def error[*Ts: Writable](self, *messages: *Ts):
        var msg = String("\033[31mERROR\033[0m - ")

        comptime for i in range(messages.__len__()):
            msg.write(messages[i], " ")
        self._log_message[LogLevel.ERROR](msg)

    def debug[*Ts: Writable](self, *messages: *Ts):
        var msg = String("\033[34mDEBUG\033[0m - ")

        comptime for i in range(messages.__len__()):
            msg.write(messages[i], " ")

        self._log_message[LogLevel.DEBUG](msg)

    def fatal[*Ts: Writable](self, *messages: *Ts):
        var msg = String("\033[35mFATAL\033[0m - ")

        comptime for i in range(messages.__len__()):
            msg.write(messages[i], " ")
        self._log_message[LogLevel.FATAL](msg)


comptime logger = Logger[LOG_LEVEL]()
