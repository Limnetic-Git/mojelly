from mojelly.http.request import (
    HTTPRequest,
    parse_cookie_header,
    parse_header_block,
)
from std.testing import assert_equal, assert_true


def test_default_request() raises:
    var req = HTTPRequest()
    assert_equal(req.url, "")
    assert_equal(req.method, "GET")
    assert_equal(req.path, "")
    assert_equal(req.query_string, "")
    assert_equal(req.body, "")
    assert_equal(req.get_header("any"), "")


def test_request_url_without_query() raises:
    var req = HTTPRequest(url="/index.html", method="GET")
    assert_equal(req.url, "/index.html")
    assert_equal(req.method, "GET")
    assert_equal(req.path, "/index.html")
    assert_equal(req.query_string, "")


def test_request_url_with_query() raises:
    var req = HTTPRequest(url="/api/users?page=2&limit=50", method="GET")
    assert_equal(req.url, "/api/users?page=2&limit=50")
    assert_equal(req.path, "/api/users")
    assert_equal(req.query_string, "page=2&limit=50")


def test_request_explicit_path_and_query() raises:
    var req = HTTPRequest(
        url="/original",
        method="POST",
        path="/override",
        query_string="flag=true",
    )
    assert_equal(req.url, "/original")
    assert_equal(req.method, "POST")
    assert_equal(req.path, "/override")
    assert_equal(req.query_string, "flag=true")


def test_request_headers_and_body() raises:
    var req = HTTPRequest(url="/submit", method="POST")
    req.body = "hello world"
    req.headers["Content-Type"] = "text/plain"
    req.headers["Authorization"] = "Bearer 12345"

    assert_equal(req.body, "hello world")
    assert_equal(req.get_header("Content-Type"), "text/plain")
    assert_equal(req.get_header("Authorization"), "Bearer 12345")
    assert_equal(req.get_header("X-Missing"), "")


# Reference: the parsing code the generated handler used before the
# single-pass parsers, kept to prove the results are identical.
def _old_parse_headers(headers_str: String, mut headers: Dict[String, String]):
    if headers_str != "":
        for line_span in headers_str.split("\r\n"):
            var line = String(line_span)
            var colon = line.find(":")
            if colon != -1:
                var key = String(line[byte=0:colon]).strip()
                var val = String(
                    line[byte = colon + 1 : len(line.as_bytes())]
                ).strip()
                headers[String(key)] = String(val)


def _old_parse_cookies(
    cookie_header: String, mut cookies: Dict[String, String]
):
    if cookie_header != "":
        for cookie_span in cookie_header.split(";"):
            var cookie = String(cookie_span).strip()
            var eq = cookie.find("=")
            if eq != -1:
                var name = String(cookie[byte=0:eq].strip())
                var value = String(
                    cookie[byte = eq + 1 : len(cookie.as_bytes())].strip()
                )
                cookies[name] = value


def _assert_same(a: Dict[String, String], b: Dict[String, String]) raises:
    assert_equal(len(a), len(b))
    for k in a.keys():
        assert_true(k in b, "missing key: " + k)
        assert_equal(a[k], b[k])


def test_get_header_is_case_insensitive() raises:
    var req = HTTPRequest(url="/", method="GET")
    req.headers["content-type"] = "text/plain"
    req.headers["X-Mixed-Case"] = "v"
    assert_equal(req.get_header("Content-Type"), "text/plain")
    assert_equal(req.get_header("CONTENT-TYPE"), "text/plain")
    assert_equal(req.get_header("content-type"), "text/plain")
    assert_equal(req.get_header("x-mixed-case"), "v")
    assert_equal(req.get_header("X-Mixed-Case"), "v")
    assert_equal(req.get_header("X-Missing"), "")


def test_parse_header_block() raises:
    var h = Dict[String, String]()
    parse_header_block(
        (
            "Host: example.com:8080\r\nAccept:  */* \r\nX-Empty:\r\nno colon"
            " here\r\n"
        ),
        h,
    )
    assert_equal(len(h), 3)
    assert_equal(h["Host"], "example.com:8080")
    assert_equal(h["Accept"], "*/*")
    assert_equal(h["X-Empty"], "")


def test_parse_header_block_empty_and_duplicates() raises:
    var h = Dict[String, String]()
    parse_header_block("", h)
    assert_equal(len(h), 0)
    parse_header_block("A: 1\r\nA: 2", h)
    assert_equal(h["A"], "2")


def test_parse_cookie_header() raises:
    var c = Dict[String, String]()
    parse_cookie_header("session=abc123; theme = dark ;;flag; k=a=b", c)
    assert_equal(len(c), 3)
    assert_equal(c["session"], "abc123")
    assert_equal(c["theme"], "dark")
    assert_equal(c["k"], "a=b")


def test_parsers_match_previous_implementation() raises:
    var header_inputs = List[String]()
    header_inputs.append("")
    header_inputs.append("Host: x\r\n")
    header_inputs.append("Host: x\r\nAccept: */*\r\nUser-Agent: curl/8.0\r\n")
    header_inputs.append("A:1\r\n  B  :   two words  \r\nC: a:b:c\r\n")
    header_inputs.append("garbage\r\nOnly: this\r\n")
    header_inputs.append(": no-name\r\nK:\r\n")
    header_inputs.append("Cookie: s=1; t=2\r\nHost: h")
    for i in range(len(header_inputs)):
        var old = Dict[String, String]()
        var new = Dict[String, String]()
        _old_parse_headers(header_inputs[i], old)
        parse_header_block(header_inputs[i], new)
        _assert_same(old, new)

    var cookie_inputs = List[String]()
    cookie_inputs.append("")
    cookie_inputs.append("a=1")
    cookie_inputs.append("a=1; b=2; c=3")
    cookie_inputs.append("  a = 1 ;b= 2")
    cookie_inputs.append("a=1;;b=2;")
    cookie_inputs.append("novalue; x=y")
    cookie_inputs.append("k=v=w; =empty; z=")
    for i in range(len(cookie_inputs)):
        var old = Dict[String, String]()
        var new = Dict[String, String]()
        _old_parse_cookies(cookie_inputs[i], old)
        parse_cookie_header(cookie_inputs[i], new)
        _assert_same(old, new)


def test_cookie_accessors() raises:
    var req = HTTPRequest(url="/", method="GET")
    req.cookies["session"] = "abc"
    assert_equal(req.get_cookie("session"), "abc")
    assert_equal(req.get_cookie("missing"), "")
    assert_true(req.has_cookie("session"))
    assert_true(not req.has_cookie("missing"))


def test_param_accessors() raises:
    var req = HTTPRequest(url="/", method="GET")
    req.params["id"] = "42"
    assert_equal(req.get_param("id"), "42")
    assert_equal(req.get_param("nope"), "")
    assert_true(req.has_param("id"))
    assert_true(not req.has_param("nope"))


def test_query_accessors() raises:
    var req = HTTPRequest(
        url="/search?q=hello%20world&page=3&debug&on=yes&neg=-4&bad=x1"
    )
    assert_equal(req.path, "/search")
    assert_equal(req.get_query("q"), "hello world")
    assert_equal(req.get_query("missing", "dflt"), "dflt")
    assert_equal(req.get_query_int("page"), 3)
    assert_equal(req.get_query_int("neg"), -4)
    assert_equal(req.get_query_int("bad", 7), 7)
    assert_equal(req.get_query_int("missing", 5), 5)
    assert_true(req.get_query_bool("debug"))  # valueless flag
    assert_true(req.get_query_bool("on"))
    assert_true(not req.get_query_bool("missing"))
    assert_true(req.get_query_bool("missing", True))
    assert_true(req.has_query("q"))
    assert_true(not req.has_query("missing"))


def test_request_without_query_has_empty_query() raises:
    var req = HTTPRequest(url="/plain")
    assert_equal(req.query_string, "")
    assert_equal(len(req.query), 0)
    assert_true(not req.has_query("anything"))


def test_question_mark_without_query() raises:
    var req = HTTPRequest(url="/x?")
    assert_equal(req.path, "/x")
    assert_equal(req.query_string, "")
    assert_equal(len(req.query), 0)


def test_query_keeps_only_first_question_mark_as_separator() raises:
    var req = HTTPRequest(url="/x?a=1?b=2")
    assert_equal(req.path, "/x")
    assert_equal(req.query_string, "a=1?b=2")
    assert_equal(req.get_query("a"), "1?b=2")


def test_get_header_prefers_exact_then_any_case() raises:
    var req = HTTPRequest()
    req.headers["Accept"] = "exact"
    req.headers["accept"] = "lower"
    assert_equal(req.get_header("Accept"), "exact")
    assert_equal(req.get_header("accept"), "lower")
    # no exact match for "ACCEPT": any-case fallback returns one of the two
    assert_true(
        req.get_header("ACCEPT") == "exact"
        or req.get_header("ACCEPT") == "lower"
    )


def test_parse_header_block_trims_spaces_and_tabs() raises:
    var h = Dict[String, String]()
    parse_header_block("A:   padded value   \r\nB:\tTabbed\t", h)
    assert_equal(h["A"], "padded value")
    assert_equal(h["B"], "Tabbed")


def test_parse_cookie_header_edge_cases() raises:
    var c = Dict[String, String]()
    parse_cookie_header("", c)
    assert_equal(len(c), 0)
    parse_cookie_header(";;;", c)
    assert_equal(len(c), 0)
    parse_cookie_header("=value-without-name", c)
    assert_equal(len(c), 1)
    assert_equal(c[""], "value-without-name")
    var d = Dict[String, String]()
    parse_cookie_header("a=1;a=2", d)
    assert_equal(d["a"], "2")  # later duplicate wins


def main() raises:
    print("Running HTTPRequest tests...")
    test_default_request()
    test_request_url_without_query()
    test_request_url_with_query()
    test_request_explicit_path_and_query()
    test_request_headers_and_body()
    test_get_header_is_case_insensitive()
    test_cookie_accessors()
    test_param_accessors()
    test_query_accessors()
    test_request_without_query_has_empty_query()
    test_question_mark_without_query()
    test_query_keeps_only_first_question_mark_as_separator()
    test_get_header_prefers_exact_then_any_case()
    test_parse_header_block_trims_spaces_and_tabs()
    test_parse_cookie_header_edge_cases()
    test_parse_header_block()
    test_parse_header_block_empty_and_duplicates()
    test_parse_cookie_header()
    test_parsers_match_previous_implementation()
    print("✅ All HTTPRequest tests passed!")
