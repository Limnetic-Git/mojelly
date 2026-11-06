#!/usr/bin/env python3
"""E2E tests: routing (path params, methods), query strings and cookies."""

from e2e_common import Suite, get


def main():
    with Suite("Routing, query strings and cookies") as s:
        # ---- path parameters -------------------------------------------
        r = get("/user/42")
        s.check("GET /user/:id binds the id", r.status == 200 and r.body == b"User ID: 42", r.body)
        r = get("/user/alice")
        s.check("GET /user/:id accepts non-numeric ids", r.body == b"User ID: alice", r.body)
        r = get("/user/alice/profile")
        s.check("GET /user/:login/profile", r.status == 200 and r.body == b"Profile of alice", r.body)
        r = get("/user/7/posts/99")
        s.check("GET /user/:id/posts/:post_id binds both params",
                r.status == 200 and r.body == b"Post 99 by user 7", r.body)
        r = get("/move-page/3/9", method="POST")
        s.check("POST /move-page/:page_id/:move_to",
                r.status == 200 and r.body == b"Move page 3 to 9", r.body)
        r = get("/user/42?x=1")
        s.check("path param route ignores the query string",
                r.status == 200 and r.body == b"User ID: 42", r.body)
        r = get("/user/1/posts")
        s.check("too few segments -> 404", r.status == 404)
        r = get("/user/1/posts/2/extra")
        s.check("too many segments -> 404", r.status == 404)
        r = get("/user/1/comments/2")
        s.check("wrong literal segment -> 404", r.status == 404)
        r = get("/user/42", method="POST")
        s.check("wrong method on a pattern route -> 404", r.status == 404)
        r = get("/move-page/3/9")
        s.check("GET on a POST-only pattern route -> 404", r.status == 404)

        # ---- methods on plain routes -----------------------------------
        for method in ("PUT", "DELETE", "PATCH"):
            r = get("/json", method=method)
            s.check(f"{method} on a GET-only route -> 404", r.status == 404, r.status)
        r = get("/echo")
        s.check("GET on a POST-only route -> 404", r.status == 404)
        r = get("/does/not/exist")
        s.check("unknown path -> 404 'Not Found'",
                r.status == 404 and r.body == b"Not Found", (r.status, r.body))

        # ---- query strings ---------------------------------------------
        r = get("/query/dict?name=Bob%20Ray&page=2")
        s.check("percent-decoded space in a query value",
                r.body == b"Hello Bob Ray, page 2", r.body)
        r = get("/query/dict?name=a+b")
        s.check("'+' decodes to a space", r.body == b"Hello a b, page 1", r.body)
        r = get("/query/dict?name=a%2Bb")
        s.check("%2B decodes to a literal plus", r.body == b"Hello a+b, page 1", r.body)
        r = get("/query/dict")
        s.check("defaults are used without a query string",
                r.body == b"Hello Guest, page 1", r.body)
        r = get("/query/dict?name=first&name=second")
        s.check("repeated key: last value wins", r.body == b"Hello second, page 1", r.body)
        r = get("/query/dict?name=")
        s.check("empty value is kept as an empty string", r.body == b"Hello , page 1", r.body)
        r = get("/query/dict?name=x&&&page=5&")
        s.check("empty pairs are ignored", r.body == b"Hello x, page 5", r.body)
        r = get("/query?a=1&b=2")
        s.check("raw query string is exposed unchanged",
                r.body == b"Path: /query, Query: a=1&b=2", r.body)
        r = get("/query?")
        s.check("a bare '?' gives an empty query",
                r.status == 200 and r.body == b"Path: /query, Query: ", r.body)

        # ---- GET DTO from the query string ------------------------------
        r = get("/user/query?nickname=Ann&age=30")
        s.check("GET DTO: adult", r.status == 200 and b"is adult" in r.body, r.body)
        r = get("/user/query?nickname=Kid&age=9")
        s.check("GET DTO: minor", r.status == 200 and b"is minor" in r.body, r.body)
        r = get("/user/query?nickname=Ann")
        s.check("GET DTO: missing field -> 400", r.status == 400, (r.status, r.body))

        # ---- cookies ----------------------------------------------------
        r = get("/cookies/set")
        cookies = r.all_headers("Set-Cookie")
        s.check("/cookies/set sends two Set-Cookie headers", len(cookies) == 2, cookies)
        by_name = {c.split("=", 1)[0]: c for c in cookies}
        sess = by_name.get("session", "")
        s.check("session cookie attributes",
                "session=abc123xyz" in sess and "Path=/" in sess and "Max-Age=3600" in sess
                and "HttpOnly" in sess and "SameSite=Lax" in sess, sess)
        theme = by_name.get("theme", "")
        s.check("theme cookie is not HttpOnly",
                "theme=dark" in theme and "Max-Age=86400" in theme and "HttpOnly" not in theme, theme)

        r = get("/cookies/read", headers={"Cookie": "session=S1; theme=light"})
        s.check("cookies are read back", b"session = S1" in r.body and b"theme = light" in r.body, r.body)
        r = get("/cookies/read")
        s.check("missing cookies are reported as not set",
                b"session = (not set)" in r.body and b"theme = (not set)" in r.body, r.body)
        r = get("/cookies/read", headers={"Cookie": "session=only"})
        s.check("a single cookie out of two",
                b"session = only" in r.body and b"theme = (not set)" in r.body, r.body)
        r = get("/cookies/read", headers={"Cookie": "  session = spaced ;theme=x"})
        s.check("whitespace around cookie names and values is trimmed",
                b"session = spaced" in r.body and b"theme = x" in r.body, r.body)
        r = get("/cookies/read", headers={"COOKIE": "session=upper"})
        s.check("uppercase COOKIE header is accepted", b"session = upper" in r.body, r.body)
        r = get("/cookies/delete")
        names = [c.split("=", 1)[0] for c in r.all_headers("Set-Cookie")]
        s.check("/cookies/delete expires both cookies by name",
                sorted(names) == ["session", "theme"], names)

        s.finish()


if __name__ == "__main__":
    main()
