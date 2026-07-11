#!/usr/bin/env python3
"""Print 'WIDTH HEIGHT NCOLORS' for an image, via ffmpeg (no PIL needed).

Usage: imginfo.py FILE.png
"""
import json
import subprocess
import sys


def main():
    path = sys.argv[1]
    probe = json.loads(subprocess.check_output(
        ["ffprobe", "-v", "quiet", "-print_format", "json",
         "-show_streams", path]))
    st = probe["streams"][0]
    w, h = st["width"], st["height"]
    raw = subprocess.check_output(
        ["ffmpeg", "-v", "quiet", "-i", path,
         "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
    colors = {raw[i:i + 3] for i in range(0, len(raw), 3)}
    print(w, h, len(colors))


if __name__ == "__main__":
    main()
