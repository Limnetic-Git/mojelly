from mojelly.http.query import QueryParams, parse_query_string


struct HTTPRequest:
    var url: String
    var path: String
    var query_string: String
    var query: QueryParams
    var method: String
    var body: String
    var headers: Dict[String, String]
    var cookies: Dict[String, String]
    var params: Dict[String, String]

    def __init__(
        out self,
        url: String = "",
        method: String = "GET",
        path: String = "",
        query_string: String = "",
    ):
        self.url = url
        if path == "" and url != "":
            var q_pos = url.find("?")
            if q_pos != -1:
                self.path = String(url[byte=0:q_pos])
                self.query_string = String(
                    url[byte = q_pos + 1 : len(url.as_bytes())]
                )
            else:
                self.path = url
                self.query_string = ""
        else:
            self.path = path
            self.query_string = query_string

        if self.query_string != "":
            self.query = QueryParams(self.query_string)
        else:
            self.query = QueryParams()

        self.method = method
        self.body = ""
        self.headers = Dict[String, String]()
        self.cookies = Dict[String, String]()
        self.params = Dict[String, String]()

    def get_header(self, name: String) -> String:
        return self.headers.get(name, "")

    def get_cookie(self, name: String) -> String:
        return self.cookies.get(name, "")

    def has_cookie(self, name: String) -> Bool:
        return name in self.cookies

    def get_query(self, name: String, default: String = "") -> String:
        return self.query.get(name, default)

    def get_query_int(self, name: String, default: Int = 0) -> Int:
        return self.query.get_int(name, default)

    def get_query_bool(self, name: String, default: Bool = False) -> Bool:
        return self.query.get_bool(name, default)

    def has_query(self, name: String) -> Bool:
        return self.query.has(name)

    def get_param(self, name: String) -> String:
        return self.params.get(name, "")

    def has_param(self, name: String) -> Bool:
        return name in self.params

