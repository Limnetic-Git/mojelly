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

## What we use ⚙️
Mojo language
C language
Bash (for `build.sh`)
llhttp
libuv
openssl
gcc compiler

## Mojelly's logo 🖼️
**Mojelly's logo is a GRAPE! 🍇🍇🍇**

(*Idk why, "jelly" sounds cool and I associate with grapes*)

# How to use it
Here is syntax of UPDATE-3 (0.0.3-INDEV), which will **100%** change in **1.0.0**,
so check it out, but don't learn it hardly :)

**⚠️ WARNING: This guide is only for Linux! If u are using other OS - i will write guides for them soon**

**Here is `examples/my_app.mojo`**:
```mojo
from mojelly.http.request import HTTPRequest
from mojelly.http.response import HTTPResponse
from mojelly.core.router_handlers import RouterHandlers
from mojelly.core.server import HTTPServer


def home_handler(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(200, "Home Page 🏠")

def about_handler(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(200, "About Page 📖")

def users_handler(req: HTTPRequest) -> HTTPResponse:
    var resp = HTTPResponse(200, '[{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]')
    resp.set_json()
    return resp^

def hello_handler(req: HTTPRequest) -> HTTPResponse:
    var resp = HTTPResponse(200, '{"message":"Hello from Mojelly! 🍇"}')
    resp.set_json()
    return resp^

def main():
    print("🍇 Mojelly HTTP Server")

    var router = RouterHandlers()

    router.add("/", home_handler)
    router.add("/about", about_handler)
    router.add("/api/users", users_handler)
    router.add("/api/hello", hello_handler)

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
~/Документы/Mojo/mojelly-0.0.2
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

~/Документы/Mojo/mojelly-0.0.2
❯ ./server 
🍇 Mojelly HTTP Server
[C] uv_loop_create_wrapper: loop=0x55c94b75e7c0, init_ret=0
[C] Router set to 0x7fff320bbb08
[C] uv_run_wrapper: loop=0x55c94b75e7c0 starting...

```

If you are interested, please ⭐ this project :)
Thank you! 🍇

# IF YOU WANT TO ASK ME SOMETHING, PLEASE, WRITE ME IN DISCORD OR TELEGRAM (`@limneticgg`)


