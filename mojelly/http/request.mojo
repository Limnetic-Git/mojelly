struct HTTPRequest:
    var url: String
    var method: String
    var body: String
    var headers: Dict[String, String]

    def __init__(out self, url: String = "", method: String = "GET"):
        self.url = url
        self.method = method
        self.body = ""
        self.headers = Dict[String, String]()

    def get_header(self, name: String) -> String:
        return self.headers.get(name, "")
