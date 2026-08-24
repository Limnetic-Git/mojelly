struct RouterBuilder:
    var paths: List[String]
    var handler_names: List[String]

    def __init__(out self):
        self.paths = List[String]()
        self.handler_names = List[String]()

    def get(mut self, path: String, handler_name: String):
        self.paths.append(path)
        self.handler_names.append(handler_name)

    def post(mut self, path: String, handler_name: String):
        self.paths.append(path)
        self.handler_names.append(handler_name)

    def put(mut self, path: String, handler_name: String):
        self.paths.append(path)
        self.handler_names.append(handler_name)

    def delete(mut self, path: String, handler_name: String):
        self.paths.append(path)
        self.handler_names.append(handler_name)

    def get_paths(self) -> List[String]:
        var copy = List[String]()
        for i in range(len(self.paths)):
            copy.append(self.paths[i])
        return copy^

    def get_handler_names(self) -> List[String]:
        var copy = List[String]()
        for i in range(len(self.handler_names)):
            copy.append(self.handler_names[i])
        return copy^
