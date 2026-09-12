struct HTTPRequest:
    var url: String
    var path: String
    var query_string: String
    var method: String
    var body: String
    var headers: Dict[String, String]

    def __init__(
        out self,
        url: String = "",
        method: String = "GET",
        path: String = "",
        query_string: String = ""
    ):
        self.url = url
        if path == "" and url != "":
            var q_pos = url.find("?")
            if q_pos != -1:
                self.path = String(url[byte=0:q_pos])
                self.query_string = String(url[byte=q_pos + 1:len(url.as_bytes())])
            else:
                self.path = url
                self.query_string = ""
        else:
            self.path = path
            self.query_string = query_string
        self.method = method
        self.body = ""
        self.headers = Dict[String, String]()

    def get_header(self, name: String) -> String:
        return self.headers.get(name, "")
