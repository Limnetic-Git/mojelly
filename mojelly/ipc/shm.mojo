# mojelly/ipc/shm.mojo — Shared Memory для Mojo

from std.memory import memcpy, memset

# ============================================================
# 1. ВНЕШНИЕ ФУНКЦИИ (из bridge_shm.c)
# ============================================================

@foreign("mojelly")
def shm_create(name: Pointer[UInt8], size: UInt64) -> Pointer[UInt8]

@foreign("mojelly")
def shm_destroy(ptr: Pointer[UInt8], size: UInt64) -> None

@foreign("mojelly")
def shm_remove(name: Pointer[UInt8]) -> None

@foreign("mojelly")
def ring_buffer_init(rb: Pointer[UInt8]) -> None

@foreign("mojelly")
def ring_buffer_write_request(rb: Pointer[UInt8], data: Pointer[UInt8], len: UInt64) -> Int32

@foreign("mojelly")
def ring_buffer_read_request(rb: Pointer[UInt8], buffer: Pointer[UInt8], len: Pointer[UInt64]) -> Int32

@foreign("mojelly")
def ring_buffer_write_response(rb: Pointer[UInt8], data: Pointer[UInt8], len: UInt64) -> Int32

@foreign("mojelly")
def ring_buffer_read_response(rb: Pointer[UInt8], buffer: Pointer[UInt8], len: Pointer[UInt64]) -> Int32

# ============================================================
# 2. SHARED MEMORY
# ============================================================

struct SharedMemory:
    var ptr: Pointer[UInt8]
    var size: UInt64
    var name: String

    def __init__(out self, name: String, size: UInt64 = 1024 * 1024):
        self.name = name
        self.size = size
        let name_cstr = string_to_c_string(name)
        self.ptr = shm_create(name_cstr, size)
        name_cstr.free()
        
        if self.ptr.is_null():
            print("❌ Failed to create shared memory: " + name)

    def __delinit__(self):
        if not self.ptr.is_null():
            shm_destroy(self.ptr, self.size)
            let name_cstr = string_to_c_string(self.name)
            shm_remove(name_cstr)
            name_cstr.free()

    def read(self, offset: UInt64, len: UInt64) -> String:
        var data = Pointer[UInt8].alloc(len)
        memcpy(data, self.ptr + offset, len)
        var result = String(data, len)
        data.free()
        return result

    def write(self, offset: UInt64, data: String):
        let bytes = data.as_bytes()
        memcpy(self.ptr + offset, bytes.data(), bytes.size())

# ============================================================
# 3. КОЛЬЦЕВОЙ БУФЕР
# ============================================================

struct RingBuffer:
    var ptr: Pointer[UInt8]

    def __init__(out self, shm: SharedMemory):
        self.ptr = shm.ptr
        ring_buffer_init(self.ptr)

    def write_request(self, data: String) -> Bool:
        let bytes = data.as_bytes()
        let result = ring_buffer_write_request(self.ptr, bytes.data(), UInt64(bytes.size()))
        return result == 0

    def read_request(self) -> String:
        var buffer = Pointer[UInt8].alloc(1024 * 1024)
        var len = UInt64(0)
        let result = ring_buffer_read_request(self.ptr, buffer, Pointer[UInt64].alloc(len))
        if result == 0:
            var data = String(buffer, len)
            buffer.free()
            return data
        buffer.free()
        return ""

    def write_response(self, data: String) -> Bool:
        let bytes = data.as_bytes()
        let result = ring_buffer_write_response(self.ptr, bytes.data(), UInt64(bytes.size()))
        return result == 0

    def read_response(self) -> String:
        var buffer = Pointer[UInt8].alloc(1024 * 1024)
        var len = UInt64(0)
        let result = ring_buffer_read_response(self.ptr, buffer, Pointer[UInt64].alloc(len))
        if result == 0:
            var data = String(buffer, len)
            buffer.free()
            return data
        buffer.free()
        return ""

# ============================================================
# 4. ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ============================================================

def string_to_c_string(s: String) -> Pointer[UInt8]:
    let bytes = s.as_bytes()
    let result = Pointer[UInt8].alloc(bytes.size() + 1)
    for i in range(bytes.size()):
        result[i] = bytes[i]
    result[bytes.size()] = 0
    return result
