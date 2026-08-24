from mojelly.http.request import HTTPRequest
from mojelly.http.response import HTTPResponse
from mojelly.core.router_handlers import RouterHandlers, Handler

def home_handler(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(200, "Home Page")

def about_handler(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(200, "About Page")

def users_handler(req: HTTPRequest) -> HTTPResponse:
    var resp = HTTPResponse(200, '[{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]')
    resp.set_json()
    return resp^

def hello_handler(req: HTTPRequest) -> HTTPResponse:
    var resp = HTTPResponse(200, '{"message":"Hello from Mojelly! 🍇"}')
    resp.set_json()
    return resp^

def main():
    print("🍇 Mojelly 0.1.0!")

    var router = RouterHandlers()

    router.add("/", home_handler)
    router.add("/about", about_handler)
    router.add("/api/users", users_handler)
    router.add("/api/hello", hello_handler)

    var req1 = HTTPRequest("/", "GET")
    var resp1 = router.handle(req1)
    print("📌", req1.url, "->", resp1.body)

    var req2 = HTTPRequest("/api/hello", "GET")
    var resp2 = router.handle(req2)
    print("📌", req2.url, "->", resp2.body)

    var req3 = HTTPRequest("/unknown", "GET")
    var resp3 = router.handle(req3)
    print("📌", req3.url, "->", resp3.body)
