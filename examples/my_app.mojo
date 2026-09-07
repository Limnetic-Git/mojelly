from mojelly.http.request import HTTPRequest
from mojelly.http.response import HTTPResponse
from mojelly.core.router_handlers import RouterHandlers

@fieldwise_init
struct CreateUserDTO(Defaultable, Movable):
    var nickname: String
    var age: Int

    def __init__(out self):
        self.nickname = ""
        self.age = 0

def create_user_handler(req: HTTPRequest, dto: CreateUserDTO) -> HTTPResponse:
    print("Age:", dto.age)
    var adult = True if dto.age >= 18 else False
    print("Adult:", adult)
    print("Nickname:", dto.nickname)

    return HTTPResponse(200, "OK")

def main():
    var router = RouterHandlers()
    router.post("/users", create_user_handler)

    var server = HTTPServer(router)
    server.listen(8080)
    server.run()
