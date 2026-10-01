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


def test_builder_returns_independent_copies() raises:
    var builder = RouterBuilder()
    builder.get("/a", "handler_a")
    var paths = builder.get_paths()
    paths.append("/mutated")
    assert_equal(len(builder.get_paths()), 1)
    assert_equal(len(builder.get_handler_names()), 1)


def test_builder_keeps_registration_order_and_duplicates() raises:
    var builder = RouterBuilder()
    builder.get("/same", "first")
    builder.post("/same", "second")
    builder.get("/same", "third")
    var paths = builder.get_paths()
    var names = builder.get_handler_names()
    assert_equal(len(paths), 3)
    assert_equal(names[0], "first")
    assert_equal(names[1], "second")
    assert_equal(names[2], "third")
    assert_equal(paths[0], paths[1])


def test_builder_paths_and_names_stay_aligned() raises:
    var builder = RouterBuilder()
    for i in range(20):
        builder.get("/p" + String(i), "h" + String(i))
    var paths = builder.get_paths()
    var names = builder.get_handler_names()
    assert_equal(len(paths), len(names))
    for i in range(20):
        assert_equal(paths[i], "/p" + String(i))
        assert_equal(names[i], "h" + String(i))


def main() raises:
    print("Running RouterBuilder tests...")
    test_router_builder()
    test_builder_returns_independent_copies()
    test_builder_keeps_registration_order_and_duplicates()
    test_builder_paths_and_names_stay_aligned()
    print("✅ All RouterBuilder tests passed!")
