def hex_char_to_int(c: UInt8) -> Int:
    if c >= 48 and c <= 57:  # '0'-'9'
        return Int(c - 48)
    elif c >= 65 and c <= 70:  # 'A'-'F'
        return Int(c - 55)
    elif c >= 97 and c <= 102:  # 'a'-'f'
        return Int(c - 87)
    return -1


def int_to_hex_char(val: Int) -> String:
    if val < 10:
        return chr(48 + val)
    else:
        return chr(65 + val - 10)


def url_decode(s: String) -> String:
    var bytes = s.as_bytes()
    var n = len(bytes)

    var has_escape = False
    for i in range(n):
        var b = bytes[i]
        if b == 37 or b == 43:  # '%' or '+'
            has_escape = True
            break
    if not has_escape:
        return s.copy()

    var res = String()
    var i = 0
    var chunk_start = 0
    while i < n:
        var b = bytes[i]
        if b == 43:  # '+' -> ' '
            if chunk_start < i:
                res += String(
                    StringSlice(unsafe_from_utf8=bytes[chunk_start:i])
                )
            res += " "
            i += 1
            chunk_start = i
        elif b == 37:  # '%'
            if i + 2 < n:
                var h1 = hex_char_to_int(bytes[i + 1])
                var h2 = hex_char_to_int(bytes[i + 2])
                if h1 != -1 and h2 != -1:
                    if chunk_start < i:
                        res += String(
                            StringSlice(unsafe_from_utf8=bytes[chunk_start:i])
                        )
                    res += chr(h1 * 16 + h2)
                    i += 3
                    chunk_start = i
                    continue
            i += 1
        else:
            i += 1

    if chunk_start < n:
        res += String(StringSlice(unsafe_from_utf8=bytes[chunk_start:n]))
    return res^


def url_encode(s: String) -> String:
    var bytes = s.as_bytes()
    var n = len(bytes)
    var all_unreserved = True
    for i in range(n):
        var b = bytes[i]
        var ok = (
            (b >= 65 and b <= 90)
            or (b >= 97 and b <= 122)
            or (b >= 48 and b <= 57)
            or b == 45
            or b == 95
            or b == 46
            or b == 126
        )
        if not ok:
            all_unreserved = False
            break
    if all_unreserved:
        return s.copy()

    var res = String()
    var i = 0
    var chunk_start = 0
    while i < n:
        var b = bytes[i]
        var ok = (
            (b >= 65 and b <= 90)
            or (b >= 97 and b <= 122)
            or (b >= 48 and b <= 57)
            or b == 45
            or b == 95
            or b == 46
            or b == 126
        )
        if ok:
            i += 1
            continue
        if chunk_start < i:
            res += String(StringSlice(unsafe_from_utf8=bytes[chunk_start:i]))
        var high = Int(b) // 16
        var low = Int(b) % 16
        res += "%" + int_to_hex_char(high) + int_to_hex_char(low)
        i += 1
        chunk_start = i

    if chunk_start < n:
        res += String(StringSlice(unsafe_from_utf8=bytes[chunk_start:n]))
    return res^


def parse_int_safe(s: String, default: Int) -> Int:
    if s == "":
        return default
    var bytes = s.as_bytes()
    var start = 0
    var sign = 1
    if bytes[0] == 45:  # '-'
        sign = -1
        start = 1
    elif bytes[0] == 43:  # '+'
        start = 1

    if start >= len(bytes):
        return default

    var val = 0
    for i in range(start, len(bytes)):
        var b = bytes[i]
        if b >= 48 and b <= 57:
            val = val * 10 + Int(b - 48)
        else:
            return default
    return sign * val


def parse_bool_safe(s: String, default: Bool) -> Bool:
    if s == "":
        return default
    var lower = s.lower()
    if lower == "true" or lower == "1" or lower == "yes" or lower == "on":
        return True
    elif lower == "false" or lower == "0" or lower == "no" or lower == "off":
        return False
    return default


def is_numeric(s: String) -> Bool:
    if s == "":
        return False
    var bytes = s.as_bytes()
    var start = 0
    if bytes[0] == 45:  # '-'
        start = 1
    if start >= len(bytes):
        return False
    for i in range(start, len(bytes)):
        if bytes[i] < 48 or bytes[i] > 57:
            return False
    return True


def _json_escape(s: String) -> String:
    var res = String()
    var bytes = s.as_bytes()
    for i in range(len(bytes)):
        var b = bytes[i]
        if b == 34:  # '"'
            res += '\\"'
        elif b == 92:  # '\'
            res += "\\\\"
        elif b == 10:  # '\n'
            res += "\\n"
        elif b == 13:  # '\r'
            res += "\\r"
        elif b == 9:  # '\t'
            res += "\\t"
        else:
            res += chr(Int(b))
    return res^


def query_to_json(params: Dict[String, String]) -> String:
    var res = String("{")
    var first = True
    for key in params.keys():
        if not first:
            res += ","
        first = False
        res += '"' + _json_escape(key) + '":'
        var val = params.get(key, "")
        if val == "true" or val == "false":
            res += val
        elif is_numeric(val):
            res += val
        else:
            res += '"' + _json_escape(val) + '"'
    res += "}"
    return res^


def parse_query_string(qs: String) -> Dict[String, String]:
    var result = Dict[String, String]()
    if qs == "":
        return result^

    var bytes = qs.as_bytes()
    var n = len(bytes)
    var i = 0
    while i < n:
        var pair_end = i
        while pair_end < n and bytes[pair_end] != 38:  # '&'
            pair_end += 1

        if pair_end == i:
            i = pair_end + 1
            continue
        var eq = -1
        var j = i
        while j < pair_end:
            if bytes[j] == 61:  # '='
                eq = j
                break
            j += 1

        if eq != -1:
            var key_raw = String(StringSlice(unsafe_from_utf8=bytes[i:eq]))
            var val_raw = String(
                StringSlice(unsafe_from_utf8=bytes[eq + 1 : pair_end])
            )
            var key = url_decode(key_raw^)
            if key != "":
                result[key] = url_decode(val_raw^)
        else:
            var key_raw = String(
                StringSlice(unsafe_from_utf8=bytes[i:pair_end])
            )
            var key = url_decode(key_raw^)
            if key != "":
                result[key] = ""

        i = pair_end + 1  # skip '&'

    return result^


def serialize_query_string(params: Dict[String, String]) -> String:
    var result = String()
    var first = True
    for key in params.keys():
        if not first:
            result += "&"
        first = False
        var val = params.get(key, "")
        result += url_encode(key) + "=" + url_encode(val)
    return result^


struct QueryParams(Copyable, Movable):
    var _raw: String
    var _cache: Optional[Dict[String, String]]

    def __init__(out self):
        self._raw = ""
        self._cache = None

    def __init__(out self, data: Dict[String, String]):
        self._raw = ""
        self._cache = data.copy()

    def __init__(out self, qs: String):
        self._raw = qs.copy()
        self._cache = None

    def __copyinit__(out self, existing: Self):
        self._raw = existing._raw.copy()
        if existing._cache:
            self._cache = existing._cache.value().copy()
        else:
            self._cache = None

    def __moveinit__(out self, deinit existing: Self):
        self._raw = existing._raw^
        self._cache = existing._cache^

    # ---- Lazy ensure ----

    def _ensure(mut self):
        if not self._cache:
            self._cache = parse_query_string(self._raw)

    # ---- Read access (mut self to trigger the lazy parse) ----

    def get(mut self, name: String, default: String = "") -> String:
        self._ensure()
        return self._cache.value().get(name, default)

    def get_int(mut self, name: String, default: Int = 0) -> Int:
        self._ensure()
        var val = self._cache.value().get(name, "")
        return parse_int_safe(val, default)

    def get_bool(mut self, name: String, default: Bool = False) -> Bool:
        self._ensure()
        var d = self._cache.value()
        if name not in d:
            return default
        var val = d.get(name, "")
        if val == "":
            return True
        return parse_bool_safe(val, default)

    def has(mut self, name: String) -> Bool:
        self._ensure()
        return name in self._cache.value()

    def __contains__(mut self, name: String) -> Bool:
        self._ensure()
        return name in self._cache.value()

    def __getitem__(mut self, name: String) -> String:
        self._ensure()
        return self._cache.value().get(name, "")

    def to_dict(mut self) -> Dict[String, String]:
        self._ensure()
        var copy = Dict[String, String]()
        for k in self._cache.value().keys():
            copy[k] = self._cache.value().get(k, "")
        return copy^

    def to_string(mut self) -> String:
        # If the cache was never built, hand back the raw string (already
        # in canonical query-string form)
        if not self._cache:
            return self._raw.copy()
        return serialize_query_string(self._cache.value())

    def to_json(mut self) -> String:
        self._ensure()
        return query_to_json(self._cache.value())
