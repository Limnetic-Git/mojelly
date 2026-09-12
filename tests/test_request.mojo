from mojelly.http.request import HTTPRequest
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


def main() raises:
    print("Running HTTPRequest tests...")
    test_default_request()
    test_request_url_without_query()
    test_request_url_with_query()
    test_request_explicit_path_and_query()
    test_request_headers_and_body()
    print("✅ All HTTPRequest tests passed!")
