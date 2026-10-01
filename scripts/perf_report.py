#!/usr/bin/env python3
"""Turn perf_run.py results into a readable markdown report and a verdict.

Usage:
  scripts/perf_report.py results.json --pr pr --base dev [--threshold 15] \
      [--out report.md]

Exit status 1 if the PR build is slower than --base by more than the
threshold in some scenario, beyond the run-to-run noise.
"""

import argparse
import json
import statistics
import sys

MARKER = "<!-- mojelly-perf-report -->"

# metric key, title, format, better direction (+1 higher is better, -1 lower)
METRICS = [
    ("rps", "Requests/s", "{:,.0f}", +1),
    ("p99_ms", "p99 latency (ms)", "{:.3f}", -1),
    ("cpu_us_per_req", "Server CPU per request (µs)", "{:.2f}", -1),
]


def summarize(runs, build, scenario, key):
    vals = [r[key] for r in runs if r["build"] == build and r["scenario"] == scenario]
    if not vals:
        return None
    med = statistics.median(vals)
    spread = (max(vals) - min(vals)) / med if med else 0.0  # relative range
    return {"median": med, "spread": spread, "n": len(vals)}


def delta_pct(new, old):
    return (new - old) / old * 100 if old else 0.0


def judge(new, old, better, thr, noise_floor=0.02):
    """Return (delta %, label) for `new` against `old` on one metric."""
    d = delta_pct(new["median"], old["median"])
    noise = max(new["spread"], old["spread"], noise_floor) * 100
    good = d * better > 0  # moved in the favourable direction
    if abs(d) <= noise:
        return d, "within noise"
    if good:
        return d, "better"
    return d, "regression" if abs(d) > thr else "worse"


def fmt_delta(d, label):
    icon = {"better": "🟢", "regression": "🔴", "worse": "🟠", "within noise": "⚪"}[label]
    return f"{icon} {d:+.1f}%"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results")
    ap.add_argument("--pr", default="pr", help="label of the PR build")
    ap.add_argument("--base", default="dev", help="label the PR is gated against")
    ap.add_argument("--threshold", type=float, default=15.0)
    ap.add_argument("--out", default="")
    args = ap.parse_args()

    data = json.load(open(args.results))
    meta, runs = data["meta"], data["runs"]
    labels = [b["label"] for b in meta["builds"]]
    pretty = {"main": "main", "dev": "dev", args.pr: "PR"}
    others = [l for l in labels if l != args.pr]

    out = [MARKER, "## 🏎️ Performance: " + " vs ".join(pretty.get(l, l) for l in labels), ""]
    out.append("Three builds of the server are benchmarked **one after another on the same "
               "runner** with the same load generator; only the ratios between them mean "
               "anything, never the absolute numbers.\n")
    out.append("| Build | Commit | Title |")
    out.append("|---|---|---|")
    for b in meta["builds"]:
        title = (b["subject"] or "").replace("|", "\\|")
        out.append(f"| **{pretty.get(b['label'], b['label'])}** | `{b['sha']}` | {title} |")
    out.append("")
    out.append(f"**Setup:** {meta['cpus']} CPUs on the runner "
               f"(server on CPUs `{meta['server_cpus'] or 'any'}`, load generator on "
               f"`{meta['client_cpus'] or 'any'}`), `{meta['oha']}`, "
               f"{meta['reps']} repetitions per build and scenario "
               f"({meta['duration_s']} s measured after {meta['warmup_s']} s warm-up), "
               f"builds interleaved, **median** reported.\n")

    failures = []
    verdicts = []
    for sc in meta["scenarios"]:
        name = sc["name"]
        out.append(f"### {name}: {sc['description']}\n")
        head = ["Metric"] + [f"{pretty.get(l, l)}" for l in labels]
        head += [f"PR vs {pretty.get(o, o)}" for o in others]
        out.append("| " + " | ".join(head) + " |")
        out.append("|" + "---|" * len(head))
        gate_result = "ok"
        for key, title, fmt, better in METRICS:
            sums = {l: summarize(runs, l, name, key) for l in labels}
            if any(v is None for v in sums.values()):
                continue
            row = [title]
            for l in labels:
                s = sums[l]
                row.append(f"{fmt.format(s['median'])} <sub>±{s['spread'] * 50:.1f}%</sub>")
            for o in others:
                d, label = judge(sums[args.pr], sums[o], better, args.threshold)
                row.append(fmt_delta(d, label))
                if o == args.base and label == "regression" and key != "p99_ms":
                    failures.append(f"{name}: {title} {d:+.1f}% vs {pretty.get(o, o)}")
                    gate_result = "regression"
                elif o == args.base and label == "better" and gate_result == "ok":
                    gate_result = "faster"
            out.append("| " + " | ".join(row) + " |")
        ok_ratios = [r["ok_ratio"] for r in runs if r["scenario"] == name]
        if ok_ratios and min(ok_ratios) < 1.0:
            failures.append(f"{name}: some requests did not get a 200 "
                            f"(lowest success ratio {min(ok_ratios):.2%})")
            gate_result = "regression"
        verdicts.append((name, gate_result))
        out.append("")

    out.append("<sub>±x% = half of the spread between the fastest and slowest repetition; a change counts only if it is larger than the full spread of the two builds (at least 2%). "
               "🟢 better · ⚪ within noise · 🟠 worse but under the threshold · "
               f"🔴 slower by more than {args.threshold:.0f}% and beyond noise. "
               "p99 is shown but not gated: it is the noisiest metric on a shared runner.</sub>\n")

    if failures:
        out.append(f"### ❌ Regression against {pretty.get(args.base, args.base)}\n")
        out.extend(f"- {f}" for f in failures)
    else:
        faster = [n for n, v in verdicts if v == "faster"]
        msg = f"### ✅ No regression against {pretty.get(args.base, args.base)}"
        if faster:
            msg += f" (faster in: {', '.join(faster)})"
        out.append(msg)
    text = "\n".join(out) + "\n"

    print(text)
    if args.out:
        open(args.out, "w").write(text)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
