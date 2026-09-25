#!/usr/bin/env python3
"""Show the Octatrack's screen from the port's plane file.

    ./out/emu/ot_emu ... --lcd out/lcd.bin        # the port, in one terminal
    .venv/bin/python3 tools/emu/lcd_view.py out/lcd.bin          # a window
    .venv/bin/python3 tools/emu/lcd_view.py out/lcd.bin --term   # in the terminal
    .venv/bin/python3 tools/emu/lcd_view.py out/lcd.bin --png shot.png
    .venv/bin/python3 tools/emu/lcd_view.py out/lcd.bin --panel out/panel.fifo   # + keys and encoders

--panel writes the port's --live FIFO: a key sends "key <code> down" on
press and "... up" on release (so FUNC + key works), an encoder sends
"enc <n> <delta>" (buttons, or the mouse wheel over its label), the pot
"pot <0..255>". Keyboard: arrows, Return = YES, Escape = NO, space =
PLAY, 1..8 / q..i = trigs 1..16, F1..F5 = the page keys.

The file starts with the firmware's own 1-bpp plane at 0x46c7e0ea (1,024
bytes): 64 columns x 128 rows, 8 bytes per row, MSB left. Screen pixel
(x, y) is column 63-y of row x -- the panel is stored rotated a quarter
turn. Measured 17 Sep 2026 by rendering a dump under each candidate
layout; the PLAYBACK page reads upright under this one and under no other.

Since 25 Sep 2026 the port appends the popup windows (the menu, TEMPO,
prompts), which the firmware keeps out of that plane: the window table at
0x46c7d34c (five 56-byte entries: x and y from the top left at +8/+12,
bit 0x20 of +32 set while the window shows, w and h at +36/+40) and the
planes at 0x460d1f7b (slot i's ink at +i*0x400, its opacity mask 0x1400
above; w columns of ceil(h/32)*4 bytes, row y of the window at bit h-1-y
from the column's MSB). Every visible window is composited over the page:
the mask picks the window's ink, the page shows elsewhere. Read from the
port's RAM against the stock TEMPO, CONTROL INPUT, MIDI SYNC and date
prompt, 25 Sep 2026.
"""
import struct as _struct
import argparse
import os
import struct
import sys
import time
import zlib

W, H = 128, 64
ON, OFF = (0xE8, 0xF0, 0x60), (0x18, 0x20, 0x10)


def pixels(plane):
    """Rows of 0/1, screen orientation."""
    def bit(col, row):
        return (plane[row * 8 + col // 8] >> (7 - col % 8)) & 1
    return [[bit(63 - y, x) for x in range(W)] for y in range(H)]


def png(rows, path, scale=4):
    out = []
    for y in range(H * scale):
        line = bytearray([0])
        for x in range(W * scale):
            line += bytes(ON if rows[y // scale][x // scale] else OFF)
        out.append(bytes(line))
    raw = b"".join(out)

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W * scale, H * scale, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def term(rows):
    """Two pixel rows per text row, half blocks."""
    glyph = {(0, 0): " ", (1, 0): "▀", (0, 1): "▄", (1, 1): "█"}
    return "\n".join("".join(glyph[(rows[y][x], rows[y + 1][x])] for x in range(W)) for y in range(0, H, 2))


WIN_TABLE, WIN_ENTRY, WIN_SLOTS = 1024, 56, 5
WIN_PLANES = WIN_TABLE + WIN_SLOTS * WIN_ENTRY
WIN_MASK = 0x1400


def read_plane(path):
    """The file as the port wrote it: the page plane, and the windows when
    it carries them."""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) != 1024 and len(data) != WIN_PLANES + 0x2800:
        raise ValueError(f"{path}: {len(data)} bytes, want 1024 or {WIN_PLANES + 0x2800}")
    return data


def composite(rows, data):
    """Every visible window over the page rows, in table order."""
    if len(data) == 1024:
        return rows
    for i in range(WIN_SLOTS):
        e = WIN_TABLE + i * WIN_ENTRY
        x0, y0 = _struct.unpack(">ii", data[e + 8:e + 16])
        flags, w, h = _struct.unpack(">Iii", data[e + 32:e + 44])
        if not flags & 0x20 or not (0 < w <= W and 0 < h <= H):
            continue
        col = (h + 31) // 32 * 4
        ink = WIN_PLANES + i * 0x400
        for x in range(w):
            sx = x0 + x
            if not 0 <= sx < W:
                continue
            a = int.from_bytes(data[ink + x * col:ink + x * col + col], "big")
            m = int.from_bytes(data[ink + WIN_MASK + x * col:ink + WIN_MASK + x * col + col], "big")
            for y in range(h):
                sy = y0 + y
                shift = col * 8 - 1 - (h - 1 - y)
                if 0 <= sy < H and (m >> shift) & 1:
                    rows[sy][sx] = (a >> shift) & 1
    return rows


def screen(data):
    """Screen rows (0/1) of a file's contents: page plus windows."""
    return composite(pixels(data[:1024]), data)


def watch(path, on_frame, period=0.05):
    last = None
    while True:
        try:
            st = os.stat(path)
            key = (st.st_mtime_ns, st.st_size)
            if key != last:
                last = key
                on_frame(screen(read_plane(path)))
        except (FileNotFoundError, ValueError):
            pass
        yield
        time.sleep(period)


# Key codes are the panel controller's: the keymap the firmware installs
# ([0x46c901dc]) is the identity, so code = row*8 + bit. Names from
# docs/firmware/PANEL.md (octalab's list, the 18 Sep 2026 probe under the
# port) and the 25 Sep 2026 survey under the port (TEMPO, SCENE A/B, PAGE,
# PART, ARR, MIX); a trailing "?" marks a name inferred, not measured.
KEYS = {
    **{i: f"{i + 1}" for i in range(16)},          # trig keys
    **{0x10 + i: f"T{i + 1}" for i in range(8)},   # track keys
    0x18: "TEMPO", 0x19: "SCENE A", 0x1A: "SCENE B", 0x1B: "PAGE", 0x1C: "MENU", 0x1D: "PART", 0x1F: "ARR",
    0x20: "DOWN", 0x21: "RIGHT", 0x22: "SRC", 0x23: "AMP", 0x24: "LFO", 0x25: "FX1", 0x26: "FX2",
    0x27: "CUE?", 0x28: "PLAY", 0x29: "REC", 0x2A: "STOP", 0x2B: "REC1?", 0x2C: "REC2?",
    0x2D: "FUNC", 0x2E: "PATTERN", 0x2F: "BANK", 0x30: "MIX", 0x31: "YES", 0x32: "NO", 0x33: "UP", 0x34: "LEFT",
    0x35: "MIDI", 0x36: "REC3?",
    **{0x38 + i: f"push {'ABCDEF'[i]}" for i in range(6)}, 0x3E: "push LEV",
}
ENCODERS = ["A", "B", "C", "D", "E", "F", "LEVEL"]
# Codes the survey has not named; drawn in their own group by number.
UNNAMED = (0x1E, 0x37, 0x3F)


class Panel:
    """Writes panel events to the port's --live FIFO."""

    def __init__(self, path):
        self.path = path
        self.fd = -1

    def send(self, line):
        # Opened on first use, non-blocking: a FIFO with no reader yet
        # (the port still loading) refuses the open and the event is
        # dropped rather than the window freezing.
        try:
            if self.fd < 0:
                self.fd = os.open(self.path, os.O_WRONLY | os.O_NONBLOCK)
            os.write(self.fd, (line + "\n").encode())
        except OSError:
            if self.fd >= 0:
                try:
                    os.close(self.fd)
                except OSError:
                    pass
            self.fd = -1

    def key(self, code, down):
        self.send(f"key 0x{code:02x} {'down' if down else 'up'}")

    def enc(self, n, delta):
        self.send(f"enc {n} {delta}")

    def pot(self, v):
        self.send(f"pot {int(v)}")


def build_panel(tk, root, panel, canvas):
    """The screen in the middle of an Octatrack-shaped panel: LEVEL and the
    track keys to its left, the six knobs, the page keys and the arrows to
    its right, the mode keys under it, trigs and transport along the
    bottom. Every key sends press and release; a knob is `<< < NAME > >>`
    (the wheel over its name turns it, a click on the name pushes it)."""
    BG, GROUP = "#2b2b2b", "#bbbbbb"
    root.configure(bg=BG)

    def box(parent, title):
        return tk.LabelFrame(parent, text=title, fg=GROUP, bg=BG, padx=4, pady=3, bd=1, relief="groove")

    def keybtn(parent, code, width=6):
        b = tk.Button(parent, text=KEYS.get(code, f"{code:02x}"), width=width, highlightbackground=BG)
        b.bind("<ButtonPress-1>", lambda e, c=code: panel.key(c, True))
        b.bind("<ButtonRelease-1>", lambda e, c=code: panel.key(c, False))
        return b

    def knob(parent, n):
        f = tk.Frame(parent, bg=BG)
        for d, t in ((-4, "«"), (-1, "‹")):
            tk.Button(f, text=t, width=1, highlightbackground=BG,
                      command=lambda dd=d: panel.enc(n, dd)).pack(side="left")
        lab = tk.Label(f, text=ENCODERS[n], width=6, relief="raised", bg="#444444", fg="white")
        lab.pack(side="left", padx=2)
        push = 0x38 + n if n < 6 else 0x3E
        lab.bind("<ButtonPress-1>", lambda e: panel.key(push, True))
        lab.bind("<ButtonRelease-1>", lambda e: panel.key(push, False))
        lab.bind("<MouseWheel>", lambda e: panel.enc(n, 1 if e.delta > 0 else -1))
        lab.bind("<Button-4>", lambda e: panel.enc(n, 1))
        lab.bind("<Button-5>", lambda e: panel.enc(n, -1))
        for d, t in ((1, "›"), (4, "»")):
            tk.Button(f, text=t, width=1, highlightbackground=BG,
                      command=lambda dd=d: panel.enc(n, dd)).pack(side="left")
        return f

    top = tk.Frame(root, bg=BG)
    top.pack(padx=6, pady=6)

    # left of the screen: LEVEL, the main volume, the track keys
    left = tk.Frame(top, bg=BG)
    left.grid(row=0, column=0, sticky="n", padx=(0, 8))
    lev = box(left, "LEVEL")
    lev.pack(fill="x")
    knob(lev, 6).pack()
    pot = tk.Scale(lev, from_=0, to=255, orient="horizontal", label="MAIN volume", length=150,
                   command=panel.pot, bg=BG, fg=GROUP, highlightthickness=0)
    pot.set(200)
    pot.pack()
    trk = box(left, "TRACKS")
    trk.pack(fill="x", pady=(6, 0))
    for i in range(8):
        keybtn(trk, 0x10 + i, width=4).grid(row=i // 4, column=i % 4, padx=1, pady=1)
    cue = box(left, "")
    cue.pack(fill="x", pady=(6, 0))
    keybtn(cue, 0x27, width=6).pack(side="left", padx=1)
    keybtn(cue, 0x2D, width=6).pack(side="left", padx=1)

    canvas.grid(in_=top, row=0, column=1, sticky="n")

    # right of the screen: data entry, pages, navigation
    right = tk.Frame(top, bg=BG)
    right.grid(row=0, column=2, sticky="n", padx=(8, 0))
    data = box(right, "DATA ENTRY")
    data.pack(fill="x")
    for n in range(6):
        knob(data, n).grid(row=n // 3, column=n % 3, padx=3, pady=2)
    pages = box(right, "PAGES")
    pages.pack(fill="x", pady=(6, 0))
    for code in (0x22, 0x23, 0x24, 0x25, 0x26):
        keybtn(pages, code, width=5).pack(side="left", padx=1)
    nav = box(right, "NAVIGATE")
    nav.pack(fill="x", pady=(6, 0))
    keybtn(nav, 0x33, width=6).grid(row=0, column=1)
    keybtn(nav, 0x34, width=6).grid(row=1, column=0)
    keybtn(nav, 0x20, width=6).grid(row=1, column=1)
    keybtn(nav, 0x21, width=6).grid(row=1, column=2)
    tk.Frame(nav, width=16, bg=BG).grid(row=0, column=3)
    keybtn(nav, 0x32, width=6).grid(row=1, column=4)
    keybtn(nav, 0x31, width=6).grid(row=1, column=5)

    # under the screen: the mode keys
    modes = box(top, "MODES")
    modes.grid(row=1, column=0, columnspan=3, sticky="we", pady=(6, 0))
    for code in (0x1C, 0x18, 0x30, 0x1D, 0x1F, 0x35, 0x1B, 0x2E, 0x2F, 0x19, 0x1A):
        keybtn(modes, code, width=7).pack(side="left", padx=1)

    # the bottom: trigs, recorders, transport
    bottom = tk.Frame(top, bg=BG)
    bottom.grid(row=2, column=0, columnspan=3, sticky="we", pady=(6, 0))
    trigs = box(bottom, "TRIGS")
    trigs.pack(side="left")
    for i in range(16):
        keybtn(trigs, i, width=2).pack(side="left", padx=(6 if i and i % 4 == 0 else 1, 1))
    other = box(bottom, "UNNAMED")
    other.pack(side="left", padx=(8, 0))
    for code in UNNAMED:
        keybtn(other, code, width=3).pack(side="left", padx=1)
    tr = box(bottom, "RECORD / TRANSPORT")
    tr.pack(side="right")
    for code in (0x2B, 0x2C, 0x36, 0x29, 0x28, 0x2A):
        keybtn(tr, code, width=5).pack(side="left", padx=1)

    # keyboard
    kb = {"Left": 0x34, "Right": 0x21, "Up": 0x33, "Down": 0x20, "Return": 0x31, "Escape": 0x32, "space": 0x28,
          "F1": 0x22, "F2": 0x23, "F3": 0x24, "F4": 0x25, "F5": 0x26}
    for i, ch in enumerate("12345678qwertyui"):
        kb[ch] = i
    held = set()

    def press(e):
        code = kb.get(e.keysym)
        if code is not None and code not in held:
            held.add(code)
            panel.key(code, True)

    def release(e):
        code = kb.get(e.keysym)
        if code is not None and code in held:
            held.discard(code)
            panel.key(code, False)
    root.bind("<KeyPress>", press)
    root.bind("<KeyRelease>", release)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("plane", help="the file --lcd writes")
    ap.add_argument("--png", help="write one PNG of the current frame and exit")
    ap.add_argument("--term", action="store_true", help="draw in the terminal instead of a window")
    ap.add_argument("--panel", help="the port's --live FIFO: draw keys and encoders under the screen and write events to it")
    ap.add_argument("--scale", type=int, default=4)
    a = ap.parse_args()

    if a.png:
        png(screen(read_plane(a.plane)), a.png, a.scale)
        print(a.png)
        return

    if a.term:
        def draw(rows):
            sys.stdout.write("\x1b[H\x1b[2J" + term(rows) + "\n")
            sys.stdout.flush()
        try:
            for _ in watch(a.plane, draw):
                pass
        except KeyboardInterrupt:
            pass
        return

    import tkinter as tk
    root = tk.Tk()
    root.title(os.path.basename(a.plane))
    root.resizable(False, False)
    root.title(os.path.basename(a.plane) + (" + panel" if a.panel else ""))
    canvas = tk.Canvas(root, width=W * a.scale, height=H * a.scale, bg="#%02x%02x%02x" % OFF, highlightthickness=0)
    if a.panel:
        build_panel(tk, root, Panel(a.panel), canvas)
    else:
        canvas.pack()
    on = "#%02x%02x%02x" % ON
    state = {"img": None}

    def draw(rows):
        img = tk.PhotoImage(width=W, height=H)
        data = " ".join("{" + " ".join(on if v else "#%02x%02x%02x" % OFF for v in row) + "}" for row in rows)
        img.put(data, to=(0, 0))
        img = img.zoom(a.scale, a.scale)
        canvas.delete("all")
        canvas.create_image(0, 0, anchor="nw", image=img)
        state["img"] = img

    gen = watch(a.plane, draw, period=0)

    def tick():
        next(gen)
        root.after(50, tick)
    tick()
    root.mainloop()


if __name__ == "__main__":
    main()
