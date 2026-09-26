from mojelly.http.request import HTTPRequest
from mojelly.http.response import HTTPResponse


comptime Handler = def(HTTPRequest) thin -> HTTPResponse

def match_path(mask: String, path: String) -> Optional[Dict[String, String]]:
    var mask_parts = mask.split("/") # NOTE: i dont like split, its slow, so
    var path_parts = path.split("/") # its better to use char-by-char comparison

    if len(mask_parts) != len(path_parts):
        return None

    var result = Dict[String, String]()

    for i in range(len(mask_parts)):
        var mask_part = String(mask_parts[i])
        var path_part = String(path_parts[i])

        if mask_part.startswith(":"):
            var var_name = String(mask_part[byte=1:])
            if var_name == "":
                return None
            result[var_name] = path_part
        else:
            if mask_part != path_part:
                return None

    return Optional[Dict[String, String]](result^)


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

    def handle(self, mut request: HTTPRequest) -> HTTPResponse:
        var exact_key = request.method + ":" + request.url
        var exact = self.handlers.get(exact_key)
        if exact:
            return exact.value()(request)

        for entry in self.handlers.items():
            var key = entry.key

            var colon = key.find(":")
            var route_method = String(key[byte=0:colon])
            var route_path = String(key[byte=colon+1:len(key.as_bytes())])

            if route_method != request.method:
                continue

            if ":" not in route_path:
                continue

            var params_opt = match_path(route_path, request.url)
            if params_opt:
                request.params = params_opt.take()
                var handler = self.handlers.get(key)
                if handler:
                    return handler.value()(request)

        return HTTPResponse(404, "Not Found")
