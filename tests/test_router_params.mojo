from mojelly.core.router_handlers import (
    RouterHandlers,
    compile_pattern,
    split_segments,
)
from mojelly.http.request import HTTPRequest
from mojelly.http.response import HTTPResponse
from std.testing import assert_equal, assert_false, assert_true


def echo_id(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(200, "id=" + req.get_param("id"))


def echo_two(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(
        200, req.get_param("login") + "|" + req.get_param("post_id")
    )


def echo_rest(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(200, "rest=" + req.get_param("path"))


def echo_me(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(200, "exact me")


def echo_first(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(200, "first:" + req.get_param("x"))


def echo_second(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(200, "second:" + req.get_param("y"))


def echo_query_and_param(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(
        200, req.get_param("id") + "/" + req.get_query("page", "none")
    )


def run(router: RouterHandlers, method: String, url: String) -> HTTPResponse:
    var req = HTTPRequest(url=url, method=method)
    return router.handle(req)


def test_split_segments() raises:
    var segs = split_segments("/a/bb/ccc")
    assert_equal(len(segs), 3)
    assert_equal(segs[0][0], 1)
    assert_equal(segs[0][1], 2)
    assert_equal(segs[1][0], 3)
    assert_equal(segs[1][1], 5)
    assert_equal(segs[2][0], 6)
    assert_equal(segs[2][1], 9)

    assert_equal(len(split_segments("")), 0)
    assert_equal(len(split_segments("/")), 0)
    # empty segments (duplicate / trailing slashes) are skipped
    var messy = split_segments("//a//b/")
    assert_equal(len(messy), 2)


def test_compile_pattern() raises:
    var no_handler = echo_id
    # a static path is not a pattern: it belongs to the exact-match table
    assert_false(Bool(compile_pattern("/static/path", no_handler, "GET")))

    var param = compile_pattern("/user/:id", no_handler, "GET")
    assert_true(Bool(param))
    ref p = param.value()
    assert_equal(p.num_segments, 2)
    assert_false(p.has_wildcard)
    assert_false(p.segments[0].is_param)
    assert_equal(p.segments[0].name, "user")
    assert_true(p.segments[1].is_param)
    assert_equal(p.segments[1].name, "id")
    assert_equal(p.method, "GET")

    var wild = compile_pattern("/files/*path", no_handler, "POST")
    assert_true(Bool(wild))
    assert_true(wild.value().has_wildcard)
    assert_true(wild.value().segments[1].is_wildcard)
    assert_equal(wild.value().segments[1].name, "path")


def test_single_param() raises:
    var router = RouterHandlers()
    router.get("/user/:id", echo_id)

    assert_equal(run(router, "GET", "/user/42").body, "id=42")
    assert_equal(run(router, "GET", "/user/alice").body, "id=alice")
    assert_equal(run(router, "GET", "/user/42").status, 200)


def test_multiple_params_and_literals() raises:
    var router = RouterHandlers()
    router.get("/user/:login/posts/:post_id", echo_two)

    var resp = run(router, "GET", "/user/bob/posts/7")
    assert_equal(resp.status, 200)
    assert_equal(resp.body, "bob|7")

    # literal segment in the middle must match exactly
    assert_equal(run(router, "GET", "/user/bob/articles/7").status, 404)


def test_segment_count_must_match() raises:
    var router = RouterHandlers()
    router.get("/user/:id", echo_id)

    assert_equal(run(router, "GET", "/user").status, 404)
    assert_equal(run(router, "GET", "/user/42/extra").status, 404)
    assert_equal(run(router, "GET", "/").status, 404)


def test_method_must_match_on_patterns() raises:
    var router = RouterHandlers()
    router.get("/user/:id", echo_id)

    assert_equal(run(router, "POST", "/user/42").status, 404)
    assert_equal(run(router, "DELETE", "/user/42").status, 404)
    assert_equal(run(router, "GET", "/user/42").status, 200)


def test_same_pattern_different_methods() raises:
    var router = RouterHandlers()
    router.get("/item/:id", echo_id)
    router.post("/item/:id", echo_rest)

    assert_equal(run(router, "GET", "/item/9").body, "id=9")
    # echo_rest reads "path", which this route does not define
    assert_equal(run(router, "POST", "/item/9").body, "rest=")


def test_wildcard() raises:
    var router = RouterHandlers()
    router.get("/files/*path", echo_rest)

    assert_equal(run(router, "GET", "/files/a").body, "rest=a")
    assert_equal(run(router, "GET", "/files/a/b/c.txt").body, "rest=a/b/c.txt")
    # the wildcard needs at least one segment to bind to
    assert_equal(run(router, "GET", "/files").status, 404)


def test_exact_route_beats_pattern() raises:
    var router = RouterHandlers()
    router.get("/user/:id", echo_id)
    router.get("/user/me", echo_me)

    assert_equal(run(router, "GET", "/user/me").body, "exact me")
    assert_equal(run(router, "GET", "/user/other").body, "id=other")


def test_first_matching_pattern_wins() raises:
    var router = RouterHandlers()
    router.get("/a/:x", echo_first)
    router.get("/a/:y", echo_second)

    assert_equal(run(router, "GET", "/a/1").body, "first:1")


def test_pattern_with_query_string() raises:
    var router = RouterHandlers()
    router.get("/user/:id", echo_query_and_param)

    assert_equal(run(router, "GET", "/user/7?page=3").body, "7/3")
    assert_equal(run(router, "GET", "/user/7").body, "7/none")


def test_params_do_not_leak_between_requests() raises:
    var router = RouterHandlers()
    router.get("/user/:id", echo_id)

    assert_equal(run(router, "GET", "/user/1").body, "id=1")
    assert_equal(run(router, "GET", "/user/2").body, "id=2")
    var req = HTTPRequest(url="/user/3", method="GET")
    var resp = router.handle(req)
    assert_equal(resp.body, "id=3")
    assert_true(req.has_param("id"))
    assert_equal(req.get_param("id"), "3")
    assert_false(req.has_param("other"))


def test_unknown_path_is_404_with_body() raises:
    var router = RouterHandlers()
    router.get("/user/:id", echo_id)
    var resp = run(router, "GET", "/nope/nothing")
    assert_equal(resp.status, 404)
    assert_equal(resp.body, "Not Found")


def main() raises:
    print("Running Router params/wildcard tests...")
    test_split_segments()
    test_compile_pattern()
    test_single_param()
    test_multiple_params_and_literals()
    test_segment_count_must_match()
    test_method_must_match_on_patterns()
    test_same_pattern_different_methods()
    test_wildcard()
    test_exact_route_beats_pattern()
    test_first_matching_pattern_wins()
    test_pattern_with_query_string()
    test_params_do_not_leak_between_requests()
    test_unknown_path_is_404_with_body()
    print("✅ All Router params/wildcard tests passed!")
