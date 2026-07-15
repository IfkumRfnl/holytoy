#!/usr/bin/env python3
"""Turn HT CORPUS guest.log markers into the staged compatibility report.

Stages per shader, in order: compile (in-guest GLSL->HolyC), install
(TempleOS compiled the generated HolyC), exec (four sample pixels returned
finite RGBA). The headline number is exec%, reported separately from visual
correctness, performance, and harness health per AGENTS.md. The extra
`visual` column is only the guest-side dump marker (HtVisualDump wrote both
state DATs); the actual oracle verdict comes from tools/visual_compare.py.

CORPUS.TXT lines are `Sxx <shader_id> [<stratum>]`; when strata are present
the stage percentages are grouped per stratum AND overall, so an
expected-failing stratum never blurs another stratum's number.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

MARKER = re.compile(
    r"HT CORPUS (\S+) (compile|install|exec|read|visual) (OK|ERR)[ \t]*([^\r\n]*)")
DONE = re.compile(r"HT CORPUS DONE (\d+)/(\d+)")

STAGES = ("compile", "install", "exec")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("guest_log", type=Path)
    parser.add_argument("--manifest", type=Path, default=None)
    args = parser.parse_args()

    order: list[str] = []
    strata: dict[str, str] = {}
    if args.manifest and args.manifest.exists():
        for line in args.manifest.read_text().splitlines():
            parts = line.split()
            if len(parts) >= 2:
                order.append(parts[1])
                if len(parts) >= 3:
                    strata[parts[1]] = parts[2]

    text = args.guest_log.read_text(errors="replace")
    results: dict[str, dict[str, tuple[bool, str]]] = {}
    for sid, stage, status, detail in MARKER.findall(text):
        results.setdefault(sid, {})[stage] = (status == "OK", detail.strip())

    ids = order or sorted(results)
    if not ids:
        print("corpus_report: no HT CORPUS markers found", file=sys.stderr)
        return 2

    counts: dict[str, dict[str, int]] = {}
    totals: dict[str, int] = {}
    print(f"{'shader':10} {'compile':8} {'install':8} {'exec':10} "
          f"{'visual':8} note")
    for sid in ids:
        group = strata.get(sid, "")
        totals[group] = totals.get(group, 0) + 1
        counts.setdefault(group, dict.fromkeys(STAGES, 0))
        r = results.get(sid, {})
        cols = []
        note = ""
        for stage in STAGES:
            ok, detail = r.get(stage, (False, ""))
            if ok:
                counts[group][stage] += 1
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
        if "visual" in r:
            vis = "OK" if r["visual"][0] else "ERR"
        else:
            vis = "-"
        print(f"{sid:10} {cols[0]:8} {cols[1]:8} {cols[2]:10} {vis:8} {note}")

    n = len(ids)
    print()
    groups = sorted(totals)
    for stage in STAGES:
        total_ok = sum(counts[g][stage] for g in groups)
        pct = 100.0 * total_ok / n if n else 0.0
        line = f"{stage:8} {total_ok:2d}/{n} ({pct:.1f}%)"
        if len(groups) > 1 or (groups and groups[0]):
            per = "  ".join(
                f"[{g or 'unlabeled'}] {counts[g][stage]}/{totals[g]}"
                for g in groups)
            line += f"   {per}"
        print(line)
    m = DONE.search(text)
    if m:
        print(f"guest DONE line: {m.group(1)}/{m.group(2)}")
    else:
        print("WARNING: no 'HT CORPUS DONE' line - the batch run may have been cut off")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
