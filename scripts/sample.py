#!/usr/bin/env python3
"""Samples one app's CPU and wakeups on a physical iPhone through Instruments' sysmontap service.

    uvx --python 3.13 --with pymobiledevice3==11.26.0 python -I scripts/sample.py \
        --udid <UDID> --bundle <bundle id> --seconds 60 --label read-fg-1 --out out/

No Xcode UI, no root and no tunnel daemon: pymobiledevice3 opens a userspace tunnel to the
device's developer services (iOS 17+), the same ones Xcode's CPU gauge reads.

CPU % is a share of one core (100 = one core busy), computed from the process's cumulative CPU time
at the first and last 1 Hz snapshot, which is exact where a single snapshot is noisy. Wakeups/s is
the delta of the kernel's interrupt-wakeup counter for the process over the same window, the
number Xcode's energy gauge and `powermetrics` call "wakeups".

Writes <out>/<label>.json and prints the same summary.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
from pathlib import Path
from typing import Any

from pymobiledevice3.remote.userspace_tunnel import establish_userspace_rsd
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl
from pymobiledevice3.services.dvt.instruments.sysmontap import Sysmontap

FIELDS = ("pid", "name", "cpuTotalUser", "cpuTotalSystem", "intWakeups", "ctxSwitch", "threadCount")


def rate(points: list[tuple[float, float]], scale: float = 1.0) -> float | None:
    if len(points) < 2 or points[-1][0] <= points[0][0]:
        return None
    (t0, v0), (t1, v1) = points[0], points[-1]
    return round(scale * (v1 - v0) / (t1 - t0), 3)


async def sample(args: argparse.Namespace) -> int:
    rsd = await establish_userspace_rsd(serial=args.udid, remotepairing_fallback=False)
    async with DvtProvider(rsd) as dvt:
        async with ProcessControl(dvt) as control:
            pid = await control.process_identifier_for_bundle_identifier(args.bundle)
        if not pid or pid <= 0:
            print(f"{args.bundle} is not running", file=sys.stderr)
            return 3
        records: list[dict[str, Any]] = []

        async def collect() -> None:
            async with await Sysmontap.create(dvt, interval=1000) as sysmon:
                async for snapshot in sysmon.iter_processes():
                    now = time.time()
                    for proc in snapshot:
                        if proc.get("pid") == pid:
                            record = {k: proc.get(k) for k in FIELDS}
                            record["t"] = now
                            records.append(record)

        started = time.time()
        task = asyncio.create_task(collect())
        done, _ = await asyncio.wait({task}, timeout=args.seconds)
        if done and task.exception():
            print(f"sysmontap failed: {task.exception()!r}", file=sys.stderr)
            return 4
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)

    cpu = [(r["t"], (r["cpuTotalUser"] or 0) + (r["cpuTotalSystem"] or 0)) for r in records
           if r.get("cpuTotalUser") is not None]
    summary = {
        "label": args.label,
        "notes": args.notes,
        "bundle": args.bundle,
        "pid": pid,
        "window_s": round(records[-1]["t"] - records[0]["t"], 1) if len(records) > 1 else 0,
        "wall_s": round(time.time() - started, 1),
        "snapshots": len(records),
        "cpu_pct": rate(cpu, scale=100.0 / 1e9),
        "wakeups_per_s": rate([(r["t"], r["intWakeups"]) for r in records if r.get("intWakeups") is not None]),
        "ctx_switches_per_s": rate([(r["t"], r["ctxSwitch"]) for r in records if r.get("ctxSwitch") is not None]),
        "threads": records[-1].get("threadCount") if records else None,
    }
    if summary["cpu_pct"] is None:
        print("too few snapshots for a rate", file=sys.stderr)
        return 5
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / f"{args.label}.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--seconds", type=float, default=60)
    parser.add_argument("--label", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--notes", default="")
    return asyncio.run(sample(parser.parse_args()))


if __name__ == "__main__":
    sys.exit(main())
