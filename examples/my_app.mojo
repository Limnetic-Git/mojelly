from mojelly.http.request import HTTPRequest
from mojelly.http.response import HTTPResponse
from mojelly.core.router_handlers import RouterHandlers
from dto import UserDTO
from test_html_page import test_html_page, test_css


# Hello world plain text response
def hello_world(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(200, "Hello, World")


# JSON response
def json_test(req: HTTPRequest) -> HTTPResponse:
    var resp = HTTPResponse(200, '{"nickname":"Limnetic","age":17}')
    resp.set_json()
    return resp^


# HTML page response
def html_page_test(req: HTTPRequest) -> HTTPResponse:
    var resp = HTTPResponse(200, test_html_page)
    resp.set_html()
    return resp^


# CSS response
def css_test(req: HTTPRequest) -> HTTPResponse:
    var resp = HTTPResponse(200, test_css)
    resp.set_css()
    return resp^


# With DTO validation
def dto_validation_test(req: HTTPRequest, dto: UserDTO) -> HTTPResponse:
    if dto.age >= 18:
        return HTTPResponse(200, dto.nickname + "is adult")
    else:
        return HTTPResponse(200, dto.nickname + "is not adult")


# Echo request header and set response header
def headers_test(req: HTTPRequest) -> HTTPResponse:
    var incoming = req.get_header("X-Test-Request")
    var resp = HTTPResponse(200, "Header received: " + incoming)
    resp.set_header("X-Test-Response", "MojellyOK")
    return resp^


# Echo query string
def query_test(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(
        200, "Path: " + req.path + ", Query: " + req.query_string
    )

# Set cookie
def cookie_set_handler(req: HTTPRequest) -> HTTPResponse:
    var resp = HTTPResponse(200, "Cookies set!\nGo to /cookies/read")
    resp.set_cookie(
        "session",
        "abc123xyz",
        max_age=3600,
        http_only=True,
        same_site="Lax",
    )
    resp.set_cookie(
        "theme",
        "dark",
        max_age=86400,
        http_only=False,
        same_site="Lax",
    )
    return resp^

# Get cookie
def cookie_read_handler(req: HTTPRequest) -> HTTPResponse:
    var session = req.get_cookie("session")
    var theme = req.get_cookie("theme")

    var body = String()
    body += "Cookie values:\n"
    body += "  session = "
    if session == "":
        body += "(not set)"
    else:
        body += session
    body += "\n  theme = "
    if theme == "":
        body += "(not set)"
    else:
        body += theme

    var resp = HTTPResponse(200, body)
    return resp^

# Delete cookie
def cookie_delete_handler(req: HTTPRequest) -> HTTPResponse:
    var resp = HTTPResponse(200, "🗑️ Cookies deleted!")
    resp.delete_cookie("session")
    resp.delete_cookie("theme")
    return resp^

def main():
    var router = RouterHandlers()

    router.get("/", hello_world)
    router.get("/json", json_test)
    router.get("/html", html_page_test)
    router.get("/style.css", css_test)
    router.get("/headers", headers_test)
    router.get("/query", query_test)
    router.post("/user", dto_validation_test)

    router.get("/cookies/set", cookie_set_handler)
    router.get("/cookies/read", cookie_read_handler)
    router.get("/cookies/delete", cookie_delete_handler)

    var server = HTTPServer(router)
    server.listen(8080)
    server.run()
