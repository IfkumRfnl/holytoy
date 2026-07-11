#!/usr/bin/env python3
"""Minimal QMP client for driving the holytoy QEMU VM.

Usage:
  qmp.py SOCKET screendump OUT.png          # PNG screendump (QEMU >= 7.1)
  qmp.py SOCKET keys KEY [KEY ...]          # raw qcodes, e.g. ret y spc kp_enter
  qmp.py SOCKET type "text..."              # type a string (US layout, \n = Enter)
  qmp.py SOCKET typefile FILE               # type an entire file's contents
  qmp.py SOCKET quit                        # terminate QEMU immediately
  qmp.py SOCKET reset                       # system_reset
  qmp.py SOCKET mouse-rel DX DY             # relative move, raw PS/2 counts
  qmp.py SOCKET mouse-btn left|right down|up
  qmp.py SOCKET mouse-to X Y                # slam to top-left, land on pixel

Options (env): QMP_KEY_DELAY (s between keystrokes, default 0.04),
QMP_MOUSE_COUNTS_PER_PX (mouse-to counts per screen pixel, default 2)
Exit codes: 0 ok, 1 command failed, 2 cannot connect.
"""
import json
import os
import socket
import sys
import time

KEY_DELAY = float(os.environ.get("QMP_KEY_DELAY", "0.04"))

PLAIN = {
    " ": "spc", "\n": "ret", "\t": "tab",
    "-": "minus", "=": "equal", "[": "bracket_left", "]": "bracket_right",
    ";": "semicolon", "'": "apostrophe", "`": "grave_accent",
    "\\": "backslash", ",": "comma", ".": "dot", "/": "slash",
}
SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6",
    "&": "7", "*": "8", "(": "9", ")": "0",
    "_": "minus", "+": "equal", "{": "bracket_left", "}": "bracket_right",
    ":": "semicolon", '"': "apostrophe", "~": "grave_accent",
    "|": "backslash", "<": "comma", ">": "dot", "?": "slash",
}


class QMP:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(15)
        self.sock.connect(path)
        self.buf = b""
        self._read_msg()  # greeting
        self.cmd("qmp_capabilities")

    def _read_msg(self):
        while True:
            nl = self.buf.find(b"\n")
            if nl >= 0:
                line, self.buf = self.buf[:nl], self.buf[nl + 1:]
                if line.strip():
                    return json.loads(line)
                continue
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("QMP socket closed")
            self.buf += chunk

    def cmd(self, name, **args):
        req = {"execute": name}
        if args:
            req["arguments"] = args
        self.sock.sendall(json.dumps(req).encode() + b"\n")
        while True:
            msg = self._read_msg()
            if "return" in msg:
                return msg["return"]
            if "error" in msg:
                raise RuntimeError(f"{name}: {msg['error']}")
            # else: async event — ignore

    def send_keys(self, qcodes, hold=None):
        keys = [{"type": "qcode", "data": k} for k in qcodes]
        args = {"keys": keys}
        if hold:
            args["hold-time"] = hold
        self.cmd("send-key", **args)

    def type_char(self, ch):
        if ch in PLAIN:
            self.send_keys([PLAIN[ch]])
        elif ch in SHIFTED:
            self.send_keys(["shift", SHIFTED[ch]])
        elif ch.isupper():
            self.send_keys(["shift", ch.lower()])
        elif ch.islower() or ch.isdigit():
            self.send_keys([ch])
        elif ch == "\r":
            return
        else:
            raise ValueError(f"cannot type char {ch!r}")

    def type_text(self, text):
        for ch in text:
            self.type_char(ch)
            time.sleep(KEY_DELAY)

    def mouse_rel(self, dx, dy):
        # The emulated PS/2 mouse clamps per-packet deltas and has a
        # bounded queue: send in chunks of <=120 counts per axis with
        # KEY_DELAY pacing, never one giant event.
        while dx or dy:
            step_x = max(-120, min(120, dx))
            step_y = max(-120, min(120, dy))
            dx -= step_x
            dy -= step_y
            self.cmd("input-send-event", events=[
                {"type": "rel", "data": {"axis": "x", "value": step_x}},
                {"type": "rel", "data": {"axis": "y", "value": step_y}},
            ])
            time.sleep(KEY_DELAY)

    def mouse_btn(self, button, down):
        self.cmd("input-send-event", events=[
            {"type": "btn", "data": {"down": down, "button": button}},
        ])

    def mouse_to(self, x, y):
        # Slam far past the top-left corner: TempleOS re-anchors ms.offset
        # whenever the position would leave the screen (MsHardSetPost,
        # Kernel/SerialDev/Mouse.HC), so the cursor is pinned there and
        # subsequent relative counts map to pixels deterministically.
        self.mouse_rel(-2000, -2000)
        time.sleep(0.3)
        # Counts per pixel: the stock golden image boots ms_hard.scale=0.5
        # (vendor HomeLocalize.HC:11-12), i.e. 1 pixel per 2 raw counts.
        # Landing error is bounded by the grid-8 edge re-anchor + rounding;
        # callers should assert with +-16 px tolerance.
        cpp = float(os.environ.get("QMP_MOUSE_COUNTS_PER_PX", "2"))
        self.mouse_rel(round(cpp * x), round(cpp * y))


def main():
    if len(sys.argv) < 3:
        sys.stderr.write(__doc__)
        return 1
    path, verb = sys.argv[1], sys.argv[2]
    try:
        q = QMP(path)
    except (OSError, ConnectionError) as e:
        sys.stderr.write(f"qmp: cannot connect to {path}: {e}\n")
        return 2
    try:
        if verb == "screendump":
            q.cmd("screendump", filename=os.path.abspath(sys.argv[3]),
                  format="png")
        elif verb == "keys":
            for k in sys.argv[3:]:
                q.send_keys(k.split("+"))  # "shift+f1" presses together
                time.sleep(KEY_DELAY)
        elif verb == "type":
            q.type_text(sys.argv[3])
        elif verb == "typefile":
            with open(sys.argv[3]) as f:
                q.type_text(f.read())
        elif verb == "quit":
            try:
                q.cmd("quit")
            except (ConnectionError, RuntimeError):
                pass  # socket dies as QEMU exits — that's success
        elif verb == "reset":
            q.cmd("system_reset")
        elif verb == "mouse-rel":
            q.mouse_rel(int(sys.argv[3]), int(sys.argv[4]))
        elif verb == "mouse-btn":
            button, state = sys.argv[3], sys.argv[4]
            if button not in ("left", "right") or state not in ("down", "up"):
                sys.stderr.write("qmp: mouse-btn takes left|right down|up\n")
                return 1
            q.mouse_btn(button, state == "down")
        elif verb == "mouse-to":
            q.mouse_to(int(sys.argv[3]), int(sys.argv[4]))
        else:
            sys.stderr.write(f"qmp: unknown verb {verb}\n")
            return 1
    except Exception as e:  # noqa: BLE001 — CLI boundary
        sys.stderr.write(f"qmp: {e}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
