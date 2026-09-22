# Mojelly Framework 🍇

⭐ **Starred by [@lattner](https://github.com/lattner)** — creator of **LLVM**, **Swift**, and **Mojo** 

Thank you, Chris :)

<p align="center">
</p>

<h1 align="center">🍇 Mojelly</h1>
<p align="center">
  <strong>Fast async backend framework for Mojo</strong>
</p>

<p align="center">
  <a href="#"><img src="https://img.shields.io/badge/Mojo-1.0.0-blue.svg" alt="Mojo"></a>
  <a href="#"><img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License"></a>
  <a href="#"><img src="https://img.shields.io/badge/PRs-welcome-brightgreen.svg" alt="PRs"></a>
  <a href="#"><img src="https://img.shields.io/badge/Platform-Linux-lightgrey.svg" alt="Platform"></a>
</p>

## About Mojelly ❔
**Mojelly** - Fast async opensource backend framework for Mojo 🍇!
Mojelly started as Limnetic's (creator, me :D) pet-project which was created for test of Mojo's speed with Zero-Copy FFI with C.
And Mojo is young lang, very powerful with simple syntax. 
So, it was cool challenge for me. Mojelly is created to be fast-enough, 
simple to use and easy to contribute, that makes it good choice to you to join the project!


## Some benchmarks 📊

### JSON response in UPDATE-7 (0.0.7-INDEV) using 4 threads (default): 
```bash
❯ wrk -t4 -c100 -d5s http://localhost:8080/json
Running 5s test @ http://localhost:8080/json
  4 threads and 100 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   175.81us  110.82us   2.51ms   92.64%
    Req/Sec   143.30k    12.24k  176.02k    66.00%
  2848343 requests in 5.01s, 344.98MB read
Requests/sec: 568252.06
Transfer/sec:     68.82MB
```

### Text response in UPDATE-7 (0.0.7-INDEV) using 4 threads (default):
```bash
❯ wrk -t4 -c100 -d5s http://localhost:8080/
Running 5s test @ http://localhost:8080/
  4 threads and 100 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   172.56us   98.25us   2.74ms   90.90%
    Req/Sec   144.09k    10.54k  196.64k    70.50%
  2866244 requests in 5.01s, 276.08MB read
Requests/sec: 572494.94
Transfer/sec:     55.14MB
```

### HTML-page response in UPDATE-7 (0.0.7-INDEV) using 4 threads (default):
```bash
❯ wrk -t4 -c100 -d5s http://localhost:8080/html
Running 5s test @ http://localhost:8080/html
  4 threads and 100 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   213.75us   77.08us   4.41ms   89.62%
    Req/Sec   116.12k     5.97k  137.13k    72.00%
  2308867 requests in 5.01s, 1.67GB read
Requests/sec: 460630.12
Transfer/sec:    340.89MB
```

### DTO validation response in UPDATE-7 (0.0.7-INDEV) using 4 threads (default):
```bash
❯ wrk -t4 -c100 -d5s -s post.lua http://localhost:8080/user
Running 5s test @ http://localhost:8080/user
  4 threads and 100 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   194.81us   66.64us   2.07ms   87.49%
    Req/Sec   126.52k     6.53k  152.52k    71.00%
  2517629 requests in 5.01s, 242.50MB read
Requests/sec: 502680.09
Transfer/sec:     48.42MB
```
And i will try to make **MORE RPS** cause I love **BLAZING** 🔥

## What we use ⚙️
Mojo language
C language
Bash (for `build.sh`)
llhttp
libuv (soon maybe will be change to io_uring)
openssl (not yet)
pthread
gcc compiler
emberjson

## Mojelly's logo 🖼️
**Mojelly's logo is a GRAPE! 🍇🍇🍇**

(*Idk why, "jelly" sounds cool and I associate with grapes*)

# How to use it
Here is syntax of UPDATE-7 (0.0.7-INDEV), which will **100%** change in **1.0.0**,
so check it out, but don't learn it hardly :)

**⚠️ WARNING: FRAMEWORK (as like as Mojo) WORKS ONLY ON LINUX! USE WSL OR LINUX DISTRO**

**Here is `examples/my_app.mojo`**:
```mojo
from mojelly.http.request import HTTPRequest
from mojelly.http.response import HTTPResponse
from mojelly.core.router_handlers import RouterHandlers
from dto import UserDTO
from test_html_page import test_html_page, test_css

#Hello world plain text response
def hello_world(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(200, "Hello, World")

#JSON response
def json_test(req: HTTPRequest) -> HTTPResponse:
    var resp = HTTPResponse(200, '{"nickname":"Limnetic","age":17}')
    resp.set_json()
    return resp^

#HTML page response
def html_page_test(req: HTTPRequest) -> HTTPResponse:
    var resp = HTTPResponse(200, test_html_page)
    resp.set_html()
    return resp^

#CSS response
def css_test(req: HTTPRequest) -> HTTPResponse:
    var resp = HTTPResponse(200, test_css)
    resp.set_css()
    return resp^

#With DTO validation
def dto_validation_test(req: HTTPRequest, dto: UserDTO) -> HTTPResponse:
    if dto.age >= 18:
        return HTTPResponse(200, dto.nickname + "is adult")
    else:
        return HTTPResponse(200, dto.nickname + "is not adult")

def main():
    var router = RouterHandlers()

    router.get("/", hello_world)
    router.get("/json", json_test)
    router.get("/html", html_page_test)
    router.get("/style.css", css_test)
    router.post("/user", dto_validation_test)

    var server = HTTPServer(router)
    server.listen(8080)
    server.run()
```

After this, run `build.sh` 🛠️:
```bash
bash build.sh
```
It will generate `build/app_generated.mojo` and auto-compile it to `server` binary file. 
Then, you can run your server! 🙂
```bash
./server
```

Normally is looks like that:

```console
❯ bash build.sh 
🔧 Using pixi environment...
🔥 Using Mojo via pixi:
Mojo 1.0.0 (ed45d567)

🔍 Checking C core...
📦 libmojelly.a not found, building...
🔨 Building C core with -O3...
✅ libmojelly.a rebuilt!
-rw-r--r-- 1 limnetic limnetic 20610 сен  8 01:14 lib/libmojelly.a

📢 Calling for server-code generator...
🔧 Generating server code...
   Mode: MULTITHREADED
✅ Generated: build/app_generated.mojo
📦 Run: ./build.sh

📦 Building server...

✅ Server built! Run ./server

   To run:
   ./server

❯ ./server
🍇 Mojelly HTTP Server (Multithreaded)
[C] ✅ All 4 threads created
✅ All 4 threads started
🚀 Server listening on port 8080
[C] 🧵 Thread 2 listening on CPU 2 (port 8080)
[C] 🧵 Thread 3 listening on CPU 3 (port 8080)
[C] 🧵 Thread 1 listening on CPU 1 (port 8080)
[C] 🧵 Thread 0 listening on CPU 0 (port 8080)
[03:38:52] [T0] GET / 200 0.01ms
[03:38:54] [T1] GET /qwerty 404 0.00ms
```

If you are interested, please ⭐ this project :)
Thank you! 🍇

# IF YOU WANT TO ASK ME SOMETHING, PLEASE, WRITE ME IN DISCORD OR TELEGRAM (`@limneticgg`)


