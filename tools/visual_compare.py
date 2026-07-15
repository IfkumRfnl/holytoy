#!/usr/bin/env python3
"""Compare guest visual-dump DATs against committed reference DATs (plan 010).

DAT format (both sides): headerless 8640 bytes = 36 rows top-down x 80
samples x 3 bytes R,G,B. Dumps come off the transfer disk as V<nn><A|B>.DAT
(ordinal <nn> maps through CORPUS.TXT, V00 = single-shader mode) or as
already-renamed <id>-<A|B>.DAT; references are <id>-<A|B>.dat.

Metric (the contract from plans/010): a sample passes when
max(|dR|,|dG|,|dB|) <= 16 (of 255); a state passes when >= 90% of its 2880
samples pass; a shader is `visual OK` when both states pass. The numbers
are the deliverable -- the threshold is just the summary line. Never loosen
the tolerance to make a shader pass.

Exit 0 when every shader with BOTH dump and reference present passes;
missing references report `no-ref` and do not affect the exit code.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

SAMPLES = 80 * 36
DAT_BYTES = SAMPLES * 3
TOL = 16
PCT_PASS = 90.0
STATES = ("A", "B")
DUMP_ORDINAL = re.compile(r"^V(\d{2,})([AB])\.DAT$", re.IGNORECASE)
DUMP_NAMED = re.compile(r"^(.+)-([AB])\.DAT$", re.IGNORECASE)


def read_manifest(path: Path) -> tuple[dict[int, str], dict[str, str]]:
    """CORPUS.TXT lines: 'Sxx <shader_id> [<stratum>]'."""
    order: dict[int, str] = {}
    strata: dict[str, str] = {}
    for line in path.read_text().splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0][:1] in "Ss":
            try:
                ordinal = int(parts[0][1:])
            except ValueError:
                continue
            order[ordinal] = parts[1]
            if len(parts) >= 3:
                strata[parts[1]] = parts[2]
    return order, strata


def compare(dump: bytes, ref: bytes) -> tuple[float, int, float]:
    """Return (meanerr, maxerr, pct_within) over per-sample max-channel err."""
    total = 0
    worst = 0
    within = 0
    for i in range(0, DAT_BYTES, 3):
        err = max(abs(dump[i] - ref[i]),
                  abs(dump[i + 1] - ref[i + 1]),
                  abs(dump[i + 2] - ref[i + 2]))
        total += err
        if err > worst:
            worst = err
        if err <= TOL:
            within += 1
    return total / SAMPLES, worst, 100.0 * within / SAMPLES


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dumps", type=Path, required=True)
    parser.add_argument("--refs", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, default=None)
    args = parser.parse_args()

    order: dict[int, str] = {}
    strata: dict[str, str] = {}
    if args.manifest and args.manifest.exists():
        order, strata = read_manifest(args.manifest)

    # shader_id -> {state: dump_path}
    dumps: dict[str, dict[str, Path]] = {}
    problems = []
    for p in sorted(args.dumps.iterdir()):
        m = DUMP_ORDINAL.match(p.name)
        if m:
            ordinal, state = int(m.group(1)), m.group(2).upper()
            sid = order.get(ordinal)
            if sid is None:
                problems.append(f"{p.name}: ordinal {ordinal} not in manifest")
                continue
            dumps.setdefault(sid, {})[state] = p
            continue
        m = DUMP_NAMED.match(p.name)
        if m:
            dumps.setdefault(m.group(1), {})[m.group(2).upper()] = p
    if not dumps:
        print(f"visual_compare: no dumps under {args.dumps}", file=sys.stderr)
        return 2

    ids = [sid for sid in order.values() if sid in dumps] if order else []
    ids += sorted(sid for sid in dumps if sid not in ids)

    passed = 0
    compared = 0
    failed = []
    per_stratum: dict[str, list[int]] = {}
    print(f"{'shader':10} "
          f"{'meanA':>7} {'maxA':>4} {'pctA':>6}  "
          f"{'meanB':>7} {'maxB':>4} {'pctB':>6}  visual")
    for sid in ids:
        cols = []
        state_ok = []
        for state in STATES:
            dump_p = dumps[sid].get(state)
            ref_p = args.refs / f"{sid}-{state}.dat"
            if dump_p is None or not ref_p.exists():
                cols.append(f"{'-':>7} {'-':>4} {'-':>6}")
                state_ok.append(None if not ref_p.exists() else False)
                if dump_p is None and ref_p.exists():
                    problems.append(f"{sid}: missing dump for state {state}")
                continue
            dump = dump_p.read_bytes()
            ref = ref_p.read_bytes()
            if len(dump) != DAT_BYTES or len(ref) != DAT_BYTES:
                problems.append(f"{sid}-{state}: bad size "
                                f"dump={len(dump)} ref={len(ref)}")
                cols.append(f"{'size!':>7} {'-':>4} {'-':>6}")
                state_ok.append(False)
                continue
            mean, worst, pct = compare(dump, ref)
            cols.append(f"{mean:7.2f} {worst:4d} {pct:6.1f}")
            state_ok.append(pct >= PCT_PASS)
        if state_ok and all(s is None for s in state_ok):
            verdict = "no-ref"
        elif all(s is True for s in state_ok):
            verdict = "OK"
            compared += 1
            passed += 1
        else:
            verdict = "FAIL"
            compared += 1
            failed.append(sid)
        print(f"{sid:10} {cols[0]}  {cols[1]}  {verdict}")
        if verdict != "no-ref" and strata:
            per_stratum.setdefault(strata.get(sid, "?"), []).append(
                1 if verdict == "OK" else 0)

    print()
    if per_stratum:
        for name in sorted(per_stratum):
            r = per_stratum[name]
            print(f"visual [{name}]: {sum(r)}/{len(r)} within tolerance")
    print(f"visual {passed}/{compared} within tolerance "
          f"(tol {TOL}/255, >={PCT_PASS:.0f}% samples, both states)")
    for msg in problems:
        print(f"visual_compare: WARNING: {msg}", file=sys.stderr)
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
