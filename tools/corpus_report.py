#!/usr/bin/env python3
"""Turn HT CORPUS guest.log markers into the staged compatibility report.

Stages per shader, in order: compile (in-guest GLSL->HolyC), install
(TempleOS compiled the generated HolyC), exec (four sample pixels returned
finite RGBA). The headline number is exec%, reported separately from visual
correctness, performance, and harness health per AGENTS.md.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

MARKER = re.compile(r"HT CORPUS (\S+) (compile|install|exec|read) (OK|ERR)\s*(.*)")
DONE = re.compile(r"HT CORPUS DONE (\d+)/(\d+)")

STAGES = ("compile", "install", "exec")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("guest_log", type=Path)
    parser.add_argument("--manifest", type=Path, default=None)
    args = parser.parse_args()

    order: list[str] = []
    if args.manifest and args.manifest.exists():
        for line in args.manifest.read_text().splitlines():
            parts = line.split()
            if len(parts) == 2:
                order.append(parts[1])

    text = args.guest_log.read_text(errors="replace")
    results: dict[str, dict[str, tuple[bool, str]]] = {}
    for sid, stage, status, detail in MARKER.findall(text):
        results.setdefault(sid, {})[stage] = (status == "OK", detail.strip())

    ids = order or sorted(results)
    if not ids:
        print("corpus_report: no HT CORPUS markers found", file=sys.stderr)
        return 2

    counts = dict.fromkeys(STAGES, 0)
    print(f"{'shader':10} {'compile':8} {'install':8} {'exec':10} note")
    for sid in ids:
        r = results.get(sid, {})
        cols = []
        note = ""
        for stage in STAGES:
            ok, detail = r.get(stage, (False, ""))
            if ok:
                counts[stage] += 1
                cols.append("OK" + (f" {detail}" if stage == "exec" and detail else ""))
            else:
                cols.append("-" if stage not in r else "ERR")
                if stage in r and detail and not note:
                    note = detail
                if stage not in r and not note and "read" in r:
                    note = "unreadable"
                break
        while len(cols) < len(STAGES):
            cols.append("-")
        print(f"{sid:10} {cols[0]:8} {cols[1]:8} {cols[2]:10} {note}")

    n = len(ids)
    print()
    for stage in STAGES:
        pct = 100.0 * counts[stage] / n if n else 0.0
        print(f"{stage:8} {counts[stage]:2d}/{n} ({pct:.1f}%)")
    m = DONE.search(text)
    if m:
        print(f"guest DONE line: {m.group(1)}/{m.group(2)}")
    else:
        print("WARNING: no 'HT CORPUS DONE' line - the batch run may have been cut off")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
