"""Shared measurement harness for the Python binding benchmarks.

Per case: three timed model builds (first two disposed), RSS sampled
around the third build and after the solve, then one timed solve.
RSS is OS-level (psutil), sampled after gc.collect(); coarse but
comparable across runtimes.
"""

import gc
import json
import os
import time

import psutil


def rss_bytes():
    gc.collect()
    return psutil.Process().memory_info().rss


def run_case(results, binding, name, build, solve, dispose):
    # memory protocol: sample around the FIRST build (clean baseline, no
    # prior garbage pending release to the OS) and the solve; the two
    # extra timed builds happen afterwards and only feed the median
    rss_before_build = rss_bytes()
    t0 = time.perf_counter()
    handle = build()
    build_s = [round(time.perf_counter() - t0, 4)]
    rss_after_build = rss_bytes()

    t0 = time.perf_counter()
    out = solve(handle)
    solve_wall = round(time.perf_counter() - t0, 4)
    rss_after_solve = rss_bytes()
    dispose(handle)

    for _ in range(2):
        t0 = time.perf_counter()
        handle = build()
        build_s.append(round(time.perf_counter() - t0, 4))
        dispose(handle)
    handle = None

    row = {
        "binding": binding,
        "model": name,
        "build_s": build_s,
        "build_median_s": sorted(build_s)[1],
        "solve_wall_s": solve_wall,
        "solver_time_s": out.get("solver_time_s"),
        "objective": out["objective"],
        "status": out["status"],
        "build_rss_mb": round((rss_after_build - rss_before_build) / 1048576, 1),
        "solve_rss_mb": round((rss_after_solve - rss_after_build) / 1048576, 1),
    }
    results.append(row)
    print(
        f"{binding:9s} {name:10s} build {row['build_median_s']:8.3f}s  "
        f"solve {solve_wall:8.3f}s  obj {out['objective']:.6f}  {out['status']}"
    )


def write_results(results, binding):
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"{binding}.json")
    with open(path, "w") as f:
        json.dump(results, f, indent=2)
    print(f"wrote {path}")
