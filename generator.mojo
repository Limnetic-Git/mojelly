#This script is generating final code of your product with Mojelly 🍇
#Final code is in build directory

from std.os import mkdir
from std.memory.alloc import alloc, dealloc, Layout

comptime USE_MULTITHREAD: Bool = True # U can turn it off, but its not recommended =)

def read_user_file(path: String) -> Optional[String]:
    try:
        var file = open(path, "r")
        var content = file.read()
        file.close()
        return Optional[String](content)
    except e:
        print("❌ Error reading file:", path)
        print("   ", e)
        return None

def write_generated_file(path: String, content: String) -> Bool:
    try:
        var file = open(path, "w")
        file.write(content)
        file.close()
        print("✅ Generated:", path)
        return True
    except:
        return False

def span_to_string(span: StringSpan) raises -> String:
    var result = String()
    var bytes = span.as_bytes()
    for i in range(len(bytes)):
        result += chr(Int(bytes[i]))
    return result

def bytes_to_string(bytes_arr: Span[UInt8, _]) raises -> String:
    var result = String()
    for i in range(len(bytes_arr)):
        var b = bytes_arr[i]
        result += chr(Int(b))
    return result

def substring_before(s: String, pos: Int) raises -> String:
    var result = String()
    var bytes = s.as_bytes()
    for i in range(pos):
        if i < len(bytes):
            result += chr(Int(bytes[i]))
    return result

def safe_strip(s: String) raises -> String:
    var trimmed = s.strip()
    return span_to_string(trimmed)

struct SourceQuoteState:
    var quote: UInt8
    var escaped: Bool

    def __init__(out self):
        self.quote = 0
        self.escaped = False

    def consume(mut self, byte: UInt8) -> Bool:
        if self.quote == 0:
            return False
        if self.escaped:
            self.escaped = False
        elif byte == 92:
            self.escaped = True
        elif byte == self.quote:
            self.quote = 0
        return True

def quote_markers() -> Dict[UInt8, UInt8]:
    var markers = Dict[UInt8, UInt8]()
    markers[34] = 34
    markers[39] = 39
    return markers^

def delimiter_deltas(opening: UInt8, closing: UInt8) -> Dict[UInt8, Int]:
    var deltas = Dict[UInt8, Int]()
    deltas[opening] = 1
    deltas[closing] = -1
    return deltas^

def substring_range(s: String, start: Int, end: Int) raises -> String:
    var result = String()
    var bytes = s.as_bytes()
    var i = start
    while i < end and i < len(bytes):
        if i >= 0:
            result += chr(Int(bytes[i]))
        i += 1
    return result

def strip_source_comment(line: String) raises -> String:
    var bytes = line.as_bytes()
    var quotes = quote_markers()
    var quote_state = SourceQuoteState()

    for i in range(len(bytes)):
        var b = bytes[i]
        if quote_state.consume(b):
            continue
        var opening_quote = quotes.get(b, 0)
        if opening_quote != 0:
            quote_state.quote = opening_quote
        elif b == 35:
            return substring_range(line, 0, i)

    return line

def parenthesis_balance(s: String) -> Int:
    var bytes = s.as_bytes()
    var balance = 0
    var quotes = quote_markers()
    var parentheses = delimiter_deltas(40, 41)
    var quote_state = SourceQuoteState()

    for i in range(len(bytes)):
        var b = bytes[i]
        if quote_state.consume(b):
            continue
        var opening_quote = quotes.get(b, 0)
        if opening_quote != 0:
            quote_state.quote = opening_quote
            continue

        balance += parentheses.get(b, 0)

    return balance

def split_top_level_arguments(arguments: String) raises -> List[String]:
    var result = List[String]()
    var current = String()
    var round_depth = 0
    var square_depth = 0
    var curly_depth = 0
    var bytes = arguments.as_bytes()
    var quotes = quote_markers()
    var parentheses = delimiter_deltas(40, 41)
    var square_brackets = delimiter_deltas(91, 93)
    var curly_brackets = delimiter_deltas(123, 125)
    var quote_state = SourceQuoteState()

    for i in range(len(bytes)):
        var b = bytes[i]
        if quote_state.consume(b):
            current += chr(Int(b))
            continue

        var opening_quote = quotes.get(b, 0)
        if opening_quote != 0:
            quote_state.quote = opening_quote
            current += chr(Int(b))
            continue

        round_depth += parentheses.get(b, 0)
        square_depth += square_brackets.get(b, 0)
        curly_depth += curly_brackets.get(b, 0)

        if b == 44 and round_depth == 0 and square_depth == 0 and curly_depth == 0:
            result.append(safe_strip(current))
            current = String()
        else:
            current += chr(Int(b))

    if current != "" or len(result) > 0:
        result.append(safe_strip(current))

    return result^

def find_top_level_byte(s: String, target: UInt8) -> Int:
    var bytes = s.as_bytes()
    var round_depth = 0
    var square_depth = 0
    var curly_depth = 0
    var quotes = quote_markers()
    var parentheses = delimiter_deltas(40, 41)
    var square_brackets = delimiter_deltas(91, 93)
    var curly_brackets = delimiter_deltas(123, 125)
    var quote_state = SourceQuoteState()

    for i in range(len(bytes)):
        var b = bytes[i]
        if quote_state.consume(b):
            continue

        var opening_quote = quotes.get(b, 0)
        if opening_quote != 0:
            quote_state.quote = opening_quote
            continue

        round_depth += parentheses.get(b, 0)
        square_depth += square_brackets.get(b, 0)
        curly_depth += curly_brackets.get(b, 0)

        if b == target and round_depth == 0 and square_depth == 0 and curly_depth == 0:
            return i

    return -1

def extract_argument_type(argument: String) raises -> String:
    var colon = find_top_level_byte(argument, 58)
    if colon == -1:
        return ""

    var type_expression = substring_range(
        argument, colon + 1, len(argument.as_bytes())
    )
    var equals = find_top_level_byte(type_expression, 61)
    if equals != -1:
        type_expression = substring_range(type_expression, 0, equals)

    return safe_strip(type_expression)

def is_http_request_type(type_name: String) -> Bool:
    if type_name == "HTTPRequest":
        return True

    var position = type_name.rfind("HTTPRequest")
    if position <= 0:
        return False

    var bytes = type_name.as_bytes()
    return position + 11 == len(bytes) and bytes[position - 1] == 46

def extract_handler_dtos(user_code: String) raises -> Dict[String, String]:
    var handler_dtos = Dict[String, String]()
    var lines = user_code.split("\n")
    var signature = String()
    var collecting = False
    var balance = 0

    for line_span in lines:
        var line = strip_source_comment(String(line_span))
        var trimmed = safe_strip(line)

        if not collecting:
            if not trimmed.startswith("def "):
                continue
            signature = trimmed
            balance = parenthesis_balance(trimmed)
            collecting = True
        else:
            signature += " " + trimmed
            balance += parenthesis_balance(trimmed)

        if "(" not in signature or balance > 0:
            continue

        var name_start = signature.find("def ") + 4
        var open_paren = signature.find("(")
        var close_paren = signature.rfind(")")

        if name_start < open_paren and close_paren > open_paren:
            var handler_name = safe_strip(
                substring_range(signature, name_start, open_paren)
            )
            var generic_start = handler_name.find("[")
            if generic_start != -1:
                handler_name = safe_strip(
                    substring_range(handler_name, 0, generic_start)
                )

            var arguments_text = substring_range(
                signature, open_paren + 1, close_paren
            )
            var arguments = split_top_level_arguments(arguments_text)
            var request_position = -1

            for i in range(len(arguments)):
                var argument_type = extract_argument_type(arguments[i])
                if is_http_request_type(argument_type):
                    request_position = i
                    break

            if request_position != -1:
                var i = request_position + 1
                while i < len(arguments):
                    var dto_type = extract_argument_type(arguments[i])
                    if dto_type != "":
                        handler_dtos[handler_name] = dto_type
                        break
                    i += 1
        signature = String()
        collecting = False
        balance = 0

    return handler_dtos^

def extract_handlers(user_code: String) -> Dict[String, String]:
    var routes = Dict[String, String]()
    var lines = user_code.split("\n")
    var patterns = Dict[String, String]()
    patterns["router.get("] = "GET"
    patterns["router.post("] = "POST"
    patterns["router.put("] = "PUT"
    patterns["router.delete("] = "DELETE"
    patterns["router.patch("] = "PATCH"
    patterns["router.add("] = "GET"

    for line_span in lines:
        var line = String(line_span)
        var trimmed = line.strip()

        if trimmed == "" or trimmed.startswith("#") or trimmed.startswith("//"):
            continue

        var method = ""
        var path = ""
        var handler = ""
        var found = False

        for pattern in patterns.keys():
            if pattern in trimmed:
                method = patterns.get(pattern, "")
                var start = trimmed.find(pattern) + len(pattern.as_bytes())
                var end = trimmed.rfind(")")
                if start != -1 and end != -1 and start < end:
                    var args_str = String()
                    var i = start
                    while i < end:
                        args_str += String(trimmed[byte=i])
                        i += 1

                    var args = args_str.split(",")
                    if len(args) >= 2:
                        var path_span = String(args[0]).strip()
                        var path_bytes = path_span.as_bytes()
                        var clean_path_bytes = List[UInt8]()
                        var in_quotes = False
                        for j in range(len(path_bytes)):
                            var b = path_bytes[j]
                            if b == 34:
                                in_quotes = not in_quotes
                            elif not in_quotes and (b == 32 or b == 9):
                                continue
                            else:
                                clean_path_bytes.append(b)

                        try:
                            var clean_span = Span[UInt8](clean_path_bytes)
                            path = bytes_to_string(clean_span)
                        except:
                            path = ""

                        var handler_span = String(args[1]).strip()
                        var handler_bytes = handler_span.as_bytes()
                        var clean_handler_bytes = List[UInt8]()
                        var paren_pos = -1
                        for j in range(len(handler_bytes)):
                            var b = handler_bytes[j]
                            if b == 40:
                                paren_pos = j
                                break
                            if b != 32 and b != 9:
                                clean_handler_bytes.append(b)

                        if paren_pos == -1:
                            try:
                                var clean_span = Span[UInt8](clean_handler_bytes)
                                handler = bytes_to_string(clean_span)
                            except:
                                handler = ""
                        else:
                            try:
                                var temp_str = bytes_to_string(handler_bytes)
                                handler = substring_before(temp_str, paren_pos)
                                handler = safe_strip(handler)
                            except:
                                handler = ""

                        if path != "" and handler != "":
                            found = True
                            break
                break

        if found and path != "" and handler != "":
            var key = method + ":" + path
            routes[key] = handler

    return routes^

def generated_dto_wrapper_name(handler: String) -> String:
    var result = "__mojelly_dto_"
    var bytes = handler.as_bytes()

    for i in range(len(bytes)):
        var b = bytes[i]
        if (
            (b >= 48 and b <= 57)
            or (b >= 65 and b <= 90)
            or (b >= 97 and b <= 122)
            or b == 95
        ):
            result += chr(Int(b))
        else:
            result += "_"

    return result

def generate_dto_wrappers_code(
    routes: Dict[String, String], handler_dtos: Dict[String, String]
) -> String:
    var code = ""
    var generated = Dict[String, String]()

    for key in routes.keys():
        var handler = routes.get(key, "")
        var dto_type = handler_dtos.get(handler, "")
        if handler == "" or dto_type == "" or generated.get(handler, "") != "":
            continue

        var wrapper = generated_dto_wrapper_name(handler)
        code += "def " + wrapper + "(req: HTTPRequest) -> HTTPResponse:\n"
        code += "    var dto_opt = try_deserialize[" + dto_type + "](req.body)\n"
        code += "    if not dto_opt:\n"
        code += '        return HTTPResponse(400, "Invalid JSON body")\n'
        code += "    var dto = dto_opt.take()\n"
        code += "    return " + handler + "(req, dto^)\n\n"
        generated[handler] = wrapper
    return code

def generate_routes_code(routes: Dict[String, String], handler_dtos: Dict[String, String]) -> String:
    var code = ""
    var keys = List[String]()

    for key in routes.keys():
        keys.append(key)

    for i in range(len(keys)):
        var key = keys[i]
        var parts = key.split(":")
        var method = String(parts[0])
        var path = String(parts[1])
        var handler = routes.get(key, "")
        if handler != "":
            var registered_handler = handler
            if handler_dtos.get(handler, "") != "":
                registered_handler = generated_dto_wrapper_name(handler)
            code += (
                '    router_ptr[].add("'
                + method
                + '", "'
                + path
                + '", '
                + registered_handler
                + ')\n'
            )
    return code

def generate_server(user_file: String) -> Optional[String]:
    var user_code_opt = read_user_file(user_file)
    if user_code_opt is None:
        return None
    var user_code = user_code_opt.value()
    var routes = extract_handlers(user_code)
    var handler_dtos: Dict[String, String]
    try:
        handler_dtos = extract_handler_dtos(user_code)
    except e:
        print("Error parsing handler signatures:")
        print("   ", e)
        return None
    var dto_wrappers_code = generate_dto_wrappers_code(routes, handler_dtos)
    var routes_code = generate_routes_code(routes, handler_dtos)
    var json_import = String()
    if dto_wrappers_code != "":
        json_import = "from emberjson import try_deserialize"
    var main_code_by_mode = Dict[Bool, String]()

    main_code_by_mode[True] = """
def main():
    print("🍇 Mojelly HTTP Server (Multithreaded)")

    var port: Int32 = 8080
    var num_threads: Int32 = 4

    var layout = Layout[RouterHandlers].single()
    var alloc_result = alloc(layout)
    var router_ptr = alloc_result^.unsafe_leak()
    router_ptr[] = RouterHandlers()

ROUTES_PLACEHOLDER

    var router_void = router_ptr.unsafe_bitcast[NoneType]()
    var router_void_fixed = router_void.unsafe_origin_cast[MutUntrackedOrigin]()
    mojelly_set_router(router_void_fixed)

    pthread_create_wrapper(port, router_void_fixed, num_threads)

    print("✅ All", num_threads, "threads started")
    print("🚀 Server listening on port", port)

    while True:
        sleep(1000)
"""
    main_code_by_mode[False] = """
def main():
    print("🍇 Mojelly HTTP Server (Single-threaded)")

    var port: Int32 = 8080
    var router = RouterHandlers()

ROUTES_PLACEHOLDER

    var server = HTTPServer(router^)
    server.listen(port)
    server.run()
"""
    var main_code = main_code_by_mode.get(USE_MULTITHREAD, "")

    var template = """
# ============================================================
# THIS FILE WAS GENERATED BY MOJELLY 🍇!
# For cool guys only 😎
# ============================================================

from mojelly.http.request import HTTPRequest
from mojelly.http.response import HTTPResponse
JSON_IMPORT_PLACEHOLDER
from mojelly.core.router_handlers import RouterHandlers
from std.memory import Pointer
from std.memory.alloc import alloc, dealloc, Layout, ThinAllocation
from std.ffi import external_call
from std.time import sleep

# ============================================================
# USER'S CODE
# ============================================================

from USER_FILE import *

# ============================================================
# DTO HANDLER WRAPPERS
# ============================================================

DTO_WRAPPERS_PLACEHOLDER
# ============================================================
# TYPE'S COMPTIMES
# ============================================================

comptime C_void = Pointer[NoneType, MutUntrackedOrigin]
comptime C_UInt8 = Pointer[UInt8, MutUntrackedOrigin]
comptime C_uv_loop = Pointer[uv_loop_t, MutUntrackedOrigin]
comptime C_uv_tcp = Pointer[uv_tcp_t, MutUntrackedOrigin]

# ============================================================
# STRUCTURES FOR C
# ============================================================

struct uv_loop_t:
    var _data: Pointer[UInt8, MutUntrackedOrigin]

struct uv_tcp_t:
    var _data: Pointer[UInt8, MutUntrackedOrigin]

# ============================================================
# WRAPPERS FOR C-FUNCS
# ============================================================

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

def pthread_create_wrapper(port: Int32, router: C_void, num_threads: Int32) -> None:
    external_call["pthread_create_wrapper", NoneType, Int32, C_void, Int32](port, router, num_threads)

def mojelly_free_response(ptr: C_UInt8) -> None:
    external_call["mojelly_free_response", NoneType, C_UInt8](ptr)

# ============================================================
# UTILS
# ============================================================

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
    var ptr = external_call["malloc", C_UInt8, UInt64](UInt64(len + 1))
    for i in range(len):
        ptr.unsafe_offset(i).unsafe_write(bytes[i])
    ptr.unsafe_offset(len).unsafe_write(0)
    return ptr

# ============================================================
# EXPORTING FUNC
# ============================================================

@export
def mojo_handler(
    router_ptr: Optional[Pointer[RouterHandlers, MutUntrackedOrigin]],
    url_ptr: C_UInt8,
    method_ptr: C_UInt8,
    body_ptr: C_UInt8
) abi("C") -> C_UInt8:

    if not router_ptr:
        var err_response = "HTTP/1.1 500 Internal Server Error\\r\\n\\r\\n"
        return string_to_c_string(err_response)

    var router = router_ptr.value()
    var url = c_string_to_string(url_ptr)
    var method = c_string_to_string(method_ptr)
    var body = c_string_to_string(body_ptr)

    var request = HTTPRequest()
    request.url = url
    request.method = method
    request.body = body
    var router_response = router[].handle(request)

    var body_len = router_response.body.byte_length()
    var http_response = String()
    http_response += "HTTP/1.1 "
    http_response += String(router_response.status)
    http_response += " OK\\r\\n"
    http_response += "Content-Type: " + router_response.content_type + "\\r\\n"
    http_response += "Content-Length: " + String(body_len) + "\\r\\n"
    http_response += "Connection: keep-alive\\r\\n"
    http_response += "\\r\\n"
    http_response += router_response.body

    var result = string_to_c_string(http_response)
    return result

# ============================================================
# HTTPServer
# ============================================================

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

# ============================================================
# MAIN
# ============================================================

""" + main_code + """
"""

    template = template.replace("USER_FILE", user_file.replace(".mojo", "").replace("/", "."))
    template = template.replace("JSON_IMPORT_PLACEHOLDER", json_import)
    template = template.replace("DTO_WRAPPERS_PLACEHOLDER", dto_wrappers_code)
    template = template.replace("ROUTES_PLACEHOLDER", routes_code)
    return Optional[String](template)

def main():
    var modes = Dict[Bool, String]()
    modes[True] = "MULTITHREADED"
    modes[False] = "SINGLE-THREADED"
    var mode = modes.get(USE_MULTITHREAD, "")
    print("🔧 Generating server code...")
    print("   Mode:", mode)

    var user_file = "examples/my_app.mojo"
    var generated_code_opt = generate_server(user_file)

    if generated_code_opt is None:
        print("❌ Generation failed!")
        return

    var generated_code = generated_code_opt.value()

    try:
        mkdir("build")
        print("✅ Created build directory")
    except:
        pass

    var success = write_generated_file("build/app_generated.mojo", generated_code)
    if success:
        print("📦 Run: ./build.sh")
    else:
        print("❌ Build failed!")
