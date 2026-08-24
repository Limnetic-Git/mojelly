struct HTTPResponse:
    var status: Int32
    var body: String
    var content_type: String
    var headers: Dict[String, String]

    def __init__(out self, status: Int32 = 200, body: String = ""):
        self.status = status
        self.body = body
        self.content_type = "text/plain"
        self.headers = Dict[String, String]()

    def set_json(mut self):
        self.content_type = "application/json"

    def set_header(mut self, name: String, value: String):
        self.headers[name] = value
