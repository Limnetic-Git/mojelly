from mojelly.core.router_builder import RouterBuilder
from std.testing import assert_equal

def test_router_builder() raises:
    var builder = RouterBuilder()
    assert_equal(len(builder.get_paths()), 0)
    assert_equal(len(builder.get_handler_names()), 0)

    builder.get("/home", "home_handler")
    builder.post("/login", "login_handler")
    builder.put("/profile", "profile_update_handler")
    builder.delete("/account", "account_delete_handler")

    var paths = builder.get_paths()
    var handlers = builder.get_handler_names()

    assert_equal(len(paths), 4)
    assert_equal(len(handlers), 4)

    assert_equal(paths[0], "/home")
    assert_equal(handlers[0], "home_handler")

    assert_equal(paths[1], "/login")
    assert_equal(handlers[1], "login_handler")

    assert_equal(paths[2], "/profile")
    assert_equal(handlers[2], "profile_update_handler")

    assert_equal(paths[3], "/account")
    assert_equal(handlers[3], "account_delete_handler")

def main() raises:
    print("Running RouterBuilder tests...")
    test_router_builder()
    print("✅ All RouterBuilder tests passed!")
