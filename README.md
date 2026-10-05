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
  <a href="#"><img src="https://img.shields.io/badge/Mojo-1.1.0-blue.svg" alt="Mojo"></a>
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

## Logging 📝

Per-request logging is off by default (it costs ~20% throughput). Enable it at startup:

```bash
MOJELLY_LOG_LEVEL=1 ./server
```

## Worker threads 🧵

By default Mojelly starts one worker per CPU the process is allowed to use (so `taskset` and container cpusets are respected) and pins each worker to one of those CPUs. Override the count with `MOJELLY_THREADS`:

```bash
MOJELLY_THREADS=4 ./server
```

## Limits and timeouts 🛡️

Safe defaults, overridable with environment variables at startup:

| Variable | Default | Meaning |
|---|---|---|
| `MOJELLY_MAX_HEADER_SIZE` | 65536 | URL + headers of one request, bytes (over → `431`) |
| `MOJELLY_MAX_BODY` | 10485760 | request body, bytes (over → `413`) |
| `MOJELLY_IDLE_TIMEOUT` | 60 | seconds without traffic before a connection is closed (`0` = off) |
| `MOJELLY_REQUEST_TIMEOUT` | 30 | seconds allowed to receive one complete request (`0` = off) |

Timeouts are checked once a second, so they are accurate to about one second.

## Performance CI 📈

Every PR to `main` or `dev` is benchmarked by `.github/workflows/perf.yml`: the **PR head**, **dev** and **main** are built and measured one after another on the same runner, and the result is posted as a PR comment. For each scenario (`/json` with 100 and 500 connections, a new connection per request, browser-like headers and cookies, a larger `/html` body) it shows requests/s, p99 latency and server CPU per request, and the PR's change against `dev` and `main`. The job fails if the PR is more than 15% slower than its base branch and the change is larger than the run-to-run noise.

Run it locally (needs [`oha`](https://github.com/hatoo/oha) and a built `./server` in each directory):

```bash
python3 scripts/perf_run.py --build main=../main --build dev=../dev --build pr=. --out results.json
python3 scripts/perf_report.py results.json --pr pr --base dev
```

## What we use ⚙️
- Mojo language
- C language
- Python3 (for tests)
- Bash (for `build.sh` and other)
- llhttp
- libuv (io_uring in experemental)
- openssl (soon)
- pthread
- gcc compiler
- emberjson
- pixi
- Github Actions (CI)

## Mojelly's logo 🖼️
**Mojelly's logo is a GRAPE! 🍇🍇🍇**

(*Idk why, "jelly" sounds cool and I associate with grapes*)

# How to use it
Here is syntax of UPDATE-11 (0.0.11-INDEV), which will **100%** change in **1.0.0**,
so check it out, but don't learn it hardly :)

**⚠️ WARNING: FRAMEWORK (as like as Mojo) WORKS ONLY ON LINUX! USE WSL OR LINUX DISTRO**

## Here is the simplest Mojelly server:
```mojo
from mojelly.http.request import HTTPRequest
from mojelly.http.response import HTTPResponse
from mojelly.core.router_handlers import RouterHandlers

# Your first handler in Mojelly🍇
def hello_world(req: HTTPRequest) -> HTTPResponse:
    return HTTPResponse(200, "Hello, World")

def main():
    var router = RouterHandlers()

    router.get("/", hello_world)

    var server = HTTPServer(router)
    server.listen(8080)
    server.run()
```
To see more features, look `examples/my_app.mojo` and reed documentation (WIP)

After this, run `build.sh` 🛠️:
```bash
bash build.sh
```
It will generate `build/app_generated.mojo` and auto-compile it to `server` binary file. 
Then, you can run your server! 🙂
```bash
MOJELLY_THREADS=4 ./server
```

Normally is looks like that:

```console
❯ bash build.sh
🔧 Using pixi environment...
🔥 Using Mojo via pixi:
Mojo 1.1.0 (8189361e)

🔍 Checking C core...
📦 libmojelly.a not found, building...
🔨 Building C core with -O3...
✅ libmojelly.a rebuilt!
-rw-r--r-- 1 limnetic limnetic 34284 окт  5 11:08 lib/libmojelly.a

📢 Calling for server-code generator...
🔧 Generating server code...
   Mode: MULTITHREADED
✅ Generated: build/app_generated.mojo
📦 Run: ./build.sh

📦 Building server...

✅ Server built! Run ./server

   To run:
   ./server

❯ MOJELLY_THREADS=4 ./server
🍇 Mojelly HTTP Server (Multithreaded)
[C] ✅ All 4 threads created
✅ Worker threads started
🚀 Server listening on port 8080
[C] 🧵 Thread 0 listening on CPU 0 (port 8080)
[C] 🧵 Thread 3 listening on CPU 3 (port 8080)
[C] 🧵 Thread 2 listening on CPU 2 (port 8080)
[C] 🧵 Thread 1 listening on CPU 1 (port 8080)
[03:38:52] [T0] GET / 200 0.01ms
[03:38:54] [T1] GET /qwerty 404 0.00ms
```

If you are interested, please ⭐ this project :)
Thank you! 🍇

# IF YOU WANT TO ASK ME SOMETHING, PLEASE, WRITE ME IN DISCORD OR TELEGRAM (`@limneticgg`)


