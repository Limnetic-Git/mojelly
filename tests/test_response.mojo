from mojelly.http.response import HTTPResponse, get_status_phrase
from std.testing import assert_equal


def test_default_response() raises:
    var resp = HTTPResponse()
    assert_equal(resp.status, 200)
    assert_equal(resp.body, "")
    assert_equal(resp.content_type, "text/plain")
    assert_equal(len(resp.headers), 0)


def test_custom_response() raises:
    var resp = HTTPResponse(404, "Nothing here")
    assert_equal(resp.status, 404)
    assert_equal(resp.body, "Nothing here")
    assert_equal(resp.content_type, "text/plain")


def test_content_type_setters() raises:
    var resp = HTTPResponse()
    resp.set_json()
    assert_equal(resp.content_type, "application/json")

    resp.set_html()
    assert_equal(resp.content_type, "text/html")

    resp.set_js()
    assert_equal(resp.content_type, "application/javascript")

    resp.set_css()
    assert_equal(resp.content_type, "text/css")


def test_response_headers() raises:
    var resp = HTTPResponse(200, "ok")
    resp.set_header("Server", "Mojelly")
    resp.set_header("X-Frame-Options", "DENY")

    assert_equal(resp.headers.get("Server", ""), "Mojelly")
    assert_equal(resp.headers.get("X-Frame-Options", ""), "DENY")
    assert_equal(resp.headers.get("Missing", ""), "")


def test_status_phrases() raises:
    assert_equal(get_status_phrase(200), "OK")
    assert_equal(get_status_phrase(201), "Created")
    assert_equal(get_status_phrase(202), "Accepted")
    assert_equal(get_status_phrase(204), "No Content")
    assert_equal(get_status_phrase(301), "Moved Permanently")
    assert_equal(get_status_phrase(302), "Found")
    assert_equal(get_status_phrase(304), "Not Modified")
    assert_equal(get_status_phrase(400), "Bad Request")
    assert_equal(get_status_phrase(401), "Unauthorized")
    assert_equal(get_status_phrase(403), "Forbidden")
    assert_equal(get_status_phrase(404), "Not Found")
    assert_equal(get_status_phrase(405), "Method Not Allowed")
    assert_equal(get_status_phrase(500), "Internal Server Error")
    assert_equal(get_status_phrase(502), "Bad Gateway")
    assert_equal(get_status_phrase(503), "Service Unavailable")
    assert_equal(get_status_phrase(999), "OK")


def main() raises:
    print("Running HTTPResponse tests...")
    test_default_response()
    test_custom_response()
    test_content_type_setters()
    test_response_headers()
    test_status_phrases()
    print("✅ All HTTPResponse tests passed!")
