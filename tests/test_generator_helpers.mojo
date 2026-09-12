from generator import (
    strip_source_comment,
    parenthesis_balance,
    split_top_level_arguments,
    extract_argument_type,
    is_http_request_type,
    generated_dto_wrapper_name,
    generate_dto_wrappers_code,
    generate_routes_code,
    extract_handlers,
    extract_handler_dtos,
)
from std.testing import assert_equal, assert_true, assert_false


def test_strip_comments() raises:
    assert_equal(
        strip_source_comment("var a = 10 # this is a comment"), "var a = 10 "
    )
    assert_equal(strip_source_comment("var b = 20"), "var b = 20")
    assert_equal(
        strip_source_comment('var str = "#not_comment" # comment'),
        'var str = "#not_comment" ',
    )


def test_parenthesis_balance() raises:
    assert_equal(parenthesis_balance("(a + b)"), 0)
    assert_equal(parenthesis_balance("((a + b) * (c + d))"), 0)
    assert_equal(parenthesis_balance("((a + b)"), 1)
    assert_equal(parenthesis_balance("(a + b))"), -1)
    assert_equal(parenthesis_balance('(")" + "(")'), 0)


def test_split_arguments() raises:
    var args = split_top_level_arguments("req: HTTPRequest, dto: UserDTO")
    assert_equal(len(args), 2)
    assert_equal(args[0], "req: HTTPRequest")
    assert_equal(args[1], "dto: UserDTO")

    var complex_args = split_top_level_arguments(
        "a: List[Int, Float], b: Dict[String, Int]"
    )
    assert_equal(len(complex_args), 2)
    assert_equal(complex_args[0], "a: List[Int, Float]")
    assert_equal(complex_args[1], "b: Dict[String, Int]")


def test_type_extraction() raises:
    assert_equal(extract_argument_type("req: HTTPRequest"), "HTTPRequest")
    assert_equal(extract_argument_type("dto: UserDTO = UserDTO()"), "UserDTO")
    assert_equal(extract_argument_type("x"), "")

    assert_true(is_http_request_type("HTTPRequest"))
    assert_true(is_http_request_type("mojelly.http.request.HTTPRequest"))
    assert_false(is_http_request_type("UserDTO"))
    assert_false(is_http_request_type("CustomHTTPRequest"))


def test_wrapper_name_and_generation() raises:
    assert_equal(
        generated_dto_wrapper_name("submit_user"), "__mojelly_dto_submit_user"
    )
    assert_equal(
        generated_dto_wrapper_name("handle.user!"), "__mojelly_dto_handle_user_"
    )

    var routes = Dict[String, String]()
    routes["POST:/user"] = "user_handler"

    var handler_dtos = Dict[String, String]()
    handler_dtos["user_handler"] = "UserDTO"

    var wrapper_code = generate_dto_wrappers_code(routes, handler_dtos)
    assert_true(
        "def __mojelly_dto_user_handler(req: HTTPRequest) -> HTTPResponse:"
        in wrapper_code
    )
    assert_true("try_deserialize[UserDTO]" in wrapper_code)

    var routes_code = generate_routes_code(routes, handler_dtos)
    assert_true(
        'router_ptr[].add("POST", "/user", __mojelly_dto_user_handler)'
        in routes_code
    )


def test_extract_handlers_and_dtos() raises:
    var sample_code = """
def test_handler(req: HTTPRequest, dto: UserDTO) -> HTTPResponse:
    return HTTPResponse(200, "ok")

def plain_handler(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(200, "plain")

def main():
    var router = RouterHandlers()
    router.get("/plain", plain_handler)
    router.post("/test", test_handler)
"""
    var routes = extract_handlers(sample_code)
    assert_equal(routes.get("GET:/plain", ""), "plain_handler")
    assert_equal(routes.get("POST:/test", ""), "test_handler")

    var dtos = extract_handler_dtos(sample_code)
    assert_equal(dtos.get("test_handler", ""), "UserDTO")
    assert_equal(dtos.get("plain_handler", ""), "")


def main() raises:
    print("Running generator helper tests...")
    test_strip_comments()
    test_parenthesis_balance()
    test_split_arguments()
    test_type_extraction()
    test_wrapper_name_and_generation()
    test_extract_handlers_and_dtos()
    print("✅ All generator helper tests passed!")
