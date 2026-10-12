from mojelly.http.query import QueryParams, parse_query_string

comptime _SP: UInt8 = 32
comptime _TAB: UInt8 = 9
comptime _CR: UInt8 = 13
comptime _COLON: UInt8 = 58
comptime _SEMI: UInt8 = 59
comptime _EQ: UInt8 = 61


def _slice_to_string(bytes: Span[UInt8, _], start: Int, end: Int) -> String:
    var s = start
    var e = end
    while s < e and (bytes[s] == _SP or bytes[s] == _TAB):
        s += 1
    while e > s and (bytes[e - 1] == _SP or bytes[e - 1] == _TAB):
        e -= 1
    if s >= e:
        return String()
    return String(StringSlice(unsafe_from_utf8=bytes[s:e]))


def parse_header_block(raw: String, mut headers: Dict[String, String]):
    var bytes = raw.as_bytes()
    var n = len(bytes)
    var i = 0
    while i < n:
        var line_end = i
        var colon = -1
        while line_end < n and bytes[line_end] != _CR:
            if colon == -1 and bytes[line_end] == _COLON:
                colon = line_end
            line_end += 1
        if colon != -1:
            headers[_slice_to_string(bytes, i, colon)] = _slice_to_string(
                bytes, colon + 1, line_end
            )
        i = line_end + 2


def parse_cookie_header(raw: String, mut cookies: Dict[String, String]):
    var bytes = raw.as_bytes()
    var n = len(bytes)
    var i = 0
    while i < n:
        var pair_end = i
        var eq = -1
        while pair_end < n and bytes[pair_end] != _SEMI:
            if eq == -1 and bytes[pair_end] == _EQ:
                eq = pair_end
            pair_end += 1
        if eq != -1:
            cookies[_slice_to_string(bytes, i, eq)] = _slice_to_string(
                bytes, eq + 1, pair_end
            )
        i = pair_end + 1


def _equal_ignore_case(a: String, b: String) -> Bool:
    var x = a.as_bytes()
    var y = b.as_bytes()
    if len(x) != len(y):
        return False
    for i in range(len(x)):
        var c = x[i]
        var d = y[i]
        if c >= 65 and c <= 90:
            c += 32
        if d >= 65 and d <= 90:
            d += 32
        if c != d:
            return False
    return True


struct HTTPRequest:
    var url: String
    var path: String
    var query_string: String
    var method: String
    var body: String

    var _headers_raw: String

    var _headers_cache: Optional[Dict[String, String]]
    var _cookies_cache: Optional[Dict[String, String]]
    var query: QueryParams
    var params: Dict[String, String]

    def __init__(
        out self,
        url: String = "",
        method: String = "GET",
        path: String = "",
        query_string: String = "",
    ):
        self.url = url

        if path == "" and url != "":
            var q_pos = url.find("?")
            if q_pos != -1:
                self.path = String(url[byte=0:q_pos])
                self.query_string = String(
                    url[byte = q_pos + 1 : len(url.as_bytes())]
                )
            else:
                self.path = url
                self.query_string = ""
        else:
            self.path = path
            self.query_string = query_string

        self.query = QueryParams(self.query_string^)
        self.method = method
        self.body = ""
        self._headers_raw = ""
        self._headers_cache = None
        self._cookies_cache = None
        self.params = Dict[String, String]()

    # ---- Headers (lazy) ----

    def get_header(mut self, name: String) -> String:
        self._ensure_headers()
        ref h = self._headers_cache.value()
        var exact = h.get(name)
        if exact:
            return exact.value()
        for key in h.keys():
            if _equal_ignore_case(key, name):
                return h.get(key, "")
        return ""

    def _ensure_headers(mut self):
        if not self._headers_cache:
            var d = Dict[String, String]()
            parse_header_block(self._headers_raw, d)
            self._headers_cache = d^

    # ---- Cookies (lazy, read via Cookie header) ----

    def get_cookie(mut self, name: String) -> String:
        self._ensure_cookies()
        ref d = self._cookies_cache.value()
        return d.get(name, "")

    def has_cookie(mut self, name: String) -> Bool:
        self._ensure_cookies()
        ref d = self._cookies_cache.value()
        return name in d

    def _ensure_cookies(mut self):
        if not self._cookies_cache:
            var cookie_header = self.get_header("Cookie")
            var d = Dict[String, String]()
            if cookie_header != "":
                parse_cookie_header(cookie_header, d)
            self._cookies_cache = d^

    # ---- Query (lazy via QueryParams) ----

    def get_query(mut self, name: String, default: String = "") -> String:
        return self.query.get(name, default)

    def get_query_int(mut self, name: String, default: Int = 0) -> Int:
        return self.query.get_int(name, default)

    def get_query_bool(mut self, name: String, default: Bool = False) -> Bool:
        return self.query.get_bool(name, default)

    def has_query(mut self, name: String) -> Bool:
        return self.query.has(name)

    # ---- Path params (no lazy — the router fills them only on match) ----

    def get_param(self, name: String) -> String:
        return self.params.get(name, "")

    def has_param(self, name: String) -> Bool:
        return name in self.params
