from mojelly.http.request import HTTPRequest
from mojelly.http.response import HTTPResponse
from mojelly.core.router_handlers import RouterHandlers
from mojelly.core.server import HTTPServer
from std.memory import Pointer, Layout
from std.ffi import external_call

comptime C_UInt8 = Pointer[UInt8, MutUntrackedOrigin]

def c_string_to_string(ptr: C_UInt8) -> String:
    var result = String()
    var i = 0
    while True:
        var ch = ptr.unsafe_offset(i)[]
        if ch == 0:
            break
        result += chr(Int(ch))
        i += 1
    return result

def string_to_c_string(s: String) -> C_UInt8:
    var bytes = s.as_bytes()
    var len = len(bytes)
    var layout = Layout[UInt8](count=len + 1)
    var allocation = alloc(layout)
    var ptr = allocation^.unsafe_leak()
    for i in range(len):
        ptr.unsafe_offset(i).unsafe_write(bytes[i])
    ptr.unsafe_offset(len).unsafe_write(0)
    return ptr

def home_handler(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(200, "Home Page")

def about_handler(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(200, "About Page 📖")

def users_handler(req: HTTPRequest) -> HTTPResponse:
    var resp = HTTPResponse(200, '[{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]')
    resp.set_json()
    return resp^

def hello_handler(req: HTTPRequest) -> HTTPResponse:
    var resp = HTTPResponse(200, '{"message":"Hello from Mojelly! 🍇"}')
    resp.set_json()
    return resp^

@export
def mojo_handler(
    router_ptr: Pointer[RouterHandlers, MutUntrackedOrigin],
    url_ptr: C_UInt8,
    method_ptr: C_UInt8,
    body_ptr: C_UInt8
) abi("C") -> C_UInt8:
    print("[Mojo] mojo_handler called")

    var url = c_string_to_string(url_ptr)
    var method = c_string_to_string(method_ptr)
    var body = c_string_to_string(body_ptr)

    print("[Mojo] Request:", method, url)

    var request = HTTPRequest()
    request.url = url
    request.method = method
    request.body = body

    var router_response = router_ptr[].handle(request)

    var body_len = router_response.body.byte_length()
    var http_response = String()
    http_response += "HTTP/1.1 "
    http_response += String(router_response.status)
    http_response += " OK\r\n"
    http_response += "Content-Type: text/plain\r\n"
    http_response += "Content-Length: " + String(body_len) + "\r\n"
    http_response += "Connection: close\r\n"
    http_response += "\r\n"
    http_response += router_response.body

    return string_to_c_string(http_response)

def main():
    print("🍇 Mojelly HTTP Server")

    var router = RouterHandlers()
    router.add("/", home_handler)
    router.add("/about", about_handler)
    router.add("/api/users", users_handler)
    router.add("/api/hello", hello_handler)

    var server = HTTPServer(router)
    server.listen(8080)
    server.run()
