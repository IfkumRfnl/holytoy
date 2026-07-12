#!/usr/bin/env python3
"""Print image dimensions and distinct RGB colors via ffmpeg (no PIL).

Usage: imginfo.py FILE.png [--crop X,Y,WxH] [--hash]
"""
import argparse
import hashlib
import json
import subprocess


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--crop", metavar="X,Y,WxH")
    ap.add_argument("--hash", action="store_true", dest="show_hash")
    args = ap.parse_args()
    path = args.path
    probe = json.loads(subprocess.check_output(
        ["ffprobe", "-v", "quiet", "-print_format", "json",
         "-show_streams", path]))
    st = probe["streams"][0]
    w, h = st["width"], st["height"]
    raw = subprocess.check_output(
        ["ffmpeg", "-v", "quiet", "-i", path,
         "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
    if args.crop:
        try:
            origin = args.crop.split(",", 2)
            if len(origin) != 3:
                raise ValueError
            x, y = int(origin[0]), int(origin[1])
            cw, ch = (int(v) for v in origin[2].lower().split("x", 1))
        except (ValueError, TypeError):
            ap.error("--crop must have the form X,Y,WxH")
        if x < 0 or y < 0 or cw <= 0 or ch <= 0 or x + cw > w or y + ch > h:
            ap.error("--crop lies outside the image")
        stride = w * 3
        raw = b"".join(raw[row * stride + x * 3:
                           row * stride + (x + cw) * 3]
                       for row in range(y, y + ch))
        w, h = cw, ch
    colors = {raw[i:i + 3] for i in range(0, len(raw), 3)}
    fields = [str(w), str(h), str(len(colors))]
    if args.show_hash:
        fields.append(hashlib.md5(raw).hexdigest())
    print(" ".join(fields))


if __name__ == "__main__":
    main()
