from mojelly.http.query import (
    parse_query_string,
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


def main() raises:
    print("Running Query String unit tests...")
    test_empty_query()
    test_single_param()
    test_multiple_params()
    test_valueless_flag_param()
    test_url_decoding()
    test_edge_cases_and_delimiters()
    test_serialize_query_string()
    print("✅ All Query String unit tests passed!")
