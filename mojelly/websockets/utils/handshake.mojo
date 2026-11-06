# This code is taken from a publicly available repository distributed under the terms of the MIT license:
# https://github.com/msaelices/mojo-websockets/blob/main/LICENSE
from std.base64 import b64encode
from mojelly.websockets.aliases import MAGIC_CONSTANT
from mojelly.websockets.utils.sha1 import sha1_digest_string


def ws_accept_key(key: String) raises -> String:
    # SHA-1 возвращает двоичный digest, который передаётся в base64 без UTF-8-преобразования
    var digest = sha1_digest_string(key + MAGIC_CONSTANT)
    return b64encode(digest[:])
