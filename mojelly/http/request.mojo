from mojelly.http.query import QueryParams, parse_query_string


struct HTTPRequest:
    var url: String
    var path: String
    var query_string: String
    var query: QueryParams
    var method: String
    var body: String
    var headers: Dict[String, String]
    var cookies: Dict[String, String]
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

        if self.query_string != "":
            self.query = QueryParams(self.query_string)
        else:
            self.query = QueryParams()

        self.method = method
        self.body = ""
        self.headers = Dict[String, String]()
        self.cookies = Dict[String, String]()
        self.params = Dict[String, String]()

    def get_header(self, name: String) -> String:
        """Header lookup, case-insensitive as HTTP requires. Names are stored
        as the client sent them; the exact spelling is tried first."""
        var exact = self.headers.get(name)
        if exact:
            return exact.value()
        for key in self.headers.keys():
            if _equal_ignore_case(key, name):
                return self.headers.get(key, "")
        return ""

    def get_cookie(self, name: String) -> String:
        return self.cookies.get(name, "")

    def has_cookie(self, name: String) -> Bool:
        return name in self.cookies

    def get_query(self, name: String, default: String = "") -> String:
        return self.query.get(name, default)

    def get_query_int(self, name: String, default: Int = 0) -> Int:
        return self.query.get_int(name, default)

    def get_query_bool(self, name: String, default: Bool = False) -> Bool:
        return self.query.get_bool(name, default)

    def has_query(self, name: String) -> Bool:
        return self.query.has(name)

    def get_param(self, name: String) -> String:
        return self.params.get(name, "")

    def has_param(self, name: String) -> Bool:
        return name in self.params


def _equal_ignore_case(a: String, b: String) -> Bool:
    """ASCII case-insensitive equality without allocating."""
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


comptime _SP: UInt8 = 32
comptime _TAB: UInt8 = 9
comptime _CR: UInt8 = 13
comptime _COLON: UInt8 = 58
comptime _SEMI: UInt8 = 59
comptime _EQ: UInt8 = 61


def _slice_to_string(bytes: Span[UInt8, _], start: Int, end: Int) -> String:
    """Copy bytes[start:end] into a new String, with surrounding spaces and
    tabs removed."""
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
    """Parse "Name: value\r\nName2: value2" into `headers`.

    One pass over the bytes; each header costs two String allocations (name
    and value). Lines without a colon are skipped; values keep any further
    colons. Later duplicates overwrite earlier ones.
    """
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
        i = line_end + 2  # skip "\r\n"


def parse_cookie_header(raw: String, mut cookies: Dict[String, String]):
    """Parse "a=1; b=2" into `cookies`. Pairs without '=' are skipped."""
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
        i = pair_end + 1  # skip ';'
