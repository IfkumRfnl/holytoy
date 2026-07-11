#!/usr/bin/env python3
"""Strip DolDoc $...$ control codes from TempleOS .DD files, leaving readable text.

Usage: strip_doldoc.py FILE.DD [FILE2.DD ...]   (or stdin -> stdout)

DolDoc syntax: control codes are delimited by '$' (e.g. $FG,2$, $LK,"text",A="FI:..."$).
A literal dollar sign is written '$$'. For LK (link) and TX (text) codes we keep the
first quoted string; every other code is dropped.
"""
import re
import sys


def strip(text: str) -> str:
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c != "$":
            out.append(c)
            i += 1
            continue
        if i + 1 < n and text[i + 1] == "$":  # escaped literal $
            out.append("$")
            i += 2
            continue
        # find closing unescaped $
        j = i + 1
        while j < n and text[j] != "$":
            j += 1
        cmd = text[i + 1 : j]
        # keep the display text of links and TX codes
        if re.match(r"(LK|TX)[-+A-Z]*\b", cmd):
            m = re.search(r'"((?:[^"\\]|\\.)*)"', cmd)
            if m:
                out.append(m.group(1))
        i = j + 1
    return "".join(out)


def main() -> None:
    if len(sys.argv) > 1:
        for path in sys.argv[1:]:
            with open(path, encoding="latin-1") as f:
                sys.stdout.write(strip(f.read()))
    else:
        sys.stdout.write(strip(sys.stdin.read()))


if __name__ == "__main__":
    main()
