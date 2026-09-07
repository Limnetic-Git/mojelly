from mojelly.http.request import HTTPRequest
from mojelly.http.response import HTTPResponse
from mojelly.core.router_handlers import RouterHandlers
from dto import UserDTO
from test_html_page import test_html_page, test_css

#Hello world plain text response
def hello_world(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(200, "Hello, World")

#JSON response
def json_test(req: HTTPRequest) -> HTTPResponse:
    var resp = HTTPResponse(200, '{"nickname":"Limnetic","age":17}')
    resp.set_json()
    return resp^

#HTML page response
def html_page_test(req: HTTPRequest) -> HTTPResponse:
    var resp = HTTPResponse(200, test_html_page)
    resp.set_html()
    return resp^

#CSS response
def css_test(req: HTTPRequest) -> HTTPResponse:
    var resp = HTTPResponse(200, test_css)
    resp.set_css()
    return resp^

#With DTO validation
def dto_validation_test(req: HTTPRequest, dto: UserDTO) -> HTTPResponse:
    if dto.age >= 18:
        return HTTPResponse(200, dto.nickname + "is adult")
    else:
        return HTTPResponse(200, dto.nickname + "is not adult")

def main():
    var router = RouterHandlers()

    router.get("/", hello_world)
    router.get("/json", json_test)
    router.get("/html", html_page_test)
    router.get("/style.css", css_test)
    router.post("/user", dto_validation_test)

    var server = HTTPServer(router)
    server.listen(8080)
    server.run()
