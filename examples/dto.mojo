@fieldwise_init
struct UserDTO(Defaultable, Movable):
    var nickname: String
    var age: Int
    def __init__(out self):
        self.nickname = ""
        self.age = 0
