from mojelly.http.request import HTTPRequest
from mojelly.http.response import HTTPResponse


comptime Handler = def(HTTPRequest) thin -> HTTPResponse

comptime SLASH: UInt8 = 47      # '/'
comptime COLON: UInt8 = 58      # ':'
comptime STAR: UInt8 = 42       # '*'

struct Segment:
    var is_param: Bool
    var is_wildcard: Bool
    var name: String

    def __init__(out self, var is_param: Bool, var is_wildcard: Bool, var name: String):
        self.is_param = is_param
        self.is_wildcard = is_wildcard
        self.name = name^


struct CompiledPattern:
    var segments: List[Segment]
    var num_segments: Int
    var has_wildcard: Bool
    var handler: Handler
    var method: String

    def __init__(
        out self,
        var segments: List[Segment],
        handler: Handler,
        var method: String,
    ):
        self.num_segments = len(segments)
        self.has_wildcard = False
        for i in range(self.num_segments):
            if segments[i].is_wildcard:
                self.has_wildcard = True
                break
        self.segments = segments^
        self.handler = handler
        self.method = method^

def split_segments(url: String) -> List[Tuple[Int, Int]]:
    var result = List[Tuple[Int, Int]]()
    var bytes = url.as_bytes()
    var n = len(bytes)
    var i = 0

    while i < n:
        if bytes[i] == SLASH:
            i += 1
            continue
        var start = i
        while i < n and bytes[i] != SLASH:
            i += 1
        result.append((start, i))

    return result^

def compile_pattern(
    path: String,
    handler: Handler,
    method: String,
) -> Optional[CompiledPattern]:
    var segs = List[Segment]()
    var has_dynamic = False
    var bytes = path.as_bytes()
    var n = len(bytes)
    var i = 0

    while i < n:
        if bytes[i] == SLASH:
            i += 1
            continue

        var start = i
        while i < n and bytes[i] != SLASH:
            i += 1

        var seg_len = i - start
        if seg_len == 0:
            continue

        var first = bytes[start]

        if first == COLON:
            has_dynamic = True
            var name = String()
            for k in range(start + 1, i):
                name += chr(Int(bytes[k]))
            segs.append(Segment(is_param=True, is_wildcard=False, name=name^))
        elif first == STAR:
            has_dynamic = True
            var name = String()
            for k in range(start + 1, i):
                name += chr(Int(bytes[k]))
            segs.append(Segment(is_param=True, is_wildcard=True, name=name^))
        else:
            var lit = String()
            for k in range(start, i):
                lit += chr(Int(bytes[k]))
            segs.append(Segment(is_param=False, is_wildcard=False, name=lit^))

    if not has_dynamic:
        return None

    return CompiledPattern(segments=segs^, handler=handler, method=method)

def match_compiled(
    cp: CompiledPattern,
    url: String,
    url_segs: List[Tuple[Int, Int]],
) -> Optional[Dict[String, String]]:
    var bytes = url.as_bytes()
    var total = len(bytes)
    var n = cp.num_segments
    var url_n = len(url_segs)

    if cp.has_wildcard:
        if url_n < n:
            return None
    else:
        if url_n != n:
            return None

    var params = Dict[String, String]()

    for i in range(n):
        ref seg = cp.segments[i]
        var bounds = url_segs[i]
        var s = bounds[0]
        var e = bounds[1]

        if seg.is_wildcard:
            var val = String()
            for k in range(s, total):
                val += chr(Int(bytes[k]))
            params[seg.name] = val^
            break

        if seg.is_param:
            var val = String()
            for k in range(s, e):
                val += chr(Int(bytes[k]))
            params[seg.name] = val^
        else:
            var lit_bytes = seg.name.as_bytes()
            if len(lit_bytes) != (e - s):
                return None
            for k in range(len(lit_bytes)):
                if lit_bytes[k] != bytes[s + k]:
                    return None

    return Optional[Dict[String, String]](params^)

struct RouterHandlers:
    var exact: Dict[String, Dict[String, Handler]]

    var patterns: List[CompiledPattern]

    def __init__(out self):
        self.exact = Dict[String, Dict[String, Handler]]()
        self.patterns = List[CompiledPattern]()

    def _insert_exact(mut self, method: String, path: String, handler: Handler) raises:
        ref bucket = self.exact[method]
        bucket[path] = handler

    def _lookup_exact(self, method: String, url: String) raises -> Optional[Handler]:
        ref bucket = self.exact[method]
        if url in bucket:
            return bucket[url]
        return None

    def add(mut self, var method: String, var path: String, handler: Handler):
        var compiled = compile_pattern(path, handler, method)

        if not compiled:
            if method not in self.exact:
                self.exact[method] = Dict[String, Handler]()
            try:
                self._insert_exact(method, path, handler)
            except:
                pass
            return

        self.patterns.append(compiled.take())

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
        var method = request.method
        var url = request.url

        if method in self.exact:
            try:
                var h = self._lookup_exact(method, url)
                if h:
                    return h.value()(request)
            except:
                pass

        var url_segs = split_segments(url)
        var n = len(url_segs)

        for i in range(len(self.patterns)):
            ref cp = self.patterns[i]
            if cp.method != method:
                continue

            if cp.has_wildcard:
                if n < cp.num_segments:
                    continue
            else:
                if cp.num_segments != n:
                    continue

            var params = match_compiled(cp, url, url_segs)
            if params:
                request.params = params.take()
                return cp.handler(request)

        return HTTPResponse(404, "Not Found")
