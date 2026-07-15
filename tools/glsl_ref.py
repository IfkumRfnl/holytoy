#!/usr/bin/env python3
"""Render reference sample DATs for the visual-correctness oracle (plan 010).

For each corpus shader this renders the SAME prepped bytes the guest
compiles (tools/glsl_prep.py transform) with a desktop OpenGL context at
80x36 -- one pixel per 8x8 viewport block, fragCoord = gl_FragCoord.xy*8.0
so every sample lands on the guest's block centers (8x+4, 8y+4) -- and
writes headerless 8640-byte DATs: rows top-down, 3 bytes R,G,B per sample,
value = round(clamp(v,0,1)*255).

Two fixed uniform states (must match HtVisualDump in src/holytoy/HT.HC):
  A: iTime=0.5, iFrame=15      B: iTime=8.0, iFrame=240
  both: iMouse=vec4(0), iDate=vec4(2026,1,1,0), iResolution=(640,288,1)
iDate.y/.z use the GUEST's values (month 1-based) so the recorded
deviation cancels out.

References are committed under tests/corpus-visual/; GL is needed only to
REgenerate them, never to run make test or corpus batches.

Usage:
  glsl_ref.py --corpus corpus/shadertoy/v1/shaders --out tests/corpus-visual/refs-v1
  glsl_ref.py --src tests/glsl/gradient.glsl --id gradient --out DIR
  glsl_ref.py ... --only-stratum single_no_channels   (needs manifest.jsonl)
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from glsl_prep import prep_bytes  # noqa: E402

W, H = 80, 36
STATES = {"A": (0.5, 15), "B": (8.0, 240)}

PROLOGUE = """#version 330 core
out vec4 ht_out_color;
const vec3 iResolution = vec3(640.0, 288.0, 1.0);
uniform float iTime;
uniform int iFrame;
uniform vec4 iMouse;
uniform vec4 iDate;
uniform float iTimeDelta;
uniform float iFrameRate;
#line 1
"""

EPILOGUE = """
void main() {
  vec4 ht_c = vec4(0.0);
  mainImage(ht_c, gl_FragCoord.xy * 8.0);
  ht_out_color = ht_c;
}
"""

VERT = """#version 330 core
const vec2 verts[3] = vec2[3](vec2(-1.,-1.), vec2(3.,-1.), vec2(-1.,3.));
void main() { gl_Position = vec4(verts[gl_VertexID], 0., 1.); }
"""


def make_context():
    import moderngl
    try:
        return moderngl.create_standalone_context()
    except Exception as first:
        try:
            return moderngl.create_standalone_context(backend="egl")
        except Exception as second:
            raise SystemExit(
                f"glsl_ref: no GL context (default: {first}; egl: {second})")


def render_states(ctx, glsl_text: str, sid: str, out_dir: Path) -> bool:
    frag = PROLOGUE + glsl_text + EPILOGUE
    try:
        prog = ctx.program(vertex_shader=VERT, fragment_shader=frag)
    except Exception as e:
        print(f"glsl_ref: {sid}: fragment compile/link failed: {e}",
              file=sys.stderr)
        return False
    vao = ctx.vertex_array(prog, [])
    fbo = ctx.framebuffer(color_attachments=[ctx.renderbuffer((W, H))])
    fbo.use()
    ctx.viewport = (0, 0, W, H)
    ok = True
    for state, (itime, iframe) in STATES.items():
        for name, val in (("iTime", itime), ("iFrame", iframe),
                          ("iMouse", (0.0, 0.0, 0.0, 0.0)),
                          ("iDate", (2026.0, 1.0, 1.0, 0.0)),
                          ("iTimeDelta", 1.0 / 30.0), ("iFrameRate", 30.0)):
            if name in prog:
                prog[name].value = val
        fbo.clear(0.0, 0.0, 0.0, 0.0)
        vao.render(mode=4, vertices=3)  # TRIANGLES
        raw = fbo.read(components=3, dtype="f1")  # rows bottom-up
        rows = [raw[j * W * 3:(j + 1) * W * 3] for j in range(H)]
        dat = b"".join(reversed(rows))  # DAT is top-down
        if len(dat) != W * H * 3:
            print(f"glsl_ref: {sid}: bad readback size {len(dat)}",
                  file=sys.stderr)
            ok = False
            continue
        (out_dir / f"{sid}-{state}.dat").write_bytes(dat)
    vao.release()
    fbo.release()
    prog.release()
    return ok


def load_strata(corpus: Path) -> dict[str, str]:
    manifest = corpus.parent / "manifest.jsonl"
    strata: dict[str, str] = {}
    if manifest.exists():
        for line in manifest.read_text().splitlines():
            if line.strip():
                obj = json.loads(line)
                strata[obj["shader_id"]] = (
                    obj.get("coverage", {}).get("primary_stratum", ""))
    return strata


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path,
                        help="corpus shaders dir (<id>/image.glsl)")
    parser.add_argument("--src", type=Path, help="single .glsl file")
    parser.add_argument("--id", dest="sid", default=None,
                        help="reference id for --src (default: stem)")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--only-stratum", default=None,
                        help="filter by manifest.jsonl stratum")
    args = parser.parse_args()
    if bool(args.corpus) == bool(args.src):
        parser.error("exactly one of --corpus / --src")

    jobs: list[tuple[str, str]] = []
    if args.src:
        text = prep_bytes(args.src.read_bytes()).decode("ascii")
        jobs.append((args.sid or args.src.stem, text))
    else:
        strata = load_strata(args.corpus)
        for d in sorted(p for p in args.corpus.iterdir() if p.is_dir()):
            if args.only_stratum and strata.get(d.name) != args.only_stratum:
                continue
            text = prep_bytes((d / "image.glsl").read_bytes()).decode("ascii")
            jobs.append((d.name, text))
    if not jobs:
        raise SystemExit("glsl_ref: nothing to render")

    args.out.mkdir(parents=True, exist_ok=True)
    ctx = make_context()
    print(f"glsl_ref: GL {ctx.info['GL_RENDERER']} / "
          f"{ctx.info['GL_VERSION']}", file=sys.stderr)
    failed = []
    for sid, text in jobs:
        if not render_states(ctx, text, sid, args.out):
            failed.append(sid)
    n_ok = len(jobs) - len(failed)
    print(f"glsl_ref: wrote {2 * n_ok} DATs for {n_ok}/{len(jobs)} shaders "
          f"to {args.out}")
    if failed:
        print(f"glsl_ref: FAILED: {' '.join(failed)}", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
