from mojelly.http.response import HTTPResponse, get_status_phrase
from std.testing import assert_equal, assert_true


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


def test_cookie_defaults() raises:
    var resp = HTTPResponse()
    resp.set_cookie("session", "abc")
    assert_equal(len(resp.cookies), 1)
    assert_equal(resp.cookies[0], "session=abc; Path=/; HttpOnly; SameSite=Lax")


def test_cookie_attributes() raises:
    var resp = HTTPResponse()
    resp.set_cookie(
        "theme",
        "dark",
        path="/app",
        max_age=3600,
        http_only=False,
        secure=True,
        same_site="Strict",
    )
    assert_equal(
        resp.cookies[0],
        "theme=dark; Path=/app; Max-Age=3600; Secure; SameSite=Strict",
    )


def test_cookie_without_same_site_and_max_age() raises:
    var resp = HTTPResponse()
    resp.set_cookie("a", "1", same_site="")
    # no Max-Age for 0, no SameSite for an empty value
    assert_equal(resp.cookies[0], "a=1; Path=/; HttpOnly")


def test_multiple_cookies_keep_order() raises:
    var resp = HTTPResponse()
    resp.set_cookie("first", "1")
    resp.set_cookie("second", "2")
    resp.set_cookie("third", "3")
    assert_equal(len(resp.cookies), 3)
    assert_true(resp.cookies[0].startswith("first=1;"))
    assert_true(resp.cookies[1].startswith("second=2;"))
    assert_true(resp.cookies[2].startswith("third=3;"))


def test_delete_cookie_appends_empty_value() raises:
    var resp = HTTPResponse()
    resp.delete_cookie("session", path="/x")
    assert_equal(len(resp.cookies), 1)
    assert_true(resp.cookies[0].startswith("session=; Path=/x"))


def test_set_header_overwrites_same_name() raises:
    var resp = HTTPResponse()
    resp.set_header("X-Token", "old")
    resp.set_header("X-Token", "new")
    assert_equal(len(resp.headers), 1)
    assert_equal(resp.headers.get("X-Token", ""), "new")


def test_response_is_independent_per_instance() raises:
    var a = HTTPResponse(200, "a")
    var b = HTTPResponse(500, "b")
    a.set_header("X-A", "1")
    a.set_cookie("c", "1")
    assert_equal(len(b.headers), 0)
    assert_equal(len(b.cookies), 0)
    assert_equal(b.status, 500)


def test_all_status_helpers_default_content_type() raises:
    # every status keeps text/plain unless a setter is called
    var codes = List[Int32]()
    codes.append(200)
    codes.append(404)
    codes.append(500)
    for i in range(len(codes)):
        assert_equal(HTTPResponse(codes[i], "x").content_type, "text/plain")


def main() raises:
    print("Running HTTPResponse tests...")
    test_default_response()
    test_custom_response()
    test_content_type_setters()
    test_response_headers()
    test_status_phrases()
    test_cookie_defaults()
    test_cookie_attributes()
    test_cookie_without_same_site_and_max_age()
    test_multiple_cookies_keep_order()
    test_delete_cookie_appends_empty_value()
    test_set_header_overwrites_same_name()
    test_response_is_independent_per_instance()
    test_all_status_helpers_default_content_type()
    print("✅ All HTTPResponse tests passed!")
