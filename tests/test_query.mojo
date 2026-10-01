from mojelly.http.query import (
    QueryParams,
    is_numeric,
    parse_bool_safe,
    parse_int_safe,
    parse_query_string,
    query_to_json,
    serialize_query_string,
    url_decode,
    url_encode,
)
from mojelly.http.request import HTTPRequest
from std.testing import assert_equal, assert_true, assert_false


def test_empty_query() raises:
    var params = parse_query_string("")
    assert_equal(len(params), 0)

    var req = HTTPRequest(url="/items")
    assert_equal(len(req.query), 0)
    assert_false(req.has_query("page"))
    assert_equal(req.get_query("page"), "")
    assert_equal(req.get_query("page", default="1"), "1")


def test_single_param() raises:
    var params = parse_query_string("name=Mojo")
    assert_equal(len(params), 1)
    assert_equal(params.get("name", ""), "Mojo")

    var req = HTTPRequest(url="/greet?name=Mojo")
    assert_true(req.has_query("name"))
    assert_equal(req.get_query("name"), "Mojo")


def test_multiple_params() raises:
    var qs = "category=books&sort=asc&limit=20&page=1"
    var params = parse_query_string(qs)
    assert_equal(len(params), 4)
    assert_equal(params.get("category", ""), "books")
    assert_equal(params.get("sort", ""), "asc")
    assert_equal(params.get("limit", ""), "20")
    assert_equal(params.get("page", ""), "1")

    var req = HTTPRequest(url="/shop?" + qs)
    assert_equal(req.get_query("category"), "books")
    assert_equal(req.get_query("sort"), "asc")
    assert_equal(req.get_query("limit"), "20")
    assert_equal(req.get_query("page"), "1")
    assert_equal(req.get_query("nonexistent", "default_val"), "default_val")


def test_valueless_flag_param() raises:
    # Query parameters without '=' (e.g. ?debug&verbose=true)
    var params = parse_query_string("debug&verbose=true&raw")
    assert_equal(params.get("debug", "not_found"), "")
    assert_equal(params.get("verbose", ""), "true")
    assert_equal(params.get("raw", "not_found"), "")

    var req = HTTPRequest(url="/api?debug&format=json")
    assert_true(req.has_query("debug"))
    assert_equal(req.get_query("debug"), "")
    assert_equal(req.get_query("format"), "json")


def test_url_decoding() raises:
    # '+' -> space, '%20' -> space, '%26' -> '&', '%3D' -> '='
    var raw = "search=hello+world&filter=50%25%20discount&symbols=%26%3D"
    var params = parse_query_string(raw)
    assert_equal(params.get("search", ""), "hello world")
    assert_equal(params.get("filter", ""), "50% discount")
    assert_equal(params.get("symbols", ""), "&=")

    assert_equal(url_decode("hello+world"), "hello world")
    assert_equal(url_decode("a%20b%20c"), "a b c")
    assert_equal(url_decode("%2B"), "+")


def test_edge_cases_and_delimiters() raises:
    # Multiple consecutive '&', leading or trailing '&'
    var params = parse_query_string("&&a=1&&&b=2&")
    assert_equal(len(params), 2)
    assert_equal(params.get("a", ""), "1")
    assert_equal(params.get("b", ""), "2")


def test_serialize_query_string() raises:
    var params = Dict[String, String]()
    params["name"] = "Alice"
    params["age"] = "30"

    var serialized = serialize_query_string(params)
    # The order of keys in Dict might vary, but both keys and values should be present
    assert_true("name=Alice" in serialized)
    assert_true("age=30" in serialized)
    assert_true("&" in serialized)


def test_query_params_typed_getters() raises:
    var req = HTTPRequest(
        url="/search?q=mojo&page=3&limit=50&active=true&debug&invalid_int=abc"
    )
    assert_equal(req.query.get("q"), "mojo")
    assert_equal(req.query.get_int("page", default=1), 3)
    assert_equal(req.query.get_int("limit", default=10), 50)
    assert_equal(req.query.get_int("missing_page", default=1), 1)
    assert_equal(req.query.get_int("invalid_int", default=42), 42)

    assert_true(req.query.get_bool("active"))
    assert_true(req.query.get_bool("debug"))  # Flag without value is True
    assert_false(req.query.get_bool("missing_flag", default=False))

    # Also test shortcuts on req
    assert_equal(req.get_query_int("page"), 3)
    assert_true(req.get_query_bool("active"))


def test_query_params_to_json() raises:
    var req = HTTPRequest(url="/user?nickname=Alice&age=25&active=true")
    var json_str = req.query.to_json()
    assert_true('"nickname":"Alice"' in json_str)
    assert_true('"age":25' in json_str)
    assert_true('"active":true' in json_str)


def test_url_decode_invalid_and_truncated_escapes() raises:
    assert_equal(url_decode("%zz"), "%zz")  # not hex: kept as is
    assert_equal(url_decode("%4"), "%4")  # truncated
    assert_equal(url_decode("100%"), "100%")  # trailing percent
    assert_equal(url_decode("%41%"), "A%")
    assert_equal(url_decode(""), "")


def test_url_decode_plus_and_encoded_plus() raises:
    assert_equal(url_decode("a+b"), "a b")
    assert_equal(url_decode("a%2Bb"), "a+b")
    assert_equal(url_decode("a%20b"), "a b")
    assert_equal(url_decode("%7a%7A"), "zz")  # lowercase hex digits


def test_url_encode_reserved_and_unicode() raises:
    assert_equal(url_encode("abc-_.~XYZ019"), "abc-_.~XYZ019")  # unreserved
    assert_equal(url_encode("a b"), "a%20b")
    assert_equal(url_encode("a/b?c=d&e"), "a%2Fb%3Fc%3Dd%26e")
    assert_equal(url_encode("é"), "%C3%A9")  # multi-byte UTF-8
    assert_equal(url_encode(""), "")


def test_encode_decode_roundtrip() raises:
    var samples = List[String]()
    samples.append("plain")
    samples.append("with space & symbols=/?#")
    samples.append("100% sure + more")  # ASCII only: see issue #36
    for i in range(len(samples)):
        assert_equal(url_decode(url_encode(samples[i])), samples[i])


def test_parse_int_safe_cases() raises:
    assert_equal(parse_int_safe("0", 9), 0)
    assert_equal(parse_int_safe("42", 9), 42)
    assert_equal(parse_int_safe("-5", 9), -5)
    assert_equal(parse_int_safe("+7", 9), 7)
    assert_equal(parse_int_safe("", 9), 9)
    assert_equal(parse_int_safe("-", 9), 9)
    assert_equal(parse_int_safe("+", 9), 9)
    assert_equal(parse_int_safe("12a", 9), 9)
    assert_equal(parse_int_safe("1.5", 9), 9)
    assert_equal(parse_int_safe(" 1", 9), 9)


def test_parse_bool_safe_spellings() raises:
    var truthy = List[String]()
    truthy.append("true")
    truthy.append("TRUE")
    truthy.append("True")
    truthy.append("1")
    truthy.append("yes")
    truthy.append("on")
    for i in range(len(truthy)):
        assert_true(parse_bool_safe(truthy[i], False), truthy[i])
    var falsy = List[String]()
    falsy.append("false")
    falsy.append("FALSE")
    falsy.append("0")
    falsy.append("no")
    falsy.append("off")
    for i in range(len(falsy)):
        assert_true(not parse_bool_safe(falsy[i], True), falsy[i])
    assert_true(parse_bool_safe("maybe", True))  # unknown -> default
    assert_true(not parse_bool_safe("maybe", False))
    assert_true(parse_bool_safe("", True))


def test_is_numeric_cases() raises:
    assert_true(is_numeric("0"))
    assert_true(is_numeric("123"))
    assert_true(is_numeric("-9"))
    assert_true(not is_numeric(""))
    assert_true(not is_numeric("-"))
    assert_true(not is_numeric("5.5"))
    assert_true(not is_numeric("1e3"))
    assert_true(not is_numeric("+1"))
    assert_true(not is_numeric("a1"))


def test_query_to_json_value_types() raises:
    var d = Dict[String, String]()
    d["n"] = "12"
    d["neg"] = "-3"
    d["t"] = "true"
    d["f"] = "false"
    d["s"] = "text"
    d["e"] = ""
    var js = query_to_json(d)
    assert_true('"n":12' in js)
    assert_true('"neg":-3' in js)
    assert_true('"t":true' in js)
    assert_true('"f":false' in js)
    assert_true('"s":"text"' in js)
    assert_true('"e":""' in js)
    assert_true(js.startswith("{") and js.endswith("}"))
    assert_equal(query_to_json(Dict[String, String]()), "{}")


def test_parse_query_string_edge_cases() raises:
    var empty_pairs = parse_query_string("&&a=1&&")
    assert_equal(len(empty_pairs), 1)
    assert_equal(empty_pairs["a"], "1")

    var no_key = parse_query_string("=v&b=2")
    assert_equal(len(no_key), 1)  # an empty key is dropped
    assert_equal(no_key["b"], "2")

    var dup = parse_query_string("a=1&a=2")
    assert_equal(dup["a"], "2")  # last wins

    var eq_in_value = parse_query_string("k=a=b")
    assert_equal(eq_in_value["k"], "a=b")

    var encoded_key = parse_query_string("na%20me=v%26w")
    assert_equal(encoded_key["na me"], "v&w")


def test_query_params_container() raises:
    var q = QueryParams("a=1&flag&name=Bob%20Ray")
    assert_equal(len(q), 3)
    assert_true("a" in q)
    assert_true(q.has("flag"))
    assert_true("zzz" not in q)
    assert_equal(q["name"], "Bob Ray")
    assert_equal(q["zzz"], "")
    assert_true(q.get_bool("flag"))  # valueless flag is True
    assert_equal(q.get_int("a"), 1)

    var copy = q.copy()
    assert_equal(len(copy), 3)
    assert_equal(copy["name"], "Bob Ray")

    var from_dict = Dict[String, String]()
    from_dict["x"] = "1"
    var q2 = QueryParams(from_dict)
    assert_equal(q2["x"], "1")
    assert_equal(len(q2.to_dict()), 1)


def test_query_params_roundtrip_through_string() raises:
    var q = QueryParams("name=Bob%20Ray&city=New%20York")
    var again = QueryParams(q.to_string())
    assert_equal(len(again), 2)
    assert_equal(again["name"], "Bob Ray")
    assert_equal(again["city"], q["city"])


def main() raises:
    print("Running Query String unit tests...")
    test_empty_query()
    test_single_param()
    test_multiple_params()
    test_valueless_flag_param()
    test_url_decoding()
    test_edge_cases_and_delimiters()
    test_serialize_query_string()
    test_query_params_typed_getters()
    test_query_params_to_json()
    test_url_decode_invalid_and_truncated_escapes()
    test_url_decode_plus_and_encoded_plus()
    test_url_encode_reserved_and_unicode()
    test_encode_decode_roundtrip()
    test_parse_int_safe_cases()
    test_parse_bool_safe_spellings()
    test_is_numeric_cases()
    test_query_to_json_value_types()
    test_parse_query_string_edge_cases()
    test_query_params_container()
    test_query_params_roundtrip_through_string()
    print("✅ All Query String unit tests passed!")
