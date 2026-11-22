"""Compute the RFC 6455 accept proof from the client key and fixed GUID.

Base64 wraps the raw 20-byte SHA-1 digest. Interpreting that digest as text
would change arbitrary bytes and break the handshake. The proof validates
the protocol exchange; it does not authenticate a user or encrypt traffic.
"""

# This code is taken from a publicly available repository distributed under the terms of the MIT license:
# https://github.com/msaelices/mojo-websockets/blob/main/LICENSE
from std.base64 import b64encode
from mojelly.websockets.aliases import MAGIC_CONSTANT
from mojelly.websockets.utils.sha1 import sha1_digest_string


def ws_accept_key(key: String) raises -> String:
    # Pass the binary SHA-1 digest to base64 without converting it to UTF-8
    var digest = sha1_digest_string(key + MAGIC_CONSTANT)
    return b64encode(digest[:])
