from mojelly.http.request import HTTPRequest
from mojelly.http.response import HTTPResponse
from mojelly.core.router_handlers import RouterHandlers
from std.ffi import external_call
from std.memory import Pointer
from std.memory.alloc import alloc, dealloc, Layout, ThinAllocation

comptime C_void = Pointer[NoneType, MutUntrackedOrigin]
comptime C_UInt8 = Pointer[UInt8, MutUntrackedOrigin]
comptime C_uv_loop = Pointer[uv_loop_t, MutUntrackedOrigin]
comptime C_uv_tcp = Pointer[uv_tcp_t, MutUntrackedOrigin]
comptime C_http_parser = Pointer[http_parser_t, MutUntrackedOrigin]

struct uv_loop_t:
    var _data: Pointer[UInt8, MutUntrackedOrigin]

struct uv_tcp_t:
    var _data: Pointer[UInt8, MutUntrackedOrigin]

struct uv_buf_t:
    var base: Pointer[UInt8, MutUntrackedOrigin]
    var len: UInt64

struct http_parser_t:
    var _data: Pointer[UInt8, MutUntrackedOrigin]

def uv_loop_create_wrapper() -> C_uv_loop:
    return external_call["uv_loop_create_wrapper", C_uv_loop]()

def uv_loop_destroy_wrapper(loop: C_uv_loop) -> None:
    external_call["uv_loop_destroy_wrapper", NoneType, C_uv_loop](loop)

def uv_tcp_init_wrapper(loop: C_uv_loop, tcp: C_uv_tcp) -> None:
    external_call["uv_tcp_init_wrapper", NoneType, C_uv_loop, C_uv_tcp](loop, tcp)

def uv_tcp_bind_wrapper(tcp: C_uv_tcp, ip: C_UInt8, port: Int32) -> None:
    external_call["uv_tcp_bind_wrapper", NoneType, C_uv_tcp, C_UInt8, Int32](tcp, ip, port)

def uv_listen_wrapper(tcp: C_uv_tcp, backlog: Int32) -> None:
    external_call["uv_listen_wrapper", NoneType, C_uv_tcp, Int32](tcp, backlog)

def uv_run_wrapper(loop: C_uv_loop) -> None:
    external_call["uv_run_wrapper", NoneType, C_uv_loop](loop)

def uv_read_start_wrapper(client: C_uv_tcp) -> None:
    external_call["uv_read_start_wrapper", NoneType, C_uv_tcp](client)

def uv_write_wrapper(client: C_uv_tcp, data: C_UInt8, len: UInt64) -> None:
    external_call["uv_write_wrapper", NoneType, C_uv_tcp, C_UInt8, UInt64](client, data, len)

def uv_close_wrapper(client: C_uv_tcp) -> None:
    external_call["uv_close_wrapper", NoneType, C_uv_tcp](client)

def mojelly_set_router(router: C_void) -> None:
    external_call["mojelly_set_router", NoneType, C_void](router)

def http_parser_create() -> C_http_parser:
    return external_call["http_parser_create", C_http_parser]()

def http_parse(parser: C_http_parser, data: C_UInt8, len: UInt64) -> Int32:
    return external_call["http_parse", Int32, C_http_parser, C_UInt8, UInt64](parser, data, len)

def http_get_url(parser: C_http_parser) -> C_UInt8:
    return external_call["http_get_url", C_UInt8, C_http_parser](parser)

def http_get_method(parser: C_http_parser) -> C_UInt8:
    return external_call["http_get_method", C_UInt8, C_http_parser](parser)

def http_get_body(parser: C_http_parser) -> C_UInt8:
    return external_call["http_get_body", C_UInt8, C_http_parser](parser)

def http_get_body_len(parser: C_http_parser) -> UInt64:
    return external_call["http_get_body_len", UInt64, C_http_parser](parser)

def http_is_complete(parser: C_http_parser) -> Int32:
    return external_call["http_is_complete", Int32, C_http_parser](parser)

def http_parser_free(parser: C_http_parser) -> None:
    external_call["http_parser_free", NoneType, C_http_parser](parser)

def send_http_response(client: C_uv_tcp, status: Int32, body: C_UInt8) -> None:
    external_call["send_http_response", NoneType, C_uv_tcp, Int32, C_UInt8](client, status, body)

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

@export
def mojo_handler(
    router_ptr: Pointer[RouterHandlers, MutUntrackedOrigin],
    url_ptr: C_UInt8,
    method_ptr: C_UInt8,
    body_ptr: C_UInt8
) abi("C") -> C_UInt8:
    var url = c_string_to_string(url_ptr)
    var method = c_string_to_string(method_ptr)
    var body = c_string_to_string(body_ptr)

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

struct HTTPServer:
    var loop: C_uv_loop
    var server: C_uv_tcp
    var router: RouterHandlers
    var is_running: Bool

    def __init__(out self, mut router: RouterHandlers):
        self.loop = uv_loop_create_wrapper()
        var server_layout = Layout[uv_tcp_t].single()
        var server_alloc = alloc(server_layout)
        self.server = server_alloc^.unsafe_leak()

        uv_tcp_init_wrapper(self.loop, self.server)

        self.router = router^
        router = RouterHandlers()

        var router_ptr = Pointer(to=self.router).as_unsafe_any_origin()
        var router_ptr_void = router_ptr.unsafe_bitcast[NoneType]()
        var router_ptr_void_fixed = router_ptr_void.unsafe_origin_cast[MutUntrackedOrigin]()
        mojelly_set_router(router_ptr_void_fixed)

        self.is_running = False

    def __deinit__(deinit self):
        uv_loop_destroy_wrapper(self.loop)
        dealloc(ThinAllocation(unsafe_owned_ptr=self.server).unsafe_with_layout(Layout[uv_tcp_t].single()))

    def listen(mut self, port: Int32, host: String = "0.0.0.0"):
        var ip_cstr = string_to_c_string(host)
        uv_tcp_bind_wrapper(self.server, ip_cstr, port)
        uv_listen_wrapper(self.server, 128)
        self.is_running = True

    def run(self):
        if self.is_running:
            uv_run_wrapper(self.loop)
