from mojelly.http.request import HTTPRequest
from mojelly.http.response import HTTPResponse
from dto import UserDTO

def dto_validation_test(req: HTTPRequest, dto: UserDTO) -> HTTPResponse:
    if dto.age >= 18:
        return HTTPResponse(200, dto.nickname + "is adult")
    else:
        return HTTPResponse(200, dto.nickname + "is not adult")

def user_handler(req: HTTPRequest) -> HTTPResponse:
    var user_id = req.get_param("id")
    var resp = HTTPResponse(200, "User ID: " + user_id)
    return resp^
