from mojelly.http.request import HTTPRequest
from mojelly.http.response import HTTPResponse
from mojelly.core.router_handlers import RouterHandlers
from mojelly.core.server import HTTPServer


def home_handler(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(200, "Home Page 🏠")

def about_handler(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(200, "About Page 📖")

def users_handler(req: HTTPRequest) -> HTTPResponse:
    var resp = HTTPResponse(200, '[{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]')
    resp.set_json()
    return resp^

def hello_handler(req: HTTPRequest) -> HTTPResponse:
    var resp = HTTPResponse(200, '{"message":"Hello from Mojelly! 🍇"}')
    resp.set_json()
    return resp^

def main():
    print("🍇 Mojelly HTTP Server")

    var router = RouterHandlers()

    router.add("/", home_handler)
    router.add("/about", about_handler)
    router.add("/api/users", users_handler)
    router.add("/api/hello", hello_handler)

    var server = HTTPServer(router)
    server.listen(8080)
    server.run()
