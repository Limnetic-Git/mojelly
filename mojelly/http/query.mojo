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
