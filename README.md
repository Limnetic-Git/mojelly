# Mojelly Framework 🍇

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

### JSON response in UPDATE-5 (0.0.5-INDEV) using 4 threads (default): 
```bash
❯ wrk -t4 -c100 -d5s http://localhost:8080/api/users
Running 5s test @ http://localhost:8080/api/users
  4 threads and 100 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   182.15us  323.66us  18.43ms   99.61%
    Req/Sec   142.25k    14.11k  171.39k    68.50%
  2830900 requests in 5.01s, 380.67MB read
Requests/sec: 565182.57
Transfer/sec:     76.00MB
```

### Text response in UPDATE-5 (0.0.5-INDEV) using 4 threads (default):
```bash
❯ wrk -t4 -c100 -d5s http://localhost:8080/
Running 5s test @ http://localhost:8080/
  4 threads and 100 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   171.56us   96.79us   6.08ms   92.58%
    Req/Sec   144.09k    16.87k  220.59k    66.50%
  2867439 requests in 5.01s, 281.66MB read
Requests/sec: 572749.87
Transfer/sec:     56.26MB
```
And i will try to make **MORE RPS** cause I love **BLAZING** 🔥


## What we use ⚙️
Mojo language
C language
Bash (for `build.sh`)
llhttp
libuv (soon will be change to io_uring)
openssl
pthread
gcc compiler

## Mojelly's logo 🖼️
**Mojelly's logo is a GRAPE! 🍇🍇🍇**

(*Idk why, "jelly" sounds cool and I associate with grapes*)

# How to use it
Here is syntax of UPDATE-5 (0.0.5-INDEV), which will **100%** change in **1.0.0**,
so check it out, but don't learn it hardly :)

**⚠️ WARNING: FRAMEWORK (as like as Mojo) WORKS ONLY ON LINUX! USE WSL OR LINUX DISTRO**

**Here is `examples/my_app.mojo`**:
```mojo
from mojelly.http.request import HTTPRequest
from mojelly.http.response import HTTPResponse
from mojelly.core.router_handlers import RouterHandlers

def home_handler(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(200, "Home Page 🏠")

def about_handler(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(200, "About Page 📖")

def users_handler(req: HTTPRequest) -> HTTPResponse:
    var resp = HTTPResponse(200, '[{"id": 1, "name": "Alice"},{"id": 2, "name": "Bob"}]')
    resp.set_json()
    return resp^

def hello_handler(req: HTTPRequest) -> HTTPResponse:
    var resp = HTTPResponse(200, '{"message": "Hello from Mojelly! 🍇"}')
    resp.set_json()
    return resp^

def main():
    print("🍇 Mojelly HTTP Server")

    var router = RouterHandlers()

    router.get("/", home_handler)
    router.post("/about", about_handler) # POST for test
    router.get("/api/users", users_handler)
    router.get("/api/hello", hello_handler)

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
~/Документы/Mojo/mojelly-0.0.4
❯ bash build.sh
🔍 Checking C core...
✅ libmojelly.a is up to date
-rw-r--r-- 1 limnetic limnetic 16872 авг 25 15:50 lib/libmojelly.a

📢 Calling for server-code generator...
Failed to initialize Crashpad.  Crash reporting will not be available.  Cause: while locating crashpad handler: unable to locate crashpad handler executable
🔧 Generating server code...
✅ Generated: build/app_generated.mojo
📦 Run: ./build.sh

📦 Building server...
Failed to initialize Crashpad.  Crash reporting will not be available.  Cause: while locating crashpad handler: unable to locate crashpad handler executable
✅ Server built! Run ./server

~/Документы/Mojo/mojelly-0.0.4
❯ ./server
🍇 Mojelly HTTP Server (Multithreaded)
[C] ✅ All 4 threads created
✅ All 4 threads started
🚀 Server listening on port 8080
[C] 🧵 Thread 2 listening on CPU 2 (port 8080)
[C] 🧵 Thread 3 listening on CPU 3 (port 8080)
[C] 🧵 Thread 1 listening on CPU 1 (port 8080)
[C] 🧵 Thread 0 listening on CPU 0 (port 8080)
[03:38:52] [T0] POST /about 200 0.01ms
[03:38:54] [T1] GET /about 404 0.00ms
```

If you are interested, please ⭐ this project :)
Thank you! 🍇

# IF YOU WANT TO ASK ME SOMETHING, PLEASE, WRITE ME IN DISCORD OR TELEGRAM (`@limneticgg`)


