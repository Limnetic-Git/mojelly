from mojelly.http.request import HTTPRequest
from mojelly.http.response import HTTPResponse
from mojelly.core.router_handlers import RouterHandlers
from std.testing import assert_equal

def handle_get_root(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(200, "root")

def handle_get_items(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(200, "items: " + req.query_string)

def handle_post_items(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(201, "created item: " + req.body)

def handle_put_item(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(200, "updated")

def handle_delete_item(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(204, "")

def handle_patch_item(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(200, "patched")

def test_router_methods() raises:
    var router = RouterHandlers()
    router.get("/", handle_get_root)
    router.get("/items", handle_get_items)
    router.post("/items", handle_post_items)
    router.put("/item", handle_put_item)
    router.delete("/item", handle_delete_item)
    router.patch("/item", handle_patch_item)

    # 1. Exact GET match
    var req1 = HTTPRequest(url="/", method="GET")
    var resp1 = router.handle(req1)
    assert_equal(resp1.status, 200)
    assert_equal(resp1.body, "root")

    # 2. GET match with query parameters
    var req2 = HTTPRequest(url="/items?category=books&limit=5", method="GET")
    var resp2 = router.handle(req2)
    assert_equal(resp2.status, 200)
    assert_equal(resp2.body, "items: category=books&limit=5")

    # 3. POST match
    var req3 = HTTPRequest(url="/items", method="POST")
    req3.body = '{"name":"book"}'
    var resp3 = router.handle(req3)
    assert_equal(resp3.status, 201)
    assert_equal(resp3.body, 'created item: {"name":"book"}')

    # 4. PUT match
    var req4 = HTTPRequest(url="/item", method="PUT")
    var resp4 = router.handle(req4)
    assert_equal(resp4.status, 200)
    assert_equal(resp4.body, "updated")

    # 5. DELETE match
    var req5 = HTTPRequest(url="/item", method="DELETE")
    var resp5 = router.handle(req5)
    assert_equal(resp5.status, 204)

    # 6. PATCH match
    var req6 = HTTPRequest(url="/item", method="PATCH")
    var resp6 = router.handle(req6)
    assert_equal(resp6.status, 200)
    assert_equal(resp6.body, "patched")

    # 7. 404 on missing route
    var req7 = HTTPRequest(url="/nonexistent", method="GET")
    var resp7 = router.handle(req7)
    assert_equal(resp7.status, 404)
    assert_equal(resp7.body, "Not Found")

    # 8. 404 on method mismatch
    var req8 = HTTPRequest(url="/items", method="DELETE")
    var resp8 = router.handle(req8)
    assert_equal(resp8.status, 404)

def main() raises:
    print("Running RouterHandlers tests...")
    test_router_methods()
    print("✅ All RouterHandlers tests passed!")
