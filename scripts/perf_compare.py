#!/usr/bin/env python3
"""Compare two perf_bench.sh results; print a markdown table, exit 1 on regression."""
import argparse
import json
import sys


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("base")
    ap.add_argument("head")
    ap.add_argument("--threshold", type=float, default=15.0,
                    help="max allowed throughput drop, percent")
    args = ap.parse_args()

    base = json.load(open(args.base))
    head = json.load(open(args.head))

    def delta(key: str) -> float:
        return (head[key] - base[key]) / base[key] * 100 if base[key] else 0.0

    d_rps, d_p99 = delta("rps"), delta("p99_ms")
    print("## Performance: head vs base\n")
    print("| Metric | Base | Head | Change |")
    print("|---|---|---|---|")
    print(f"| Requests/sec | {base['rps']:,.0f} | {head['rps']:,.0f} | {d_rps:+.1f}% |")
    print(f"| p99 latency (ms) | {base['p99_ms']:.3f} | {head['p99_ms']:.3f} | {d_p99:+.1f}% |")
    print(f"| Success rate | {base['success_rate']:.2%} | {head['success_rate']:.2%} | |")
    print()

    failed = False
    if head["success_rate"] < 1.0:
        print("❌ Head build returned failed requests.")
        failed = True
    if d_rps < -args.threshold:
        print(f"❌ Throughput dropped {-d_rps:.1f}% (allowed: {args.threshold:.0f}%).")
        failed = True
    if not failed:
        print(f"✅ Within the {args.threshold:.0f}% regression threshold.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
