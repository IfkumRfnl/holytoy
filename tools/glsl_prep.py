#!/usr/bin/env python3
"""Prepare deterministic guest-safe copies of corpus GLSL passes.

TempleOS uses its own 8-bit charset: a UTF-8 BOM or multi-byte sequence
arrives in the guest as mojibake and breaks compilation. This tool derives
transfer copies from the authoritative corpus without touching the
originals:

  * strip one leading UTF-8 BOM if present;
  * replace every byte >= 0x80 with '?' (corpus policy keeps non-ASCII
    bytes only inside comments, so shader semantics are unaffected);
  * normalize CRLF to LF.

The mapping is deterministic: shaders are numbered S01..Snn in sorted
shader-id order, and CORPUS.TXT lists "Sxx <shader_id>" one per line.
"""
from __future__ import annotations

import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / "corpus/shadertoy/v1/shaders"


def prep_bytes(raw: bytes) -> bytes:
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    raw = raw.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
    return bytes(b if b < 0x80 else ord("?") for b in raw)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=CORPUS)
    parser.add_argument("--dest", type=Path,
                        default=ROOT / "out/corpus-guest")
    args = parser.parse_args()

    shader_ids = sorted(p.name for p in args.corpus.iterdir() if p.is_dir())
    if not shader_ids:
        raise SystemExit(f"glsl_prep: no shaders under {args.corpus}")
    args.dest.mkdir(parents=True, exist_ok=True)

    manifest_lines = []
    for i, sid in enumerate(shader_ids, start=1):
        src = args.corpus / sid / "image.glsl"
        name = f"S{i:02d}"
        (args.dest / f"{name}.GLS").write_bytes(prep_bytes(src.read_bytes()))
        manifest_lines.append(f"{name} {sid}")
    (args.dest / "CORPUS.TXT").write_text("\n".join(manifest_lines) + "\n")
    print(f"glsl_prep: wrote {len(shader_ids)} guest-safe shaders to {args.dest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
