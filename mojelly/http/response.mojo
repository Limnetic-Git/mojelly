struct HTTPResponse:
    var status: Int32
    var body: String
    var content_type: String
    var headers: Dict[String, String]
    var cookies: List[String]

    def __init__(out self, status: Int32 = 200, body: String = ""):
        self.status = status
        self.body = body
        self.content_type = "text/plain"
        self.headers = Dict[String, String]()
        self.cookies = List[String]()

    def set_json(mut self):
        self.content_type = "application/json"

    def set_html(mut self):
        self.content_type = "text/html"

    def set_js(mut self):
        self.content_type = "application/javascript"

    def set_css(mut self):
        self.content_type = "text/css"

    def set_header(mut self, name: String, value: String):
        if _has_crlf(name) or name.find(":") != -1 or name == "":
            return
        self.headers[name] = _strip_crlf(value)

    def set_cookie(
        mut self,
        name: String,
        value: String,
        path: String = "/",
        max_age: Int = 0,
        http_only: Bool = True,
        secure: Bool = False,
        same_site: String = "Lax",
    ):
        if (
            _has_crlf(name)
            or name.find("=") != -1
            or name.find(";") != -1
            or name == ""
        ):
            return
        var cookie = name + "=" + _strip_crlf(value)
        cookie += "; Path=" + _strip_crlf(path)
        if max_age > 0:
            cookie += "; Max-Age=" + String(max_age)
        if http_only:
            cookie += "; HttpOnly"
        if secure:
            cookie += "; Secure"
        if same_site != "":
            cookie += "; SameSite=" + _strip_crlf(same_site)
        self.cookies.append(cookie)

    def delete_cookie(mut self, name: String, path: String = "/"):
        self.set_cookie(name, "", path=path, max_age=0)


def _has_crlf(s: String) -> Bool:
    var bytes = s.as_bytes()
    for i in range(len(bytes)):
        var b = bytes[i]
        if b == 13 or b == 10:  # '\r' or '\n'
            return True
    return False


def _strip_crlf(s: String) -> String:
    var bytes = s.as_bytes()
    var has_crlf = False
    var n = len(bytes)
    for i in range(n):
        var b = bytes[i]
        if b == 13 or b == 10:
            has_crlf = True
            break
    if not has_crlf:
        return s.copy()

    var res = String()
    var chunk_start = 0
    var i = 0
    while i < n:
        var b = bytes[i]
        if b == 13 or b == 10:
            if chunk_start < i:
                res += String(
                    StringSlice(unsafe_from_utf8=bytes[chunk_start:i])
                )
            i += 1
            chunk_start = i
        else:
            i += 1
    if chunk_start < n:
        res += String(StringSlice(unsafe_from_utf8=bytes[chunk_start:n]))
    return res^


def get_status_phrase(status: Int32) -> String:
    if status == 200:
        return "OK"
    elif status == 201:
        return "Created"
    elif status == 202:
        return "Accepted"
    elif status == 204:
        return "No Content"
    elif status == 301:
        return "Moved Permanently"
    elif status == 302:
        return "Found"
    elif status == 304:
        return "Not Modified"
    elif status == 400:
        return "Bad Request"
    elif status == 401:
        return "Unauthorized"
    elif status == 403:
        return "Forbidden"
    elif status == 404:
        return "Not Found"
    elif status == 405:
        return "Method Not Allowed"
    elif status == 500:
        return "Internal Server Error"
    elif status == 502:
        return "Bad Gateway"
    elif status == 503:
        return "Service Unavailable"
    return "OK"
