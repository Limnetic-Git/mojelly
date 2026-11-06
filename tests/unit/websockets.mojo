from std.collections import Optional
from std.memory import Pointer
from std.sys import argv
from std.testing import assert_equal, assert_false, assert_true

from mojelly.websockets.aliases import Bytes
from mojelly.websockets.frames import Close, Frame, OpCode, apply_mask
from mojelly.websockets.http import Header, Headers
from mojelly.websockets.streams import StreamReader
from mojelly.websockets.utils.bytes import (
    b64decode,
    bytes_to_str,
    int_as_bytes,
    int_from_bytes,
    pack,
    str_to_bytes,
    unpack,
)
from mojelly.websockets.utils.handshake import ws_accept_key
from mojelly.websockets.utils.sha1 import Sha1Hash, sha1_string
from mojelly.websockets.utils.string import ByteReader, ByteWriter
from mojelly.websockets.utils.uri import URI


# Фиксированная маска из RFC 6455 исключает зависимость тестов от случайных чисел
def fixed_mask() -> Bytes:
    var result: Bytes = [0x37, 0xFA, 0x21, 0x3D]
    return result^


def parse_wire(data: Bytes, *, masked: Bool = False) raises -> Optional[Frame]:
    var reader = StreamReader()
    reader.feed_data(data)
    return Frame.parse(Pointer(to=reader), mask=masked)


def test_utf8_encodes_exact_bytes() raises:
    var expected: Bytes = [0xD0, 0xAF, 0xF0, 0x9F, 0x8C, 0x8D]
    assert_equal(str_to_bytes("Я🌍"), expected)
    assert_equal(bytes_to_str(expected), "Я🌍")


def test_utf8_preserves_embedded_zero() raises:
    var expected: Bytes = [65, 0, 66]
    assert_equal(str_to_bytes("A\x00B"), expected)
    assert_equal(bytes_to_str(expected), "A\x00B")


def test_utf8_replaces_invalid_sequence() raises:
    var invalid: Bytes = [65, 255, 66]
    assert_equal(bytes_to_str(invalid), "A�B")


def test_integer_byte_order() raises:
    var big: Bytes = [0x12, 0x34, 0x56, 0x78]
    var little: Bytes = [0x78, 0x56, 0x34, 0x12]
    assert_equal(int_as_bytes[DType.uint32, True](0x12345678), big)
    assert_equal(int_as_bytes[DType.uint32, False](0x12345678), little)
    assert_equal(int_from_bytes[DType.uint32, True](big[:]), 0x12345678)
    assert_equal(int_from_bytes[DType.uint32, False](little[:]), 0x12345678)


def test_integer_rejects_wrong_width() raises:
    for size in [0, 1, 3, 5]:
        var failed = False
        var data = Bytes(length=size, fill=0)
        try:
            _ = int_from_bytes[DType.uint32](data[:])
        except:
            failed = True
        assert_true(failed)


def test_pack_matches_network_bytes() raises:
    var expected: Bytes = [1, 255, 0x12, 0x34]
    assert_equal(pack["!BBH"](1, 255, 0x1234), expected)
    var little: Bytes = [0x34, 0x12]
    assert_equal(pack["<H"](0x1234), little)


def test_signed_integers_match_twos_complement() raises:
    var expected: Bytes = [255, 255, 254]
    assert_equal(pack["!bh"](-1, -2), expected)
    var values = unpack("!bh", expected)
    assert_equal(values[0], -1)
    assert_equal(values[1], -2)


def test_pack_rejects_argument_count() raises:
    var failed = False
    try:
        _ = pack["!HH"](1)
    except:
        failed = True
    assert_true(failed)


def test_unpack_rejects_wrong_size() raises:
    for size in [1, 3]:
        var failed = False
        try:
            _ = unpack("!H", Bytes(length=size, fill=0))
        except:
            failed = True
        assert_true(failed)


def test_unpack_rejects_unknown_format() raises:
    var failed = False
    try:
        _ = unpack("!X", Bytes())
    except:
        failed = True
    assert_true(failed)


def test_base64_decodes_binary_and_padding() raises:
    var expected: Bytes = [0, 1, 2, 255]
    assert_equal(b64decode[True]("AAEC/w=="), expected)
    assert_equal(bytes_to_str(b64decode[True]("Zg==")), "f")
    assert_equal(bytes_to_str(b64decode[True]("Zm8=")), "fo")
    assert_equal(bytes_to_str(b64decode[True]("Zm9v")), "foo")
    assert_equal(len(b64decode[True]("")), 0)


def test_base64_rejects_malformed_input() raises:
    for encoded in ["abc", "####", "Z=g=", "Zh==", "Zm9="]:
        var failed = False
        try:
            _ = b64decode[True](encoded)
        except:
            failed = True
        assert_true(failed)


def test_sha1_known_vectors() raises:
    assert_equal(sha1_string(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    assert_equal(sha1_string("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
    assert_equal(
        sha1_string("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
        "84983e441c3bd26ebaae4aa1f95129e5e54670f1",
    )


def test_sha1_incremental_updates() raises:
    var hasher = Sha1Hash()
    hasher.update("a")
    hasher.update("b")
    hasher.update("c")
    assert_equal(hasher.hexdigest(), "a9993e364706816aba3e25717850c26c9cd0d89d")
    # Чтение digest не должно завершать объект или менять накопленное состояние
    assert_equal(hasher.hexdigest(), "a9993e364706816aba3e25717850c26c9cd0d89d")
    hasher.update("d")
    assert_equal(hasher.hexdigest(), "81fe8bfe87576c3ecb22426f8e57847382917acf")


def test_handshake_rfc_accept_key() raises:
    assert_equal(
        ws_accept_key("dGhlIHNhbXBsZSBub25jZQ=="),
        "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
    )


def test_uri_default_ports() raises:
    var plain = URI.parse("ws://example.com")
    var secure = URI.parse("wss://example.com")
    assert_equal(plain.get_hostname(), "example.com")
    assert_equal(plain.get_port(), 80)
    assert_equal(plain.get_path(), "/")
    assert_equal(secure.get_port(), 443)
    assert_true(secure.is_wss())


def test_uri_path_query_and_explicit_port() raises:
    var uri = URI.parse("ws://example.com:9000/путь?q=hello")
    assert_equal(uri.get_hostname(), "example.com")
    assert_equal(uri.get_port(), 9000)
    assert_equal(uri.path, "/путь")
    assert_equal(uri.query_string, "q=hello")
    assert_equal(uri.get_path(), "/путь?q=hello")


def test_uri_credentials_do_not_change_hostname() raises:
    var uri = URI.parse("ws://user:password@example.com:9000/chat")
    assert_equal(uri.get_hostname(), "example.com")
    assert_equal(uri.get_port(), 9000)
    var credentials = uri.get_user_info()
    assert_true(Bool(credentials))
    assert_equal(credentials.value()[0], "user")
    assert_equal(credentials.value()[1], "password")
    var default_port = URI.parse("ws://user:password@example.com/chat")
    assert_equal(default_port.get_hostname(), "example.com")
    assert_equal(default_port.get_port(), 80)
    var colon_password = URI.parse("ws://user:password:part@example.com/chat")
    assert_equal(colon_password.get_user_info().value()[1], "password:part")


def test_stream_partial_read_does_not_consume() raises:
    var reader = StreamReader()
    reader.feed_data(str_to_bytes("ab"))
    assert_false(Bool(reader.read_exact(3)))
    assert_equal(reader.position(), 0)
    reader.feed_data(str_to_bytes("c"))
    var result = reader.read_exact(3)
    assert_true(Bool(result))
    assert_equal(bytes_to_str(result.value()), "abc")
    assert_equal(reader.position(), 3)


def test_stream_line_waits_for_newline() raises:
    var reader = StreamReader()
    reader.feed_data(str_to_bytes("abc"))
    assert_false(Bool(reader.read_line(10)))
    assert_equal(reader.position(), 0)
    reader.feed_data(str_to_bytes("\r\nnext"))
    var line = reader.read_line(10)
    assert_equal(bytes_to_str(line.value()), "abc\r\n")
    assert_equal(reader.position(), 5)


def test_stream_enforces_line_limit() raises:
    var reader = StreamReader()
    reader.feed_data(str_to_bytes("abcd\n"))
    var failed = False
    try:
        _ = reader.read_line(4)
    except:
        failed = True
    assert_true(failed)
    assert_equal(reader.position(), 0)


def test_stream_rejects_data_after_eof() raises:
    var reader = StreamReader()
    reader.feed_eof()
    var failed = False
    try:
        reader.feed_data(str_to_bytes("x"))
    except:
        failed = True
    assert_true(failed)
    assert_true(reader.at_eof())


def test_stream_reports_truncated_eof() raises:
    var reader = StreamReader()
    reader.feed_data(str_to_bytes("ab"))
    reader.feed_eof()
    var failed = False
    try:
        _ = reader.read_exact(3)
    except:
        failed = True
    assert_true(failed)


def test_stream_enforces_limit_after_eof() raises:
    var reader = StreamReader()
    reader.feed_data(str_to_bytes("abcd"))
    reader.feed_eof()
    var failed = False
    try:
        _ = reader.read_to_eof(3)
    except:
        failed = True
    assert_true(failed)


def test_byte_writer_consumes_and_resets() raises:
    var writer = ByteWriter()
    writer.write("Я")
    writer.write_byte(0)
    var expected: Bytes = [0xD0, 0xAF, 0]
    assert_equal(writer.consume(), expected)
    assert_equal(len(writer.consume()), 0)
    writer.write("ok")
    assert_equal(bytes_to_str(writer.consume()), "ok")


def test_byte_reader_lines_and_remaining_data() raises:
    var reader = ByteReader(str_to_bytes("a\r\nb\nc"))
    assert_equal(bytes_to_str(reader.read_line()), "a")
    assert_equal(bytes_to_str(reader.read_line()), "b")
    assert_equal(bytes_to_str(reader.read_bytes()), "c")
    assert_false(reader.available())


def test_headers_normalize_names() raises:
    var headers = Headers()
    headers["Content-Type"] = "text/plain"
    assert_true("CONTENT-TYPE" in headers)
    assert_equal(headers["content-type"], "text/plain")
    headers.remove("CONTENT-TYPE")
    assert_true(headers.empty())


def test_headers_equality_is_symmetric() raises:
    var empty = Headers()
    var populated = Headers(Header("Host", "example.com"))
    assert_false(empty == populated)
    assert_false(populated == empty)
    var same = Headers(Header("HOST", "example.com"))
    assert_true(populated == same)
    assert_true(same == populated)
    same["host"] = "other.example.com"
    assert_false(populated == same)


def test_mask_matches_rfc_vector() raises:
    var expected: Bytes = [0x7F, 0x9F, 0x4D, 0x51, 0x58]
    assert_equal(apply_mask(str_to_bytes("Hello"), fixed_mask()), expected)
    assert_equal(bytes_to_str(apply_mask(expected, fixed_mask())), "Hello")


def test_mask_rejects_wrong_key_length() raises:
    for size in [0, 3, 5]:
        var failed = False
        try:
            _ = apply_mask(str_to_bytes("Hello"), Bytes(length=size, fill=0))
        except:
            failed = True
        assert_true(failed)


def test_frame_serializes_unmasked_text() raises:
    var frame = Frame(OpCode.OP_TEXT, str_to_bytes("Hi"))
    var expected: Bytes = [0x81, 2, 0x48, 0x69]
    assert_equal(frame.serialize(mask=False), expected)


def test_frame_serializes_masked_rfc_vector() raises:
    var frame = Frame(OpCode.OP_TEXT, str_to_bytes("Hello"))
    var expected: Bytes = [
        0x81,
        0x85,
        0x37,
        0xFA,
        0x21,
        0x3D,
        0x7F,
        0x9F,
        0x4D,
        0x51,
        0x58,
    ]
    assert_equal(frame.serialize[fixed_mask](mask=True), expected)


def test_frame_parses_independent_wire_bytes() raises:
    var wire: Bytes = [0x82, 3, 0, 255, 0]
    var result = parse_wire(wire)
    assert_true(Bool(result))
    assert_equal(result.value().opcode, OpCode.OP_BINARY)
    var expected: Bytes = [0, 255, 0]
    assert_equal(result.value().data, expected)
    assert_true(result.value().fin)


def test_frame_length_boundaries() raises:
    for size in [125, 126, 65535, 65536]:
        var frame = Frame(OpCode.OP_BINARY, Bytes(length=size, fill=42))
        var wire = frame.serialize(mask=False)
        assert_equal(Int(wire[0]), 0x82)
        if size == 125:
            assert_equal(Int(wire[1]), 125)
            assert_equal(len(wire), 127)
        elif size == 126:
            var header: Bytes = [0x82, 126, 0, 126]
            assert_equal(Bytes(wire[:4]), header)
        elif size == 65535:
            var header: Bytes = [0x82, 126, 255, 255]
            assert_equal(Bytes(wire[:4]), header)
        else:
            var header: Bytes = [0x82, 127, 0, 0, 0, 0, 0, 1, 0, 0]
            assert_equal(Bytes(wire[:10]), header)


def test_frame_waits_at_every_split_position() raises:
    var wire: Bytes = [
        0x81,
        0x85,
        0x37,
        0xFA,
        0x21,
        0x3D,
        0x7F,
        0x9F,
        0x4D,
        0x51,
        0x58,
    ]
    for split in range(len(wire)):
        var reader = StreamReader()
        reader.feed_data(Bytes(wire[:split]))
        assert_false(Bool(Frame.parse(Pointer(to=reader), mask=True)))
        assert_equal(reader.position(), 0)
        reader.feed_data(Bytes(wire[split:]))
        var result = Frame.parse(Pointer(to=reader), mask=True)
        assert_true(Bool(result))
        assert_equal(bytes_to_str(result.value().data), "Hello")
        assert_equal(reader.position(), len(wire))


def test_frame_rejects_missing_mask() raises:
    var wire: Bytes = [0x81, 0]
    var failed = False
    try:
        _ = parse_wire(wire, masked=True)
    except:
        failed = True
    assert_true(failed)


def test_frame_rejects_reserved_bits_and_opcode() raises:
    for first in [0xC1, 0x83]:
        var wire: Bytes = [Byte(first), 0]
        var failed = False
        try:
            _ = parse_wire(wire)
        except:
            failed = True
        assert_true(failed)


def test_frame_rejects_fragmented_control_frame() raises:
    var wire: Bytes = [0x09, 0]
    var failed = False
    try:
        _ = parse_wire(wire)
    except:
        failed = True
    assert_true(failed)


def test_frame_rejects_nonminimal_length() raises:
    var wire: Bytes = [0x82, 126, 0, 125]
    var failed = False
    try:
        _ = parse_wire(wire)
    except:
        failed = True
    assert_true(failed)


def test_frame_rejects_oversized_payload_header() raises:
    var wire: Bytes = [0x82, 127, 0, 0, 0, 0, 0, 0xA0, 0, 1]
    var failed = False
    try:
        _ = parse_wire(wire)
    except:
        failed = True
    assert_true(failed)


def test_close_matches_wire_format() raises:
    var close = Close(1000, "bye")
    var wire: Bytes = [3, 232, 98, 121, 101]
    assert_equal(close.serialize(), wire)
    var result = Close.parse(wire)
    assert_equal(Int(result.code), 1000)
    assert_equal(result.reason, "bye")


def test_close_accepts_empty_payload() raises:
    var close = Close.parse(Bytes())
    assert_equal(Int(close.code), 1005)
    assert_equal(close.reason, "")


def test_close_rejects_reserved_codes() raises:
    for code in [999, 1004, 1005, 1006, 1015, 2999, 5000]:
        var close = Close(UInt16(code), "")
        var failed = False
        try:
            _ = close.serialize()
        except:
            failed = True
        assert_true(failed)


def test_close_rejects_truncated_payload() raises:
    var wire: Bytes = [3]
    var failed = False
    try:
        _ = Close.parse(wire)
    except:
        failed = True
    assert_true(failed)


def test_close_rejects_invalid_utf8() raises:
    var wire: Bytes = [3, 232, 255]
    var failed = False
    try:
        _ = Close.parse(wire)
    except:
        failed = True
    assert_true(failed)


def test_close_counts_reason_in_utf8_bytes() raises:
    var valid = Close(1000, "Я" * 61)
    assert_equal(len(valid.serialize()), 124)
    var invalid = Close(1000, "Я" * 62)
    var failed = False
    try:
        _ = invalid.serialize()
    except:
        failed = True
    assert_true(failed)


# Реестр позволяет запускать все проверки или одну именованную проверку
comptime UnitTest = def() raises thin -> None


def main() raises:
    var tests: List[Tuple[String, UnitTest]] = [
        ("test_utf8_encodes_exact_bytes", test_utf8_encodes_exact_bytes),
        (
            "test_utf8_preserves_embedded_zero",
            test_utf8_preserves_embedded_zero,
        ),
        (
            "test_utf8_replaces_invalid_sequence",
            test_utf8_replaces_invalid_sequence,
        ),
        ("test_integer_byte_order", test_integer_byte_order),
        ("test_integer_rejects_wrong_width", test_integer_rejects_wrong_width),
        ("test_pack_matches_network_bytes", test_pack_matches_network_bytes),
        (
            "test_signed_integers_match_twos_complement",
            test_signed_integers_match_twos_complement,
        ),
        ("test_pack_rejects_argument_count", test_pack_rejects_argument_count),
        ("test_unpack_rejects_wrong_size", test_unpack_rejects_wrong_size),
        (
            "test_unpack_rejects_unknown_format",
            test_unpack_rejects_unknown_format,
        ),
        (
            "test_base64_decodes_binary_and_padding",
            test_base64_decodes_binary_and_padding,
        ),
        (
            "test_base64_rejects_malformed_input",
            test_base64_rejects_malformed_input,
        ),
        ("test_sha1_known_vectors", test_sha1_known_vectors),
        ("test_sha1_incremental_updates", test_sha1_incremental_updates),
        ("test_handshake_rfc_accept_key", test_handshake_rfc_accept_key),
        ("test_uri_default_ports", test_uri_default_ports),
        (
            "test_uri_path_query_and_explicit_port",
            test_uri_path_query_and_explicit_port,
        ),
        (
            "test_uri_credentials_do_not_change_hostname",
            test_uri_credentials_do_not_change_hostname,
        ),
        (
            "test_stream_partial_read_does_not_consume",
            test_stream_partial_read_does_not_consume,
        ),
        (
            "test_stream_line_waits_for_newline",
            test_stream_line_waits_for_newline,
        ),
        ("test_stream_enforces_line_limit", test_stream_enforces_line_limit),
        (
            "test_stream_rejects_data_after_eof",
            test_stream_rejects_data_after_eof,
        ),
        (
            "test_stream_reports_truncated_eof",
            test_stream_reports_truncated_eof,
        ),
        (
            "test_stream_enforces_limit_after_eof",
            test_stream_enforces_limit_after_eof,
        ),
        (
            "test_byte_writer_consumes_and_resets",
            test_byte_writer_consumes_and_resets,
        ),
        (
            "test_byte_reader_lines_and_remaining_data",
            test_byte_reader_lines_and_remaining_data,
        ),
        ("test_headers_normalize_names", test_headers_normalize_names),
        (
            "test_headers_equality_is_symmetric",
            test_headers_equality_is_symmetric,
        ),
        ("test_mask_matches_rfc_vector", test_mask_matches_rfc_vector),
        (
            "test_mask_rejects_wrong_key_length",
            test_mask_rejects_wrong_key_length,
        ),
        (
            "test_frame_serializes_unmasked_text",
            test_frame_serializes_unmasked_text,
        ),
        (
            "test_frame_serializes_masked_rfc_vector",
            test_frame_serializes_masked_rfc_vector,
        ),
        (
            "test_frame_parses_independent_wire_bytes",
            test_frame_parses_independent_wire_bytes,
        ),
        ("test_frame_length_boundaries", test_frame_length_boundaries),
        (
            "test_frame_waits_at_every_split_position",
            test_frame_waits_at_every_split_position,
        ),
        ("test_frame_rejects_missing_mask", test_frame_rejects_missing_mask),
        (
            "test_frame_rejects_reserved_bits_and_opcode",
            test_frame_rejects_reserved_bits_and_opcode,
        ),
        (
            "test_frame_rejects_fragmented_control_frame",
            test_frame_rejects_fragmented_control_frame,
        ),
        (
            "test_frame_rejects_nonminimal_length",
            test_frame_rejects_nonminimal_length,
        ),
        (
            "test_frame_rejects_oversized_payload_header",
            test_frame_rejects_oversized_payload_header,
        ),
        ("test_close_matches_wire_format", test_close_matches_wire_format),
        ("test_close_accepts_empty_payload", test_close_accepts_empty_payload),
        (
            "test_close_rejects_reserved_codes",
            test_close_rejects_reserved_codes,
        ),
        (
            "test_close_rejects_truncated_payload",
            test_close_rejects_truncated_payload,
        ),
        ("test_close_rejects_invalid_utf8", test_close_rejects_invalid_utf8),
        (
            "test_close_counts_reason_in_utf8_bytes",
            test_close_counts_reason_in_utf8_bytes,
        ),
    ]
    var arguments = argv()
    var selected = arguments[1] if len(arguments) > 1 else String("all")
    var matched = False
    for test_case in tests:
        if selected == "all" or selected == test_case[0]:
            test_case[1]()
            print("ok", test_case[0])
            matched = True
    if not matched:
        raise Error("Unknown unit test: ", selected)
