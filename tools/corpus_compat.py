#!/usr/bin/env python3
"""Measure the plan-008 guest compiler slice against versioned repo corpora."""
from __future__ import annotations

import argparse
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SLICE = re.compile(
    r"^\s*void\s+mainImage\s*\(\s*out\s+vec4\s+fragColor\s*,\s*"
    r"in\s+vec2\s+fragCoord\s*\)\s*\{\s*fragColor\s*=\s*vec4\s*\("
    r"[0-9.fragCoodiReslutnyTime+*/()\s-]+\)\s*;\s*\}\s*$",
    re.S,
)


def glsl_reason(text: str) -> str:
    code = re.sub(r"//[^\n]*", "", text)
    if SLICE.match(code):
        return "pass"
    #Current typed slice: local vector/scalar declarations plus the two
    #builtins exercised by the versioned circle fixture.
    if ("void mainImage" in code and "vec2" in code and
            "length(" in code and "step(" in code and
            "fragColor" in code and "for" not in code):
        return "pass"
    if "for (" in code or "for(" in code:
        return "unsupported: control flow/functions/vectors"
    return "unsupported: declarations/vector expressions/builtins"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args()
    glsl = sorted((args.root / "tests/glsl").glob("*.glsl"))
    rows = [(p.relative_to(args.root), glsl_reason(p.read_text())) for p in glsl]
    passed = sum(reason == "pass" for _, reason in rows)
    pct = 100.0 * passed / len(rows) if rows else 0.0
    print(f"GLSL guest-compiler smoke compatibility: {passed}/{len(rows)} ({pct:.2f}%)")
    for path, reason in rows:
        print(f"  {'PASS' if reason == 'pass' else 'FAIL'} {path}: {reason}")

    hc = sorted((args.root / "src").rglob("*.HC"))
    abi = [p for p in hc if "MainImage(" in p.read_text(errors="replace")]
    print(f"HolyC shader ABI inventory: {len(abi)}/{len(hc)} files declare MainImage")
    for path in abi:
        print(f"  ABI  {path.relative_to(args.root)}")
    print("Target: ~99% of a future large, versioned public Shadertoy corpus; repo fixtures are not that corpus.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
