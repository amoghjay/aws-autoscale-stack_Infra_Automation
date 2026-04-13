#!/usr/bin/env python3
"""
Concurrent HTTP load generator for AWS auto-scaling demonstration.

Example:
    python3 load_test.py \
      --url http://<ALB>/items \
      --workers 200 \
      --duration 300 \
      --progress-interval 15 \
      --output evidence/load_test_results.json
"""

import argparse
import json
import math
import threading
import time
import urllib.error
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any


def percentile(sorted_values: list[float], pct: float) -> float:
    if not sorted_values:
        return 0.0
    if len(sorted_values) == 1:
        return sorted_values[0]
    rank = pct / 100 * (len(sorted_values) - 1)
    lower = math.floor(rank)
    upper = math.ceil(rank)
    if lower == upper:
        return sorted_values[lower]
    weight = rank - lower
    return sorted_values[lower] + (sorted_values[upper] - sorted_values[lower]) * weight


def summarize(snapshot: dict[str, Any]) -> dict[str, Any]:
    total_requests = snapshot["success"] + snapshot["errors"]
    latency_values = sorted(snapshot["latencies"])
    avg_latency = sum(latency_values) / len(latency_values) if latency_values else 0.0

    return {
        "requests": total_requests,
        "success": snapshot["success"],
        "errors": snapshot["errors"],
        "status_codes": dict(sorted(snapshot["status_codes"].items())),
        "exceptions": dict(sorted(snapshot["exceptions"].items())),
        "latency_ms": {
            "min": round(latency_values[0] * 1000, 2) if latency_values else 0.0,
            "avg": round(avg_latency * 1000, 2),
            "p95": round(percentile(latency_values, 95) * 1000, 2),
            "p99": round(percentile(latency_values, 99) * 1000, 2),
            "max": round(latency_values[-1] * 1000, 2) if latency_values else 0.0,
        },
    }


def print_summary(title: str, elapsed: float, snapshot: dict[str, Any]) -> None:
    summary = summarize(snapshot)
    req_per_sec = summary["requests"] / elapsed if elapsed > 0 else 0.0

    print(f"\n--- {title} ---")
    print(f"Elapsed:      {elapsed:.1f}s")
    print(f"Requests:     {summary['requests']}")
    print(f"Success:      {summary['success']}")
    print(f"Errors:       {summary['errors']}")
    print(f"Req/s:        {req_per_sec:.1f}")
    print(
        "Latency ms:   "
        f"min={summary['latency_ms']['min']:.2f} "
        f"avg={summary['latency_ms']['avg']:.2f} "
        f"p95={summary['latency_ms']['p95']:.2f} "
        f"p99={summary['latency_ms']['p99']:.2f} "
        f"max={summary['latency_ms']['max']:.2f}"
    )
    print(f"Status codes: {summary['status_codes'] or {'none': 0}}")
    if summary["exceptions"]:
        print(f"Exceptions:   {summary['exceptions']}")


def worker(
    url: str,
    timeout: float,
    stop_event: threading.Event,
    lock: threading.Lock,
    stats: dict[str, Any],
) -> None:
    while not stop_event.is_set():
        started = time.perf_counter()
        try:
            with urllib.request.urlopen(url, timeout=timeout) as resp:
                resp.read()
                status = getattr(resp, "status", 200)
                latency = time.perf_counter() - started
                with lock:
                    stats["success"] += 1
                    stats["status_codes"][str(status)] += 1
                    stats["latencies"].append(latency)
        except urllib.error.HTTPError as exc:
            latency = time.perf_counter() - started
            with lock:
                stats["errors"] += 1
                stats["status_codes"][str(exc.code)] += 1
                stats["latencies"].append(latency)
        except Exception as exc:
            with lock:
                stats["errors"] += 1
                stats["exceptions"][type(exc).__name__] += 1


def main() -> None:
    parser = argparse.ArgumentParser(description="HTTP load generator")
    parser.add_argument("--url", required=True, help="Target URL")
    parser.add_argument("--workers", type=int, default=50, help="Concurrent worker threads")
    parser.add_argument("--duration", type=int, default=120, help="Test duration in seconds")
    parser.add_argument("--timeout", type=float, default=5.0, help="Per-request timeout in seconds")
    parser.add_argument(
        "--progress-interval",
        type=int,
        default=15,
        help="Seconds between progress summaries (0 disables progress output)",
    )
    parser.add_argument(
        "--ramp-seconds",
        type=int,
        default=0,
        help="Optional time to spread worker startup over; 0 starts all workers immediately",
    )
    parser.add_argument("--output", help="Optional path to write JSON results")
    args = parser.parse_args()

    stop_event = threading.Event()
    lock = threading.Lock()
    stats: dict[str, Any] = {
        "success": 0,
        "errors": 0,
        "status_codes": Counter(),
        "exceptions": Counter(),
        "latencies": [],
    }

    print(
        f"Starting load test: {args.workers} workers -> {args.url} "
        f"for {args.duration}s (timeout={args.timeout}s)"
    )
    if args.ramp_seconds > 0:
        print(f"Ramp-up enabled: spreading worker startup over {args.ramp_seconds}s")

    start = time.time()
    last_progress = start
    previous_snapshot = {
        "success": 0,
        "errors": 0,
        "status_codes": Counter(),
        "exceptions": Counter(),
        "latencies": [],
    }

    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        futures = []
        for index in range(args.workers):
            futures.append(executor.submit(worker, args.url, args.timeout, stop_event, lock, stats))
            if args.ramp_seconds > 0 and index < args.workers - 1:
                time.sleep(args.ramp_seconds / args.workers)

        end_time = start + args.duration
        while time.time() < end_time:
            time.sleep(min(1, max(0.1, end_time - time.time())))
            now = time.time()
            if args.progress_interval > 0 and now - last_progress >= args.progress_interval:
                with lock:
                    current_snapshot = {
                        "success": stats["success"],
                        "errors": stats["errors"],
                        "status_codes": Counter(stats["status_codes"]),
                        "exceptions": Counter(stats["exceptions"]),
                        "latencies": list(stats["latencies"]),
                    }
                delta_snapshot = {
                    "success": current_snapshot["success"] - previous_snapshot["success"],
                    "errors": current_snapshot["errors"] - previous_snapshot["errors"],
                    "status_codes": current_snapshot["status_codes"] - previous_snapshot["status_codes"],
                    "exceptions": current_snapshot["exceptions"] - previous_snapshot["exceptions"],
                    "latencies": current_snapshot["latencies"][len(previous_snapshot["latencies"]):],
                }
                print_summary("Progress", now - last_progress, delta_snapshot)
                previous_snapshot = current_snapshot
                last_progress = now

        stop_event.set()
        for future in as_completed(futures):
            future.result()

    elapsed = time.time() - start
    final_summary = summarize(stats)
    print_summary("Final Results", elapsed, stats)

    if args.output:
        payload = {
            "url": args.url,
            "workers": args.workers,
            "duration_seconds": args.duration,
            "timeout_seconds": args.timeout,
            "ramp_seconds": args.ramp_seconds,
            "elapsed_seconds": round(elapsed, 2),
            "summary": final_summary,
            "generated_at_epoch": int(time.time()),
        }
        with open(args.output, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2)
        print(f"\nSaved JSON results to {args.output}")


if __name__ == "__main__":
    main()
