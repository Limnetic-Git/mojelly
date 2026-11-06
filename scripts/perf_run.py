#!/usr/bin/env python3
"""Benchmark several built Mojelly servers against each other.

Usage:
  scripts/perf_run.py --build main=path/to/main --build dev=path/to/dev \
      --build pr=path/to/pr --out results.json

Each build directory must contain a built ./server. For every scenario the
builds are measured in turns, `--reps` times, rotating who goes first, so
slow drift on a shared machine does not favour one build. Per run it records
requests/s, latency percentiles and the server's CPU time per request (read
from /proc, far less noisy than requests/s on shared runners).

Needs `oha` on PATH. Linux only.
"""

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import time

PORT = 8080
TICK = os.sysconf("SC_CLK_TCK")

BROWSER_HEADERS = [
    "User-Agent: Mozilla/5.0 (X11; Linux x86_64) Firefox/130.0",
    "Accept: text/html,application/xhtml+xml,*/*;q=0.8",
    "Accept-Language: en-US,en;q=0.5",
    "Cookie: session=abc123xyz; theme=dark; lang=en",
    "X-Request-Id: 7f3c9a10-5b2e-4c41-9d8e-1a2b3c4d5e6f",
    "Authorization: Bearer 0123456789abcdef",
]

# name, description, path, connections, extra oha args
SCENARIOS = [
    ("json-100", "GET /json, 100 keep-alive connections", "/json", 100, []),
    ("json-500", "GET /json, 500 keep-alive connections", "/json", 500, []),
    ("json-new-conn", "GET /json, a new connection per request (100 clients)",
     "/json", 100, ["--disable-keepalive"]),
    ("browser", "GET /json with 6 browser-like headers and 3 cookies",
     "/json", 100, [a for h in BROWSER_HEADERS for a in ("-H", h)]),
    ("html", "GET /html, larger response body", "/html", 100, []),
]


def git(dirpath, *args):
    try:
        return subprocess.run(["git", "-C", dirpath, *args], capture_output=True,
                              text=True, check=True).stdout.strip()
    except Exception:  # noqa: BLE001
        return ""


def server_ready(timeout=10.0):
    end = time.time() + timeout
    while time.time() < end:
        try:
            with socket.create_connection(("127.0.0.1", PORT), timeout=0.5) as s:
                s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                if s.recv(16).startswith(b"HTTP/1.1 200"):
                    return True
        except OSError:
            time.sleep(0.1)
    return False


def port_in_use():
    try:
        socket.create_connection(("127.0.0.1", PORT), timeout=0.3).close()
        return True
    except OSError:
        return False


def cpu_seconds(pid):
    f = open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()
    return (int(f[11]) + int(f[12])) / TICK  # utime + stime


def pin(cpus, cmd):
    if cpus and shutil.which("taskset"):
        return ["taskset", "-c", cpus, *cmd]
    return cmd


def measure(dirpath, scenario, args, server_cpus, client_cpus):
    name, _, path, conns, extra = scenario
    if port_in_use():
        raise SystemExit(f"port {PORT} is already in use; stop the other server first")
    server = subprocess.Popen(pin(server_cpus, ["./server"]), cwd=dirpath,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        if not server_ready():
            raise RuntimeError(f"server in {dirpath} did not become ready")
        url = f"http://127.0.0.1:{PORT}{path}"
        base = pin(client_cpus, ["oha", "-c", str(conns), "--no-tui", *extra])
        subprocess.run([*base, "-z", f"{args.warmup}s", url],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cpu0, t0 = cpu_seconds(server.pid), time.time()
        out = subprocess.run([*base, "-z", f"{args.duration}s", "--output-format",
                              "json", url], capture_output=True, text=True).stdout
        cpu1, t1 = cpu_seconds(server.pid), time.time()
        workers = len(os.listdir(f"/proc/{server.pid}/task"))
    finally:
        server.terminate()
        try:
            server.wait(timeout=3)
        except subprocess.TimeoutExpired:
            server.kill()
        time.sleep(0.5)

    d = json.loads(out)
    codes = d.get("statusCodeDistribution", {})
    total = sum(codes.values())
    ok = codes.get("200", 0)
    pct = d["latencyPercentiles"]
    return {
        "rps": d["summary"]["requestsPerSec"],
        "p50_ms": (pct.get("p50") or 0) * 1e3,
        "p99_ms": (pct.get("p99") or 0) * 1e3,
        "requests": total,
        "ok_ratio": ok / total if total else 0.0,
        "cpu_us_per_req": (cpu1 - cpu0) / total * 1e6 if total else 0.0,
        "server_cpu_pct": (cpu1 - cpu0) / (t1 - t0) * 100,
        "threads": workers,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--build", action="append", required=True, metavar="LABEL=DIR")
    ap.add_argument("--out", required=True)
    ap.add_argument("--duration", type=int, default=10, help="measured seconds per run")
    ap.add_argument("--warmup", type=int, default=3)
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--scenarios", default="", help="comma-separated names (default: all)")
    args = ap.parse_args()

    if not shutil.which("oha"):
        sys.exit("oha not found on PATH")
    builds = [tuple(b.split("=", 1)) for b in args.build]
    for label, d in builds:
        if not os.path.exists(os.path.join(d, "server")):
            sys.exit(f"{label}: no built ./server in {d}")

    scenarios = [s for s in SCENARIOS if not args.scenarios or s[0] in args.scenarios.split(",")]
    cpus = sorted(os.sched_getaffinity(0))
    if len(cpus) >= 4:
        half = len(cpus) // 2
        server_cpus = ",".join(map(str, cpus[:half]))
        client_cpus = ",".join(map(str, cpus[half:]))
    else:
        server_cpus = client_cpus = ""

    oha_version = subprocess.run(["oha", "--version"], capture_output=True,
                                 text=True).stdout.strip()
    meta = {
        "cpus": len(cpus), "server_cpus": server_cpus, "client_cpus": client_cpus,
        "oha": oha_version, "duration_s": args.duration, "warmup_s": args.warmup,
        "reps": args.reps,
        "builds": [{"label": l, "dir": d, "sha": git(d, "rev-parse", "--short", "HEAD"),
                    "subject": git(d, "log", "-1", "--format=%s")} for l, d in builds],
        "scenarios": [{"name": s[0], "description": s[1], "connections": s[3]}
                      for s in scenarios],
    }

    runs = []
    for si, scenario in enumerate(scenarios):
        for rep in range(args.reps):
            order = builds[(rep + si) % len(builds):] + builds[:(rep + si) % len(builds)]
            for label, d in order:
                r = measure(d, scenario, args, server_cpus, client_cpus)
                r.update(build=label, scenario=scenario[0], rep=rep)
                runs.append(r)
                print(f"{scenario[0]:<14} rep{rep} {label:<5} {r['rps']:>9,.0f} req/s  "
                      f"p99 {r['p99_ms']:.3f} ms  cpu {r['cpu_us_per_req']:.2f} us/req  "
                      f"ok {r['ok_ratio']:.2%}", flush=True)

    with open(args.out, "w") as f:
        json.dump({"meta": meta, "runs": runs}, f, indent=1)


if __name__ == "__main__":
    main()
