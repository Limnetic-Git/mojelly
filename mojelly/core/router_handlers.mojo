from mojelly.http.request import HTTPRequest
from mojelly.http.response import HTTPResponse

comptime Handler = def(HTTPRequest) thin -> HTTPResponse

struct RouterHandlers:
    var handlers: Dict[String, Handler]

    def __init__(out self):
        self.handlers = Dict[String, Handler]()

    def add(mut self, path: String, handler: Handler):
        self.handlers[path] = handler

    def handle(self, request: HTTPRequest) -> HTTPResponse:
        var url = request.url

        var handler = self.handlers.get(url)
        if handler:
            return handler.value()(request)

        return HTTPResponse(404, "Not Found")
