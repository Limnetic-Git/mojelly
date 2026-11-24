from mojelly.http.query import QueryParams, parse_query_string
from std.memory import Pointer

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


def parse_header_bytes(
    bytes: Span[UInt8, _], mut headers: Dict[String, String]
):
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


def parse_header_block(raw: String, mut headers: Dict[String, String]):
    parse_header_bytes(raw.as_bytes(), headers)


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


struct FilePart(Copyable, Movable):
    var name: String
    var filename: String
    var content_type: String
    var size: Int
    var path: String

    def __init__(
        out self,
        var name: String = "",
        var filename: String = "",
        var content_type: String = "",
        size: Int = 0,
        var path: String = "",
    ):
        self.name = name^
        self.filename = filename^
        self.content_type = content_type^
        self.size = size
        self.path = path^


struct MultipartData(Copyable, Movable):
    var form: Dict[String, String]
    var files: List[FilePart]

    def __init__(out self):
        self.form = Dict[String, String]()
        self.files = List[FilePart]()


struct HTTPRequest:
    var url: String
    var path: String
    var query_string: String
    var method: String
    var body: String

    var _headers_raw: String
    var _headers_ptr: Optional[Pointer[UInt8, MutUntrackedOrigin]]
    var _headers_len: Int

    var _headers_cache: Optional[Dict[String, String]]
    var _cookies_cache: Optional[Dict[String, String]]
    var query: QueryParams
    var params: Dict[String, String]

    var multipart: Optional[MultipartData]

    def __init__(
        out self,
        url: String = "",
        method: String = "GET",
        path: String = "",
        query_string: String = "",
        headers_raw: String = "",
    ):
        self.url = url

        if path == "" and url != "":
            var q_pos = url.find("?")
            if q_pos != -1:
                self.path = String(url[byte=0:q_pos])
                self.query_string = String(
                    url[byte = q_pos + 1 : len(url.as_bytes())]
                )
                self.query = QueryParams(self.query_string)
            else:
                self.path = url
                self.query_string = ""
                self.query = QueryParams()
        else:
            self.path = path
            self.query_string = query_string
            if query_string != "":
                self.query = QueryParams(query_string)
            else:
                self.query = QueryParams()

        self.method = method
        self.body = ""
        self._headers_raw = headers_raw
        self._headers_ptr = None
        self._headers_len = 0
        self._headers_cache = None
        self._cookies_cache = None
        self.params = Dict[String, String]()
        self.multipart = None

    # ---- Headers (lazy, zero-copy from C arena until first access) ----

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

    def set_header(mut self, name: String, value: String):
        self._ensure_headers()
        self._headers_cache.value()[name] = value

    def get_headers(mut self) -> Dict[String, String]:
        self._ensure_headers()
        return self._headers_cache.value().copy()

    def _ensure_headers(mut self):
        if not self._headers_cache:
            var d = Dict[String, String]()
            if self._headers_ptr and self._headers_len > 0:
                var span = Span[UInt8](
                    unsafe_ptr=self._headers_ptr.value(),
                    length=self._headers_len,
                )
                parse_header_bytes(span, d)
            elif len(self._headers_raw.as_bytes()) > 0:
                parse_header_bytes(self._headers_raw.as_bytes(), d)
            self._headers_cache = d^

    # ---- Cookies (lazy, read via Cookie header) ----

    def get_cookie(mut self, name: String) -> String:
        self._ensure_cookies()
        ref d = self._cookies_cache.value()
        return d.get(name, "")

    def set_cookie(mut self, name: String, value: String):
        self._ensure_cookies()
        self._cookies_cache.value()[name] = value

    def get_cookies(mut self) -> Dict[String, String]:
        self._ensure_cookies()
        return self._cookies_cache.value().copy()

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

    # ---- Path params ----

    def get_param(self, name: String) -> String:
        return self.params.get(name, "")

    def has_param(self, name: String) -> Bool:
        return name in self.params

    # ---- Multipart ----

    def has_multipart(self) -> Bool:
        return self.multipart is not None

    def get_form(self, name: String, default: String = "") -> String:
        if not self.multipart:
            return default
        return self.multipart.value().form.get(name, default)

    def has_form(self, name: String) -> Bool:
        if not self.multipart:
            return False
        return name in self.multipart.value().form

    def get_file(self, name: String) -> Optional[FilePart]:
        if not self.multipart:
            return None
        ref files = self.multipart.value().files
        for i in range(len(files)):
            if files[i].name == name:
                return files[i].copy()
        return None

    def get_files(self) -> List[FilePart]:
        if not self.multipart:
            return List[FilePart]()
        return self.multipart.value().files.copy()

    def file_count(self) -> Int:
        if not self.multipart:
            return 0
        return len(self.multipart.value().files)

    def form_count(self) -> Int:
        if not self.multipart:
            return 0
        return len(self.multipart.value().form)
