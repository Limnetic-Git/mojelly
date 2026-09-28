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
    var res = String()
    var i = 0
    var n = len(bytes)
    while i < n:
        var b = bytes[i]
        if b == 43:  # '+' -> ' '
            res += " "
            i += 1
        elif b == 37 and i + 2 < n:  # '%'
            var h1 = hex_char_to_int(bytes[i + 1])
            var h2 = hex_char_to_int(bytes[i + 2])
            if h1 != -1 and h2 != -1:
                res += chr(h1 * 16 + h2)
                i += 3
            else:
                res += chr(Int(b))
                i += 1
        else:
            res += chr(Int(b))
            i += 1
    return res


def url_encode(s: String) -> String:
    var bytes = s.as_bytes()
    var res = String()
    for i in range(len(bytes)):
        var b = bytes[i]
        # unreserved: A-Z, a-z, 0-9, '-', '_', '.', '~'
        if (
            (b >= 65 and b <= 90)
            or (b >= 97 and b <= 122)
            or (b >= 48 and b <= 57)
            or b == 45
            or b == 95
            or b == 46
            or b == 126
        ):
            res += chr(Int(b))
        else:
            var high = Int(b) // 16
            var low = Int(b) % 16
            res += "%" + int_to_hex_char(high) + int_to_hex_char(low)
    return res


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


def query_to_json(params: Dict[String, String]) -> String:
    var res = String("{")
    var first = True
    for key in params.keys():
        if not first:
            res += ","
        first = False
        res += '"' + key + '":'
        var val = params.get(key, "")
        if val == "true" or val == "false":
            res += val
        elif is_numeric(val):
            res += val
        else:
            res += '"' + val + '"'
    res += "}"
    return res


def parse_query_string(qs: String) -> Dict[String, String]:
    var result = Dict[String, String]()
    if qs == "":
        return result^

    for pair_span in qs.split("&"):
        var pair = String(pair_span)
        if pair == "":
            continue
        var eq_pos = pair.find("=")
        if eq_pos != -1:
            var key_raw = String(pair[byte=0:eq_pos])
            var val_raw = String(pair[byte = eq_pos + 1 : len(pair.as_bytes())])
            var key = url_decode(key_raw)
            var val = url_decode(val_raw)
            if key != "":
                result[key] = val
        else:
            var key = url_decode(pair)
            if key != "":
                result[key] = ""
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
    return result


struct QueryParams(Copyable, Movable, Sized):
    var data: Dict[String, String]

    def __init__(out self):
        self.data = Dict[String, String]()

    def __init__(out self, data: Dict[String, String]):
        self.data = data.copy()

    def __init__(out self, qs: String):
        self.data = parse_query_string(qs)

    def __copyinit__(out self, existing: Self):
        self.data = existing.data.copy()

    def __moveinit__(out self, deinit existing: Self):
        self.data = existing.data^

    def get(self, name: String, default: String = "") -> String:
        return self.data.get(name, default)

    def get_int(self, name: String, default: Int = 0) -> Int:
        var val = self.data.get(name, "")
        return parse_int_safe(val, default)

    def get_bool(self, name: String, default: Bool = False) -> Bool:
        var val = self.data.get(name, "")
        if val == "":
            if name in self.data:
                return True
            return default
        return parse_bool_safe(val, default)

    def has(self, name: String) -> Bool:
        return name in self.data

    def __contains__(self, name: String) -> Bool:
        return name in self.data

    def __getitem__(self, name: String) -> String:
        return self.data.get(name, "")

    def __len__(self) -> Int:
        return len(self.data)

    def to_dict(self) -> Dict[String, String]:
        var copy = Dict[String, String]()
        for k in self.data.keys():
            copy[k] = self.data.get(k, "")
        return copy^

    def to_string(self) -> String:
        return serialize_query_string(self.data)

    def to_json(self) -> String:
        return query_to_json(self.data)
