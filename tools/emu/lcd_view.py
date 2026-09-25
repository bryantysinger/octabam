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


# The MKII's front, from Elektron's own layout (the product photo): every
# key where it sits on the unit, its name on the key and its FUNC name under
# it. (x, y) are the key's centre on a 1500 x 840 canvas; w, h its size.
LCD_SCALE = 3
LCD_AT = (558, 238)                                 # the screen's top left
KEYS_MK2 = [
    # code, label, under, x, y, w, h
    (0x35, "MIDI", "MIDI Sync", 110, 300, 62, 50),
    (0x2B, "REC1", "Setup 1", 235, 280, 62, 50),
    (0x2C, "REC2", "Setup 2", 315, 280, 62, 50),
    (0x36, "REC3", "Rec Edit", 395, 280, 62, 50),
    (0x1C, "PROJ", "Save Proj", 110, 410, 62, 50),
    (0x1D, "PART", "Part Edit", 190, 410, 62, 50),
    (0x1E, "AED", "Slice Grid", 270, 410, 62, 50),
    (0x30, "MIX", "Click", 350, 410, 62, 50),
    (0x1F, "ARR", "Arr Mode", 430, 410, 62, 50),
    (0x2D, "FUNC", "", 120, 530, 80, 50),
    (0x27, "CUE", "Reload Part", 250, 530, 80, 50),
    (0x2E, "PTN", "Pattern Settings", 120, 640, 80, 50),
    (0x2F, "BANK", "Track Trig Edit", 250, 640, 80, 50),
    (0x31, "YES", "Arm", 360, 565, 54, 50),
    (0x32, "NO", "Disarm", 360, 640, 54, 50),
    (0x33, "\u2227", "Trig Mode", 500, 565, 54, 50),
    (0x34, "<", "\u00b5Time -", 430, 640, 54, 50),
    (0x20, "\u2228", "Trig Mode", 500, 640, 54, 50),
    (0x21, ">", "\u00b5Time +", 570, 640, 54, 50),
    (0x22, "SRC", "Note", 610, 510, 58, 50),
    (0x23, "AMP", "Arp", 690, 510, 58, 50),
    (0x24, "LFO", "LFO Setup", 770, 510, 58, 50),
    (0x25, "FX1", "Ctrl 1", 850, 510, 58, 50),
    (0x26, "FX2", "Ctrl 2", 930, 510, 58, 50),
    (0x29, "\u25cb", "Copy (REC)", 690, 640, 74, 50),
    (0x28, "\u25b7", "Clear (PLAY)", 770, 640, 74, 50),
    (0x2A, "\u25a1", "Paste (STOP)", 850, 640, 74, 50),
    (0x18, "TEMPO", "Tap Tempo", 1110, 360, 62, 50),
    (0x19, "A", "Scene A / Mute", 1110, 510, 70, 60),
    (0x1A, "B", "Scene B / Mute", 1420, 510, 70, 60),
    (0x1B, "PAGE", "Scale", 1420, 650, 70, 50),
] + [(0x10 + i, f"T{i + 1}", "Cue/Mute", 500 if i < 4 else 1020, 170 + 75 * (i % 4), 54, 48) for i in range(8)] \
  + [(i, str(i + 1), f"T{i % 8 + 1}", 100 + 80 * i, 760, 68, 58) for i in range(16)]
KNOBS_MK2 = [   # encoder index, label, under, x, y
    (6, "LEVEL", "Cursor Pos", 1120, 230),
    (0, "A", "Start Pos", 1220, 230), (1, "B", "Loop Pos", 1320, 230), (2, "C", "End Pos", 1420, 230),
    (3, "D", "Zoom", 1220, 360), (4, "E", "Scroll", 1320, 360), (5, "F", "Zoom", 1420, 360),
]
# Codes the survey has not placed: small keys by number, bottom right.
SPARE_MK2 = [(0x37, 1380, 800), (0x3F, 1440, 800)]


def build_panel(tk, root, panel):
    """The MKII's front as one canvas: every key sends press and release,
    a knob turns with the mouse wheel (Shift: x4) and pushes on a click,
    the top-left knob is the MAIN pot. Returns the canvas and where the
    screen goes on it."""
    BG, KEY, TXT, SUB, EDGE = "#1c1c1e", "#2a2a2d", "#d8d8d8", "#8a8a8a", "#3a3a3e"
    cv = tk.Canvas(root, width=1500, height=790, bg="#101012", highlightthickness=0)
    cv.pack()
    bg = cv.create_rectangle(20, 20, 1480, 820, fill=BG, outline="#2c2c30", width=2)

    def rrect(x0, y0, x1, y1, r, **kw):
        pts = [x0 + r, y0, x1 - r, y0, x1, y0, x1, y0 + r, x1, y1 - r, x1, y1, x1 - r, y1,
               x0 + r, y1, x0, y1, x0, y1 - r, x0, y0 + r, x0, y0]
        return cv.create_polygon(pts, smooth=True, **kw)

    def key(code, label, under, x, y, w, h):
        tag = f"key{code}"
        rrect(x - w / 2, y - h / 2, x + w / 2, y + h / 2, 8, fill=KEY, outline=EDGE, width=2, tags=(tag, tag + "b"))
        cv.create_text(x, y, text=label, fill=TXT, font=("Helvetica", 12, "bold"), tags=tag)
        if under:
            cv.create_text(x, y + h / 2 + 11, text=under, fill=SUB, font=("Helvetica", 9))

        def down(e):
            cv.itemconfigure(tag + "b", fill="#55555a")
            panel.key(code, True)

        def up(e):
            cv.itemconfigure(tag + "b", fill=KEY)
            panel.key(code, False)
        cv.tag_bind(tag, "<ButtonPress-1>", down)
        cv.tag_bind(tag, "<ButtonRelease-1>", up)

    wheel = {}                      # canvas tag -> (event, +-1): the wheel is the canvas's

    def knob(n, label, under, x, y, r=28):
        tag = f"knob{n}"
        cv.create_oval(x - r, y - r, x + r, y + r, fill="#2e2e32", outline="#4a4a50", width=2, tags=tag)
        cv.create_oval(x - r + 6, y - r + 6, x + r - 6, y + r - 6, fill="#252528", outline="", tags=tag)
        cv.create_text(x, y + r + 12, text=label, fill=TXT, font=("Helvetica", 11, "bold"))
        cv.create_text(x, y + r + 26, text=under, fill=SUB, font=("Helvetica", 9))
        push = 0x38 + n if n < 6 else 0x3E
        cv.tag_bind(tag, "<ButtonPress-1>", lambda e: panel.key(push, True))
        cv.tag_bind(tag, "<ButtonRelease-1>", lambda e: panel.key(push, False))
        wheel[tag] = lambda e, d: panel.enc(n, d * (4 if e.state & 1 else 1))

    # the screen's bezel
    lx, ly = LCD_AT
    cv.create_rectangle(lx - 34, ly - 50, lx + W * LCD_SCALE + 34, ly + H * LCD_SCALE + 62, fill="#0b0b0c", outline="")
    cv.create_text(lx, ly - 30, anchor="w", text="8 Track Dynamic Performance Sampler", fill="#cfcfcf",
                   font=("Helvetica", 10, "bold"))
    cv.create_text(lx, ly + H * LCD_SCALE + 34, anchor="w", text="Octatrack MKII  (octabam port)", fill="#dddddd",
                   font=("Helvetica", 16, "bold"))

    for k in KEYS_MK2:
        key(*k)
    for k in KNOBS_MK2:
        knob(*k)
    for code, x, y in SPARE_MK2:
        key(code, f"{code:02x}", "", x, y, 44, 28)

    # the MAIN pot, top left: drag up/down or wheel
    level = {"v": 200}
    px, py = 150, 175
    cv.create_oval(px - 26, py - 26, px + 26, py + 26, fill="#2e2e32", outline="#4a4a50", width=2, tags="pot")
    potv = cv.create_text(px, py, text="200", fill=TXT, font=("Helvetica", 10), tags="pot")
    cv.create_text(px, py + 40, text="Main Vol (pot)", fill=TXT, font=("Helvetica", 10, "bold"))

    def pot(d):
        level["v"] = max(0, min(255, level["v"] + d))
        cv.itemconfigure(potv, text=str(level["v"]))
        panel.pot(level["v"])
    wheel["pot"] = lambda e, d: pot(8 * d)

    def on_wheel(e, d):
        for it in cv.find_withtag("current"):
            for t in cv.gettags(it):
                if t in wheel:
                    wheel[t](e, d)
                    return
    cv.bind("<MouseWheel>", lambda e: on_wheel(e, 1 if e.delta > 0 else -1))
    cv.bind("<Button-4>", lambda e: on_wheel(e, 1))
    cv.bind("<Button-5>", lambda e: on_wheel(e, -1))

    # the crossfader: drawn, not modelled by the port
    cv.create_line(1170, 510, 1360, 510, fill="#444448", width=6)
    cv.create_rectangle(1255, 485, 1275, 535, fill="#3a3a3e", outline="#555")
    cv.create_text(1265, 555, text="crossfader (not modelled)", fill=SUB, font=("Helvetica", 9))
    cv.create_text(760, 822, text="keyboard: arrows, Return = YES, Esc = NO, space = PLAY, F1-F5 = pages, "
                   "1-8 q-i = trigs;  wheel over a knob turns it (Shift x4), a click pushes it",
                   fill=SUB, font=("Helvetica", 9))

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
    # the layout is drawn on the photo's grid; its top 60 px are empty
    cv.move("all", 0, -60)
    cv.coords(bg, 20, 20, 1480, 770)
    return cv, lx, ly - 60, LCD_SCALE


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
    if a.panel:
        canvas, ox, oy, scale = build_panel(tk, root, Panel(a.panel))
    else:
        canvas = tk.Canvas(root, width=W * a.scale, height=H * a.scale, bg="#%02x%02x%02x" % OFF,
                           highlightthickness=0)
        canvas.pack()
        ox, oy, scale = 0, 0, a.scale
    on = "#%02x%02x%02x" % ON
    state = {"img": None}

    def draw(rows):
        img = tk.PhotoImage(width=W, height=H)
        data = " ".join("{" + " ".join(on if v else "#%02x%02x%02x" % OFF for v in row) + "}" for row in rows)
        img.put(data, to=(0, 0))
        img = img.zoom(scale, scale)
        canvas.delete("lcd")
        canvas.create_image(ox, oy, anchor="nw", image=img, tags="lcd")
        state["img"] = img

    gen = watch(a.plane, draw, period=0)

    def tick():
        next(gen)
        root.after(50, tick)
    tick()
    root.mainloop()


if __name__ == "__main__":
    main()
