from mojelly.http.request import HTTPRequest
from mojelly.http.response import HTTPResponse

comptime Handler = def(HTTPRequest) thin -> HTTPResponse

struct RouterHandlers:
    var handlers: Dict[String, Handler]

    def __init__(out self):
        self.handlers = Dict[String, Handler]()

    def add(mut self, method: String, path: String, handler: Handler):
        var key = method + ":" + path
        self.handlers[key] = handler

    def get(mut self, path: String, handler: Handler):
        self.add("GET", path, handler)

    def post(mut self, path: String, handler: Handler):
        self.add("POST", path, handler)

    def put(mut self, path: String, handler: Handler):
        self.add("PUT", path, handler)

    def delete(mut self, path: String, handler: Handler):
        self.add("DELETE", path, handler)

    def patch(mut self, path: String, handler: Handler):
        self.add("PATCH", path, handler)

    def handle(self, request: HTTPRequest) -> HTTPResponse:
        var key = request.method + ":" + request.url
        var handler = self.handlers.get(key)
        if handler:
            return handler.value()(request)
        return HTTPResponse(404, "Not Found")
