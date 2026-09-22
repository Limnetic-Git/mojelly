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
        self.headers[name] = value

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
        var cookie = name + "=" + value
        cookie += "; Path=" + path
        if max_age > 0:
            cookie += "; Max-Age=" + String(max_age)
        if http_only:
            cookie += "; HttpOnly"
        if secure:
            cookie += "; Secure"
        if same_site != "":
            cookie += "; SameSite=" + same_site
        self.cookies.append(cookie)

    def delete_cookie(mut self, name: String, path: String = "/"):
        self.set_cookie(name, "", path=path, max_age=0)

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
