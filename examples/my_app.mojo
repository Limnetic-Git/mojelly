from mojelly.http.request import HTTPRequest
from mojelly.http.response import HTTPResponse
from mojelly.core.router_handlers import RouterHandlers
from emberjson import try_deserialize, serialize

@fieldwise_init
struct CreateUserDTO(Movable, Defaultable):
    var nickname: String
    var age: Int

    def __init__(out self):
        self.nickname = ""
        self.age = 0

    def default() -> Self:
        var result = Self()
        result.nickname = ""
        self.age = 0
        return result^

def create_user_handler(req: HTTPRequest) -> HTTPResponse: #В АРГУМЕНТЕ ДОЛЖНА БУДЕТ БЫТЬ dto: CreateUserDTO ДЛЯ ПАРСИНГА

    # ВОТ ЭТО ЧАСТЬ ДОЛЖНА БУДЕТ ГЕНЕРИРОВАТЬСЯ
    var dto_opt = try_deserialize[CreateUserDTO](req.body)
    if not dto_opt:
        return HTTPResponse(400, "Invalid parse JSON to DTO")
    var dto = dto_opt.take()


    print("Age:", dto.age)
    var adult = (True if dto.age >= 18 else False)
    print("Adult:", adult)
    print("Nickname:", dto.nickname)

    return HTTPResponse(200, "OK")

def main():
    var router = RouterHandlers()
    router.post("/users", create_user_handler)

    var server = HTTPServer(router)
    server.listen(8080)
    server.run()
