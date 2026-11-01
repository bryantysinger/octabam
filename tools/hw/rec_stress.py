#!/usr/bin/env python3
"""The recorder stress test: one project, ladders of recorder load stepped over USB MIDI, the frame interrupt and
the tasks read over USB at every rung, a scorecard per image.

    python3 tools/hw/rec_stress.py plan
    python3 tools/hw/rec_stress.py proj TEMPLATE DEST [--bits 24]   # TEMPLATE: eight sound-on-sound tracks set up on the unit
    python3 tools/hw/rec_stress.py run DEST LABEL [--midi Octatrack] [--usb-in Octatrack] [--usb off,on]
                                                  [--ladders SELF,DIAG,MED,DENSE,SWITCH] [--secs 10] [--settle 4]
                                                  [--resume]
    python3 tools/hw/rec_stress.py report LABEL [LABEL ...]      # the scorecard; two or more labels side by side
    python3 tools/hw/rec_stress.py masks [--set REC=MASK ...]    # read (or set) REC MATRIX's masks over USB
    python3 tools/hw/rec_stress.py hold DEST LABEL --rung "MED x3" [--usb on|in|out|off] [--minutes 5] [--repeats 3]
                                                  [--all]          # one rung held: how often tracks stop
    python3 tools/hw/rec_stress.py cycle DEST LABEL --from "MED x2" --to "MED x3" [--count 30] [--secs 10]
                                                  [--usb on|in|out|off]   # the change between two rungs, repeated

HOLD AND CYCLE (1 Nov 2026: on the unit, tracks 2 and up stopped partway through MTRX rungs with USB on, once at
66% load, track 1 running on). `hold` plays one rung for --minutes, polling as `run` does plus the USB counters
every 0.5 s; every change of a track's glyph is logged with its time after START and its bar.beat. When a track
that should be recording shows the stopped glyph for two polls, the stop is counted, its segment written, and the
transport restarted (STOP, the program change, START, --settle), so one hold gives a rate: stops a minute. Up to
--repeats holds, ending after the first with a stop unless --all. `cycle` plays --from for --settle, then STOP,
the program change and START into --to, and measures --to for --secs, --count times: stops a change. --usb in
streams only the tone into the unit, out only takes its output, on both, off neither. One JSON line per segment or
cycle in out/hw/stress/LABEL.jsonl (`kind` hold or cycle), with the events and every window.

WHY. "Is it better than last build" and "what do we have to tell users before they rely on it" both need the same
conditions every time, run without anyone at the panel. The ladders climb in load and stop where the unit does.

THE TEMPLATE is a project set up on the unit, as a user sets up sound-on-sound: bank A part 1 with every track a
FLEX machine on its own recorder buffer, INAB A B, INCD -, RLEN 16, SRC3 the track itself, chosen on the panel (the
panel's FLEX choice sets bytes a machine-type write does not: 1 Nov 2026, the play triangle only flashed on a
generated part). `proj` refuses any other. It keeps the template's Part as the unit wrote it -- machines, levels,
volumes, effects, attributes, DYNAMIC_RECORDERS, depth -- and writes only the trigs, bank B's recorder sources, the
MIDI receive settings and 128 BPM (RECORD_24BIT too, if --bits is given):
  bank A, part 1  SELF: the template's part. Pattern n (1-8): the first n tracks with PLAY + REC1 + REC2 + REC3 on
                  step 1 (the template's own layout). Pattern 16: no trigs (BASE).
  bank B, part 1  MTRX: the template's part with every track's INAB -, INCD -, SRC3 MTRX. Pattern n: the first n
                  tracks with PLAY + REC3 on step 1. The matrix is not in the project: `run` sets every recorder's row over USB
                  before each rung (vendor request 0xc0/0x58, images with FRAME PROFILE and REC MATRIX):
                    DIAG   recorder t records Tt                                   (1 source)
                    MED    Tt + AB + MAIN                                          (3 sources)
                    DENSE  AB + CD + T1-T8 + MAIN + CUE                            (12 sources, every non-overlapping one)
                  SWITCH holds MTRX x4 and flips every row between DIAG and DENSE every --flip seconds (the
                  64-sample ramps on every change, QUANT as the project has it: OFF in a fresh one).
A program change (channel 1) selects 16 x bank + pattern. By default (proj --clock internal) the unit is the
clock, as it is played, and the script sends only START, STOP and program changes; with --clock midi the project
receives MIDI clock and the script sends it (every project before 1 Nov 2026 did: a stop seen then began with
playback ending three quarters through a bar, a short take, one candidate cause being arm spacing measured
from a jittered external clock).

A RUN. --usb off,on runs every ladder with USB audio idle, then again with the host streaming: a 997 Hz sine at
-20 dBFS into USB IN ABCD and the unit's output taken (with --audio, MAIN L checked: only with a template whose
tracks do not reach MAIN, since the loops on MAIN would read as damage). Within a phase: BASE; each ladder from x1
up, then its DROP rung (x8 played for --settle, then STOP and x1: the heavy-to-light change that locked a unit on 31
Oct 2026); then BASE again as a cool-down before the next ladder. Per rung: STOP twice, the program change, START,
--settle seconds (two bars at 128 BPM: the first take, then sound on sound), then --secs of polling: BRAIN's task
ledger (block 4), LOAD METER's windows (block 0: the frame interrupt's mean and its longest single run) and FRAME
PROFILE's sections (block 5), the USB counters before and after. One JSON line per rung in out/hw/stress/LABEL.jsonl,
with every 0.5 s window kept (`series`).

WHAT A RUNG REPORTS.
  CLEAN          nothing below.
  LATE           a frame interrupt ran past the 362.8 us frame in some window (the next one started late). Not a
                 failure by itself: on 31 Oct 2026 LATE rungs up to 506 us lost no USB packet.
  USB ERR        an IN or OUT error, underrun or overrun counter moved.
  AUDIO          (USB on) MAIN's tone, the USB IN -> DIR AB -> MAIN -> USB OUT path, slipped a sample or more, or
                 dropped, or its residual rose 10 dB over the phase's BASE: a block was lost or repeated somewhere
                 between the host and back.
  USB IN STOPPED / USB OUT STOPPED
                 (USB on) the stream stopped moving in that direction during the rung, with no counter to say so
                 (31 Oct 2026: USB IN stopped at MED x8 and stayed stopped until a power cycle).
  SCREEN FROZEN  the screen's picture did not change for 2 s or more while the transport ran (the beat boxes
                 change every beat, 0.47 s at 128 BPM): what a user sees as the screen no longer updating.
  REC/PLAY       a recording track's glyph on the PLAYBACK page was not + with the play triangle for two polls
                 running (a take not started, or a buffer not playing), or a track that should be stopped was
                 not: what a user sees as the + or the animation missing.
  LOCKUP         the unit stopped answering, or LOAD METER's window count stopped for 3 s.
LOCKUP and the STOPPEDs end the run: power-cycle the unit (it reloads the project), then the same command with
--resume skips the rungs already done and the rest of the ladder that ended it. The scorecard climbs each ladder to
the first USB ERR, AUDIO, STOPPED or LOCKUP and gives the frame interrupt's mean load at the top clean rung.

THE SCREEN. With FRAME PROFILE's probes the unit answers 0xc0/0x59 (a read of RAM), and every poll reads the
screen's plane (0x46c7e0ea, 1,024 bytes; docs/firmware/PANEL.md) and each track's glyph under its F on the PLAYBACK
page: a square stopped, + recording, + and a triangle recording and playing. Each rung reports how often the
picture changed (updates a second: the slowdown users see) and its longest still stretch. Leave the unit on the
PLAYBACK page of track 1; `run` refuses to start when it cannot read the glyphs.

What it cannot see:
interrupts other than the frame interrupt stay inside the tasks they hit; FRAME PROFILE's sections are window
means, so a single long frame is not attributed; the audio check covers the realtime path, not what a recorder
wrote.
"""
import argparse
import json
import math
import pathlib
import re
import shutil
import statistics
import struct
import sys
import threading
import time

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import analyzer_sweep as AZ                           # noqa: E402  (bank layout, USB counters)

BPM = 128
FS = 44100
PLAN_FILE = "OCTABAM_STRESS.json"
OUT = pathlib.Path("out/hw/stress")
FRAME_US = 16 / FS * 1e6                              # 362.8 us
CF_HZ = 132e6
SELF_BANK, MTRX_BANK, BASE_PATTERN = 0, 1, 15
SRC3_MTRX = 11                                        # the stored SRC3 value REC MATRIX formats as MTRX (rmx.s)
REC_SELF = {"INAB": 1, "INCD": 0, "RLEN": 15, "LOOP": 0}    # A B, -, 16 steps (raw), off
REC_MTRX = {"INAB": 0, "INCD": 0, "RLEN": 15, "LOOP": 0}
TRIGS_SELF = (AZ.MASK_PLAY, AZ.MASK_REC1, AZ.MASK_REC2, AZ.MASK_REC3)
TRIGS_MTRX = (AZ.MASK_PLAY, AZ.MASK_REC3)
NS = range(1, 9)
SWITCH_N = 4
TONE_HZ, TONE_DBFS = 997.0, -20.0
HARD = ("LOCKUP", "USB IN STOPPED", "USB OUT STOPPED", "USB ERR", "AUDIO", "SCREEN FROZEN", "REC/PLAY")
PLANE, PLANE_BYTES = 0x46c7e0ea, 1024                  # the screen's 1-bit plane (docs/firmware/PANEL.md)
STILL_S = 2.0
TERMINAL = ("LOCKUP", "USB IN STOPPED", "USB OUT STOPPED")

# REC MATRIX's masks (modules/rec-matrix README, Storage): bit 0 A, 1 B, 2 C, 3 D, 4 AB, 5 CD, 6-13 T1-T8,
# 14 MAIN, 15 CUE
AB, CD, MAIN, CUE = 1 << 4, 1 << 5, 1 << 14, 1 << 15


def track_bit(t):
    return 1 << (6 + t)


DENSITIES = {
    "DIAG": lambda t: track_bit(t),
    "MED": lambda t: track_bit(t) | AB | MAIN,
    "DENSE": lambda t: AB | CD | 0x3FC0 | MAIN | CUE,
}
LADDERS = ("SELF", "DIAG", "MED", "DENSE", "SWITCH")


# ---------------------------------------------------------------------------------------------------- the plan --

def prog(lad, n):
    return 16 * (SELF_BANK if lad == "SELF" else MTRX_BANK) + n - 1


def rungs(ladders=LADDERS):
    """The rungs of one USB phase, in run order."""
    base = lambda tag="": {"ladder": "BASE", "n": 0, "program": 16 * SELF_BANK + BASE_PATTERN, "density": None,
                           "tag": tag}
    out = [base()]
    for i, lad in enumerate(ladders):
        if i:
            out.append(base(f"before {lad}"))
        dens = lad if lad in DENSITIES else None
        if lad in ("SELF",) + tuple(DENSITIES):
            out += [{"ladder": lad, "n": n, "program": prog(lad, n), "density": dens} for n in NS]
            out.append({"ladder": lad, "n": 1, "program": prog(lad, 1), "density": dens, "drop": prog(lad, 8)})
        elif lad == "SWITCH":
            out.append({"ladder": "SWITCH", "n": SWITCH_N, "program": prog("SWITCH", SWITCH_N),
                        "density": "DIAG/DENSE"})
        else:
            sys.exit(f"no ladder {lad!r}: {', '.join(LADDERS)}")
    return out


def rung_id(usb, r):
    head = f"USB {usb.upper()}/"
    if r["ladder"] == "BASE":
        return head + "BASE" + (f" {r['tag']}" if r.get("tag") else "")
    if r.get("drop") is not None:
        return head + f"{r['ladder']} DROP x8>x1"
    return head + f"{r['ladder']} x{r['n']}"


def cmd_plan(_a):
    for r in rungs():
        dens = f"  masks {r['density']}" if r["density"] else ""
        what = rung_id("-", r)[6:]
        pre = f"PC {r['drop']:3d} then " if r.get("drop") is not None else ""
        print(f"{pre}PC {r['program']:3d}  {what:22s}{dens}")
    print("each rung runs once with USB audio idle and once streaming (--usb off,on)")


# ------------------------------------------------------------------------------------------------- the project --

PART_BYTES = AZ.PART_STRIDE


def template_ok(data):
    """The template's bank A part 1 is eight sound-on-sound tracks: FLEX on buffer R(t), INAB A B, INCD -, RLEN 16,
    SRC3 the track. -> list of what is not."""
    bad = []
    b = AZ.PART_BASE
    for t in range(8):
        rs = b + AZ.REC_SETUP_OFF + t * 12
        f = lambda k: data[rs + AZ.REC_FIELDS.index(k)]
        if data[b + AZ.MTYPE_OFF + t] != 1 or data[b + AZ.SLOT_OFF + t * 5 + 1] != 128 + t:
            bad.append(f"T{t + 1} is not FLEX on recorder buffer {t + 1}")
        elif (f("INAB"), f("INCD"), f("RLEN"), f("SRC3")) != (1, 0, 15, t + 1):
            bad.append(f"T{t + 1}'s recording setup is not INAB A B, INCD -, RLEN 16, SRC3 T{t + 1}")
    return bad


def write_banks(dest, template_bank):
    """Bank A: the template's part 1 (and as its saved copy), the SELF trigs. Bank B: the same part with the MTRX
    sources, the MTRX trigs. Every pattern of both: part 1, LEN 16 1X, no other trig or lock."""
    part = template_bank[AZ.PART_BASE:AZ.PART_BASE + PART_BYTES]
    for bank, trigs, mtrx in ((SELF_BANK, TRIGS_SELF, False), (MTRX_BANK, TRIGS_MTRX, True)):
        for suffix in ("work", "strd"):
            path = dest / f"bank{bank + 1:02d}.{suffix}"
            if not path.exists():
                continue
            data = bytearray(path.read_bytes())
            for p in (0, 4):                                # part 1 and its saved copy
                base = AZ.PART_BASE + p * AZ.PART_STRIDE
                data[base:base + PART_BYTES] = part
                if mtrx:
                    for t in range(8):
                        rs = base + AZ.REC_SETUP_OFF + t * 12
                        for f, v in REC_MTRX.items():
                            data[rs + AZ.REC_FIELDS.index(f)] = v
                        data[rs + AZ.REC_FIELDS.index("SRC3")] = SRC3_MTRX
            for pat in range(16):
                for t in range(8):
                    off = AZ.trac_off(pat, t)
                    data[off:off + 64] = bytes(64)          # no trigs or trigless locks
                    data[off + 0x50], data[off + 0x51] = 16, 2
                tail = AZ.PTRN0 + pat * AZ.PTRN_FSTRIDE + AZ.PTRN_FSTRIDE - 11
                data[tail + 2], data[tail + 3] = 16, 2      # LEN 16, 1X
                data[AZ.PTRN0 + pat * AZ.PTRN_FSTRIDE + AZ.PTRN_FSTRIDE - 5] = 0   # part 1
            for n in NS:
                for t in range(n):
                    for mask in trigs:
                        data[AZ.trac_off(n - 1, t) + mask + 7] |= 1    # step 1
            data[-2:] = (sum(data[0x10:-2]) & 0xFFFF).to_bytes(2, "big")
            path.write_bytes(bytes(data))


def check_banks(dest, template_bank):
    tpart = template_bank[AZ.PART_BASE:AZ.PART_BASE + PART_BYTES]
    for bank, trigs, mtrx in ((SELF_BANK, TRIGS_SELF, False), (MTRX_BANK, TRIGS_MTRX, True)):
        data = (dest / f"bank{bank + 1:02d}.work").read_bytes()
        for n in NS:
            for mask in (AZ.MASK_PLAY, AZ.MASK_REC1, AZ.MASK_REC2, AZ.MASK_REC3):
                on = [t for t in range(8) if data[AZ.trac_off(n - 1, t) + mask + 7] & 1]
                assert on == (list(range(n)) if mask in trigs else []), (bank, n, hex(mask), on)
        for pat in (8, BASE_PATTERN):
            assert not any(data[AZ.trac_off(pat, t) + m + 7] & 1 for t in range(8)
                           for m in (AZ.MASK_PLAY, AZ.MASK_REC1, AZ.MASK_REC2, AZ.MASK_REC3)), (bank, pat)
        for p in (0, 4):
            part = data[AZ.PART_BASE + p * AZ.PART_STRIDE:AZ.PART_BASE + p * AZ.PART_STRIDE + PART_BYTES]
            moved = [i for i in range(PART_BYTES) if part[i] != tpart[i]]
            if mtrx:
                allowed = {AZ.REC_SETUP_OFF + t * 12 + AZ.REC_FIELDS.index(f) for t in range(8)
                           for f in ("INAB", "INCD", "SRC3")}
                assert set(moved) <= allowed, (bank, p, [hex(i) for i in moved if i not in allowed][:8])
                assert all(part[AZ.REC_SETUP_OFF + t * 12 + AZ.REC_FIELDS.index("SRC3")] == SRC3_MTRX
                           for t in range(8))
            else:
                assert not moved, (bank, p, [hex(i) for i in moved][:8])
        assert (sum(data[0x10:-2]) & 0xFFFF) == int.from_bytes(data[-2:], "big"), "bank checksum"


def write_project_text(dest, bits, clock="internal"):
    """Transport and program change in; MIDI clock in only with clock "midi" (the unit is the clock otherwise, as
    Bryan T plays it); 128 BPM; RECORD_24BIT only when --bits is given."""
    import ot_matrix as M
    settings = M.test_settings(1)
    settings["TEMPOx24"] = BPM * 24
    settings["MIDI_CLOCK_RECEIVE"] = 1 if clock == "midi" else 0
    if bits:
        settings["RECORD_24BIT"] = 1 if bits == 24 else 0
    return M.stamp_text(dest, settings, M.TEST_STATES)


def cmd_proj(a):
    src, dest = pathlib.Path(a.template), pathlib.Path(a.dest)
    if not (src / "project.work").is_file():
        sys.exit(f"{src} is not a project directory")
    if dest.exists():
        sys.exit(f"{dest} exists; refusing to overwrite")
    for b in (SELF_BANK, MTRX_BANK):
        if not (src / f"bank{b + 1:02d}.work").is_file():
            sys.exit(f"{src}: no bank{b + 1:02d}.work")
    tbank = (src / "bank01.work").read_bytes()
    bad = template_ok(tbank)
    if bad:
        sys.exit(f"{src} is not a sound-on-sound template (bank A, part 1):\n  " + "\n  ".join(bad)
                 + "\nSet the eight tracks up on the unit (FLEX on their own buffers, INAB A B, INCD -, RLEN 16, "
                   "SRC3 the track itself) and SAVE PROJECT.")
    shutil.copytree(src, dest)
    changed = write_project_text(dest, a.bits, a.clock)
    write_banks(dest, tbank)
    check_banks(dest, tbank)
    raw = (dest / "project.work").read_text(errors="replace")
    depth = 24 if "RECORD_24BIT=1" in raw else 16
    plan = {"bpm": BPM, "bits": depth, "clock": a.clock, "pc_channel": 1, "rungs": rungs(),
            "settings_changed": changed, "template": str(src)}
    (dest / PLAN_FILE).write_text(json.dumps(plan, indent=1))
    print(f"{dest}: from {src}'s part, banks A (SELF) and B (MTRX), {depth}-bit recorders, "
          f"{'the unit' if a.clock == 'internal' else 'MIDI'} as the clock, {len(rungs())} rungs a USB phase; copy the "
          "folder into a set on the card and load it")


# ------------------------------------------------------------------------------------------------------ the unit --

class Lockup(Exception):
    pass


class Unit:
    """The meters over USB, raising instead of degrading once the image's blocks are known."""

    def __init__(self):
        import load_meter as L
        import task_meter as T
        self.L, self.T = L, T
        self.dev = L.libusb_device()
        self.has_fp = self._try(lambda: self.block(T.FP_BLOCK, T.FP_BYTES))
        self.has_mtrx = self._try(lambda: self.mask(0))
        self.has_peek = self._try(lambda: self.peek(PLANE, 4))
        if not self._try(lambda: self.block(T.STATS_BLOCK, T.STATS_BYTES)):
            sys.exit("no LOAD METER in this image (block 0 STALLs): build a _bt_stress_* remix")
        if not self._try(lambda: self.block(T.LEDGER_BLOCK, T.LEDGER_BYTES)):
            sys.exit("no task ledger (block 4 STALLs): the image needs BRAIN and FRAME PROFILE (USB_PROBES)")

    @staticmethod
    def _try(f):
        try:
            f()
            return True
        except Exception:  # noqa: BLE001 -- a STALL: the image does not carry it
            return False

    def _ctrl(self, w, off, n):
        return bytes(self.dev.ctrl_transfer(0xc0, 0x57, w, off, n, timeout=1000))

    def block(self, b, size):
        return self.L.read_block(self._ctrl, b, size)

    def read(self):
        """(ledger, stats, fp) or Lockup."""
        T = self.T
        try:
            led = T.decode_ledger(self.block(T.LEDGER_BLOCK, T.LEDGER_BYTES))
            st = T.decode_stats(self.block(T.STATS_BLOCK, T.STATS_BYTES))
            fp = T.decode_fp(self.block(T.FP_BLOCK, T.FP_BYTES)) if self.has_fp else None
        except Exception as e:  # noqa: BLE001
            raise Lockup(f"the unit stopped answering USB ({e})") from e
        return led, st, fp

    def snapshot(self):
        try:
            return AZ.usb_snapshot(self.dev)
        except Exception as e:  # noqa: BLE001
            raise Lockup(f"the unit stopped answering USB ({e})") from e

    def peek(self, addr, n):
        """n bytes of RAM at addr (0xc0/0x59, at most 255 a request, never a multiple of 64)."""
        out = b""
        while n:
            k = min(n, 255)
            if k % 64 == 0:
                k -= 1
            out += bytes(self.dev.ctrl_transfer(0xc0, 0x59, (addr + len(out)) & 0xFFFF, (addr + len(out)) >> 16,
                                                k, timeout=1000))
            n -= k
        return out

    def plane(self):
        try:
            return self.peek(PLANE, PLANE_BYTES)
        except Exception as e:  # noqa: BLE001
            raise Lockup(f"the unit stopped answering USB ({e})") from e

    def mask(self, rec, value=None):
        """REC MATRIX's mask for recorder rec (0-7), set first when value is given (0xc0/0x58)."""
        idx = rec | (0x100 if value is not None else 0)
        raw = bytes(self.dev.ctrl_transfer(0xc0, 0x58, (value or 0) & 0xFFFF, idx, 4, timeout=1000))
        return struct.unpack(">i", raw)[0] & 0xFFFF

    def set_masks(self, density):
        f = DENSITIES[density]
        for t in range(8):
            want = f(t)
            got = self.mask(t, want)
            if got != want:
                sys.exit(f"recorder {t + 1}: set mask {want:#06x}, read back {got:#06x}")


# ---------------------------------------------------------------------------------------- the host's stream --

class Stream:
    """The host side with USB on: a 997 Hz sine at -20 dBFS on every channel into the unit (USB IN A-D) and the
    unit's output taken, channel 1 (MAIN L) kept in a 90 s ring with its sample index. One device, one clock: the
    tone comes back at 997 Hz with a fixed latency, so a constant phase per block, and a lost or repeated block is
    a step (ot_usb_soak.py's method)."""

    RING_S = 90

    def __init__(self, device, dirs=("in", "out")):
        """dirs: "in" streams the tone into the unit (USB IN), "out" takes the unit's output (USB OUT)."""
        import numpy as np
        import sounddevice as sd
        self.np = np
        self.dirs = tuple(dirs)
        devs = sd.query_devices()
        outs = [i for i, d in enumerate(devs) if device.lower() in d["name"].lower() and d["max_output_channels"] >= 2]
        ins = [i for i, d in enumerate(devs) if device.lower() in d["name"].lower() and d["max_input_channels"] >= 2]
        if len(outs) != 1 or len(ins) != 1:
            sys.exit(f"want one device matching {device!r} with inputs and outputs: "
                     + ", ".join(f"{d['name']!r} in={d['max_input_channels']} out={d['max_output_channels']}"
                                 for d in devs))
        self.name, self.ch = devs[outs[0]]["name"], devs[outs[0]]["max_output_channels"]
        self.in_ch = devs[ins[0]]["max_input_channels"]
        amp, w = 10 ** (TONE_DBFS / 20), 2 * math.pi * TONE_HZ / FS
        self.w = w
        self.phase = 0
        self.lock = threading.Lock()
        self.chunks, self.n_in = [], 0

        def out_cb(outdata, frames, _t, _status):
            n = np.arange(self.phase, self.phase + frames)
            outdata[:] = (amp * np.sin(w * n)).astype(np.float32)[:, None]
            self.phase += frames

        def in_cb(indata, frames, _t, _status):
            with self.lock:
                self.chunks.append((self.n_in, indata[:, 0].copy()))
                self.n_in += frames
                keep = self.RING_S * FS
                while self.chunks and self.chunks[0][0] + len(self.chunks[0][1]) < self.n_in - keep:
                    self.chunks.pop(0)
        self.ostream = self.istream = None
        if "in" in self.dirs:
            self.ostream = sd.OutputStream(device=outs[0], channels=self.ch, samplerate=FS, dtype="float32",
                                           callback=out_cb)
            self.ostream.start()
        if "out" in self.dirs:
            self.istream = sd.InputStream(device=ins[0], channels=self.in_ch, samplerate=FS, dtype="float32",
                                          callback=in_cb)
            self.istream.start()

    def mark(self):
        with self.lock:
            return self.n_in

    def segment(self, a, b):
        with self.lock:
            parts = [(s, x) for s, x in self.chunks if s + len(x) > a and s < b]
        if not parts:
            return a, self.np.zeros(0)
        x = self.np.concatenate([x for _s, x in parts])
        start = parts[0][0]
        lo = max(a, start)
        return lo, x[lo - start:lo - start + (b - lo)]

    def close(self):
        for s in (self.ostream, self.istream):
            if s is not None:
                s.stop(); s.close()


def tone_check(lo, x, w, block=4410, slip=0.25):
    """MAIN's tone over [lo, lo + len(x)): per 0.1 s block a least-squares fit of the 997 Hz tone at the absolute
    sample index. -> level (dBFS), residual relative to the tone (dB, median and max), slips (|phase step| >= 0.25
    sample), drops (a block with the tone under 1% of the run's median), and the block count."""
    import numpy as np
    blocks = []
    for s in range(0, len(x) - block + 1, block):
        y = x[s:s + block].astype(np.float64)
        idx = np.arange(lo + s, lo + s + block, dtype=np.float64)
        X = np.column_stack((np.sin(w * idx), np.cos(w * idx), np.ones(block)))
        coef, *_ = np.linalg.lstsq(X, y, rcond=None)
        A = math.hypot(coef[0], coef[1])
        res = math.sqrt(float(np.mean((y - X @ coef) ** 2)))
        blocks.append((A, math.atan2(coef[1], coef[0]), res))
    if not blocks:
        return None
    amps = sorted(b[0] for b in blocks)
    med = amps[len(amps) // 2]
    if med < 10 ** (-60 / 20):
        return {"blocks": len(blocks), "level_db": round(20 * math.log10(max(med, 1e-12)), 1), "no_tone": True}
    drops = sum(1 for b in blocks if b[0] < 0.01 * med)
    slips, prev = 0, None
    thdn = []
    for A, phi, res in blocks:
        if A < 0.01 * med:
            prev = None
            continue
        thdn.append(20 * math.log10(max(res, 1e-15) / (A / math.sqrt(2))))
        if prev is not None:
            step = -(((phi - prev) + math.pi) % (2 * math.pi) - math.pi) / w
            if abs(step) >= slip:
                slips += 1
        prev = phi
    return {"blocks": len(blocks), "level_db": round(20 * math.log10(med), 2), "slips": slips, "drops": drops,
            "thdn_db": round(statistics.median(thdn), 1) if thdn else None,
            "thdn_max_db": round(max(thdn), 1) if thdn else None}


# ------------------------------------------------------------------------------------------------- the screen --

def pixels(plane):
    """Rows of 0/1, screen orientation: pixel (x, y) is column 63 - y of row x (tools/emu/lcd_view.py)."""
    return [[(plane[x * 8 + (63 - y) // 8] >> (7 - (63 - y) % 8)) & 1 for x in range(128)] for y in range(64)]


GLYPHS = {                                            # PLAYBACK page, under each track's F (port, 1 Nov 2026)
    "stop": ("###", "###", "###"),
    "rec": (".#.", "###", ".#."),
    "play": ("#..", "##.", "###", "##.", "#.."),
}


def _find(band, glyph):
    h, w = len(glyph), len(glyph[0])
    want = [[c == "#" for c in row] for row in glyph]
    for y in range(len(band) - h + 1):
        for x in range(len(band[0]) - w + 1):
            if all(band[y + i][x + j] == want[i][j] for i in range(h) for j in range(w)):
                if glyph is GLYPHS["play"] and any(band[y + i][x + w] for i in range(h) if x + w < len(band[0])):
                    continue
                return True
    return False


def track_states(rows):
    """Per track: 'recplay', 'rec', 'play', 'stop' or '?' from the glyph under its F (tracks 1-4 on the left
    edge, 5-8 on the right; the selected track's band is drawn inverted)."""
    out = []
    for t in range(8):
        x0, x1 = (0, 10) if t < 4 else (118, 128)
        band = [row[x0:x1] for row in rows[16 * (t % 4):16 * (t % 4) + 16]]
        if sum(map(sum, band)) > len(band) * len(band[0]) // 2:
            band = [[1 - v for v in row] for row in band]
        rec, play, stop = _find(band, GLYPHS["rec"]), _find(band, GLYPHS["play"]), _find(band, GLYPHS["stop"])
        out.append("recplay" if rec and play else "rec" if rec else "play" if play else "stop" if stop else "?")
    return out


def expected_states(r):
    n = 0 if r["ladder"] == "BASE" else (1 if r.get("drop") is not None else r["n"])
    return ["recplay"] * n + ["stop"] * (8 - n)


class Screen:
    """Each poll's picture: how often it changes, its longest still stretch, and the tracks' glyphs against the
    rung's expectation (a mismatch must hold for two polls running: a read can catch the UI mid-draw)."""

    def __init__(self, want, t_start=None, bpm=BPM, on_event=None):
        self.want = want
        self.t_start = t_start                         # the transport's START (monotonic), for bar positions
        self.bar_s = 240.0 / bpm
        self.on_event = on_event
        self.last = list(want)                         # each track's last readable glyph
        self.events = []                               # [s after START, bar.beat, track, from, to]
        self.stop_run = [0] * 8
        self.stopped = []                              # tracks wanted recording that held the stopped glyph
        self.polls = self.changes = 0
        self.prev = None
        self.t_still = self.t0 = None
        self.longest = 0.0
        self.counts = [{} for _ in range(8)]
        self.miss_run = [0] * 8
        self.misses = [0] * 8

    def add(self, plane, now):
        if self.t0 is None:
            self.t0 = self.t_still = now
        self.polls += 1
        if self.prev is not None and plane != self.prev:
            self.changes += 1
            self.t_still = now
        self.longest = max(self.longest, now - self.t_still)
        self.prev = plane
        for t, st in enumerate(track_states(pixels(plane))):
            self.counts[t][st] = self.counts[t].get(st, 0) + 1
            if st == "?":                              # a read caught mid-draw: neither a match nor a miss
                continue
            if st != self.last[t]:
                ts = now - self.t_start if self.t_start is not None else None
                bar = round(ts / self.bar_s + 1, 2) if ts is not None else None
                ev = [round(ts, 2) if ts is not None else None, bar, t + 1, self.last[t], st]
                self.events.append(ev)
                if self.on_event:
                    self.on_event(ev)
                self.last[t] = st
            if st != self.want[t]:
                self.miss_run[t] += 1
                if self.miss_run[t] == 2:
                    self.misses[t] += 1
            else:
                self.miss_run[t] = 0
            if self.want[t] == "recplay" and st == "stop":
                self.stop_run[t] += 1
                if self.stop_run[t] == 2 and t + 1 not in self.stopped:
                    self.stopped.append(t + 1)
            else:
                self.stop_run[t] = 0

    def result(self, now):
        secs = max(now - (self.t0 if self.t0 is not None else now), 1e-6)
        return {"polls": self.polls, "updates_s": round(self.changes / secs, 2),
                "longest_still_s": round(self.longest, 2),
                "tracks": [{"want": w, "seen": c, "missed": m} for w, c, m in zip(self.want, self.counts, self.misses)],
                "events": self.events, "stopped": self.stopped}


# ---------------------------------------------------------------------------------------------- a measurement --

def measure(unit, secs, interval=0.25, flip=None, screen=None, usb_every=None, until=None):
    """usb_every: snapshot the USB counters every that many seconds into series["usb"] ([t, IN packets/s, OUT
    frames/s, {counter: delta}]). until: a callable checked each poll; True ends the measurement early."""
    """Poll for secs. -> dict with the task shares (task_meter's Accumulator), the frame interrupt's mean and worst
    frame per LOAD METER window, FRAME PROFILE's sections per window, and every window (`series`)."""
    T = unit.T
    acc = T.Accumulator()
    t0 = time.monotonic()
    lm_seq, lm_moved = None, t0
    fp_seq = None
    wins, fps = [], []                                 # (t, mean us, longest us), (t, {section: us})
    state, next_flip = 0, (t0 + flip if flip else None)
    usb_rows, usb_prev, usb_t = [], (unit.snapshot() if usb_every else None), t0
    while True:
        led, st, fp = unit.read()
        now = time.monotonic()
        acc.add(led, st, fp)
        if screen is not None:
            screen.add(unit.plane(), time.monotonic())
        if st["seq"] != lm_seq:
            if lm_seq is not None and st["count"]:
                wins.append((now - t0, st["sum"] / st["count"] / CF_HZ * 1e6, st["longest"] / CF_HZ * 1e6))
            lm_seq, lm_moved = st["seq"], now
        elif now - lm_moved > 3.0:
            raise Lockup("LOAD METER's window count stopped for 3 s: the frame engine stopped")
        if fp and fp["seq"] != fp_seq:
            if fp_seq is not None and fp["frames"]:
                n = fp["frames"]
                d = {name: c / n / CF_HZ * 1e6 for name, c in zip(T.SECTIONS, fp["sec"])}
                d["usb out"] = fp["uout"] / n / CF_HZ * 1e6
                d["usb in"] = fp["uin"] / n / CF_HZ * 1e6
                fps.append((now - t0, d))
            fp_seq = fp["seq"]
        if usb_every and now - usb_t >= usb_every:
            snap = unit.snapshot()
            if usb_prev is not None:
                dt = now - usb_t
                pin, pout = usb_rates(usb_prev, snap, dt)
                usb_rows.append([round(now - t0, 2), pin and round(pin), pout and round(pout),
                                 errors_of(AZ.usb_delta(usb_prev, snap))])
            usb_prev, usb_t = snap, now
        if until is not None and until():
            break
        if next_flip and now >= next_flip:
            state ^= 1
            try:
                unit.set_masks("DENSE" if state else "DIAG")
            except Exception as e:  # noqa: BLE001
                raise Lockup(f"the unit stopped answering USB ({e})") from e
            next_flip += flip
        if now - t0 >= secs:
            break
        time.sleep(interval)
    res = acc.result()
    if screen is not None:
        sc = screen.result(time.monotonic())
    out = {"seconds": round(res["seconds"], 2), "frame_irq": res["frame_irq"],
           "share": {k: round(v, 5) for k, v in res["share"].items()},
           "profile": {k: (round(v, 2) if isinstance(v, float) else v) for k, v in (res["profile"] or {}).items()},
           "windows": len(wins),
           "series": {"lm": [[round(t, 2), round(m, 1), round(l, 1)] for t, m, l in wins],
                      "fp": [[round(t, 2), {k: round(v, 1) for k, v in d.items()}] for t, d in fps],
                      "usb": usb_rows}}
    if screen is not None:
        out["screen"] = sc
    if wins:
        means = [w[1] for w in wins]
        worst = max(wins, key=lambda w: w[2])
        out.update({"frame_us": round(statistics.fmean(means), 1), "frame_us_max_window": round(max(means), 1),
                    "worst_us": round(worst[2], 1), "late_windows": sum(1 for w in wins if w[2] >= FRAME_US)})
        if fps:
            near = min(fps, key=lambda f: abs(f[0] - worst[0]))[1]
            med = {k: statistics.median(f[1][k] for f in fps) for k in near}
            rise = {k: near[k] - med[k] for k in near}
            k = max(rise, key=rise.get)
            out["spike"] = {"section": k, "rise_us": round(rise[k], 1), "at_s": round(worst[0], 1)}
    return out


# ------------------------------------------------------------------------------------------------------- a run --

def counter(snap, host_in, key):
    side = snap.get(host_in)
    return side[key] if side else None


def usb_rates(u0, u1, secs):
    """(IN packets a second, OUT frames a second) the host moved over the rung, None for a side the image lacks."""
    def rate(host_in, key):
        a, b = counter(u0, host_in, key), counter(u1, host_in, key)
        return None if a is None or b is None else ((b - a) % (1 << 32)) / secs
    return rate(True, "pkts"), rate(False, "consumed")


def errors_of(delta):
    return {k: int(v) for k, v in delta.items() if v not in ("", "0") and not k.endswith("consumed")}


def verdict(rec):
    if rec.get("result") in TERMINAL:
        return rec["result"]
    tags = []
    if rec.get("late_windows"):
        tags.append("LATE")
    if rec.get("usb_errors"):
        tags.append("USB ERR")
    if rec.get("audio_bad"):
        tags.append("AUDIO")
    sc = rec.get("screen")
    if sc and sc["longest_still_s"] >= STILL_S:
        tags.append("SCREEN FROZEN")
    if sc and any(t["missed"] for t in sc["tracks"]):
        tags.append("REC/PLAY")
    return " ".join(tags) or "CLEAN"


def load_done(path):
    if not path.exists():
        return []
    return [json.loads(l) for l in path.read_text().splitlines() if l.strip()]


def cmd_run(a):
    import ot_ladder as L
    dest = pathlib.Path(a.dest)
    plan = json.loads((dest / PLAN_FILE).read_text())
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"{a.label}.jsonl"
    done = load_done(path)
    if done and not a.resume:
        sys.exit(f"{path} exists: --resume to continue it, or another LABEL")
    skip = {d["rung"] for d in done}
    ended = {(d["usb"], d["ladder"]) for d in done if d["result"] in TERMINAL}
    unit = Unit()
    ladders = [x.strip().upper() for x in a.ladders.split(",") if x.strip()]
    if not (unit.has_mtrx and unit.has_fp):
        dropped = [x for x in ladders if x != "SELF"]
        ladders = [x for x in ladders if x == "SELF"]
        if dropped:
            print(f"no REC MATRIX test command in this image (0xc0/0x58): skipping {', '.join(dropped)}")
    if not unit.has_peek:
        print("no 0xc0/0x59 in this image: the screen is not watched (build with FRAME PROFILE)")
    else:
        sts = track_states(pixels(unit.plane()))
        if "?" in sts:
            sys.exit(f"the screen's track glyphs read {sts}: leave the unit on the PLAYBACK page (track 1), "
                     "then run again")
    clock = make_clock(plan, a.midi)
    stream = None
    print(f"writing {path}  ({plan.get('bits', 16)}-bit recorders)")
    try:
        for usb in [x.strip().lower() for x in a.usb.split(",")]:
            base_thdn = None
            if usb == "on":
                stream = Stream(a.usb_in)
                u0 = unit.snapshot(); time.sleep(1.0); u1 = unit.snapshot()
                in_ref, out_ref = usb_rates(u0, u1, 1.0)
                if not in_ref or not out_ref:
                    sys.exit(f"USB ON asked, but IN moves {in_ref} packets/s and OUT {out_ref} frames/s: check the "
                             "device and that USB IN and OUT are on")
                print(f"USB ON: {TONE_HZ:g} Hz at {TONE_DBFS:g} dBFS into {stream.ch} channels of {stream.name!r}, "
                      f"IN {in_ref:.0f} packets/s, OUT {out_ref:.0f} frames/s; MAIN L taken back")
                base_thdn = next((d.get("audio", {}).get("thdn_db") for d in done
                                  if d["usb"] == "on" and d["ladder"] == "BASE" and d.get("audio")), None)
            else:
                pin, pout = usb_rates(*_twice(unit), 1.0)
                if pin or pout:
                    sys.exit(f"USB OFF asked, but the host is streaming (IN {pin}/s, OUT {pout} frames/s): quit "
                             "every app using the Octatrack's audio (Logic, the aggregate device's users)")
                print("USB OFF: no host stream")
            for r in rungs(ladders):
                rid = rung_id(usb, r)
                if rid in skip or (usb, r["ladder"]) in ended:
                    continue
                rec = {"rung": rid, "usb": usb, "ladder": r["ladder"], "n": r["n"], "program": r["program"],
                       "density": r["density"], "drop": r.get("drop") is not None, "bits": plan.get("bits", 16),
                       "time": time.strftime("%Y-%m-%d %H:%M:%S")}
                try:
                    clock.stop(); time.sleep(0.2); clock.stop(); time.sleep(0.5)
                    if r["density"]:
                        unit.set_masks("DIAG" if r["ladder"] == "SWITCH" else r["density"])
                    if r.get("drop") is not None:          # the heavy rung first, then straight to the light one
                        clock.pc(plan["pc_channel"], r["drop"]); time.sleep(0.8)
                        clock.start(); time.sleep(a.settle)
                        clock.stop(); time.sleep(0.2); clock.stop(); time.sleep(0.5)
                    clock.pc(plan["pc_channel"], r["program"]); time.sleep(0.8)
                    clock.start()
                    time.sleep(a.settle)
                    u0 = unit.snapshot()
                    m0 = stream.mark() if stream else None
                    t0 = time.monotonic()
                    rec.update(measure(unit, a.secs if r["ladder"] != "SWITCH" else 2 * a.secs,
                                       flip=a.flip if r["ladder"] == "SWITCH" else None,
                                       screen=Screen(expected_states(r)) if unit.has_peek else None))
                    secs = time.monotonic() - t0
                    u1 = unit.snapshot()
                    rec["usb_errors"] = errors_of(AZ.usb_delta(u0, u1))
                    if stream:
                        pin, pout = usb_rates(u0, u1, secs)
                        rec["usb_rates"] = {"in_pkts_s": pin and round(pin), "out_frames_s": pout and round(pout)}
                        if pin is not None and pin < 0.5 * in_ref:
                            rec["result"] = "USB IN STOPPED"
                        elif pout is not None and pout < 0.5 * out_ref:
                            rec["result"] = "USB OUT STOPPED"
                        lo, x = stream.segment(m0, stream.mark())
                        au = tone_check(lo, x, stream.w) if a.audio else None
                        if au:
                            rec["audio"] = au
                            if r["ladder"] == "BASE" and not r.get("tag") and au.get("thdn_db") is not None:
                                base_thdn = au["thdn_db"]
                            rec["audio_bad"] = bool(au.get("no_tone") or au.get("slips") or au.get("drops") or (
                                base_thdn is not None and au.get("thdn_max_db") is not None
                                and au["thdn_max_db"] > base_thdn + 10))
                    rec["result"] = verdict(rec)
                except Lockup as e:
                    rec.update({"result": "LOCKUP", "detail": str(e)})
                with path.open("a") as f:
                    f.write(json.dumps(rec) + "\n")
                print(line(rec), flush=True)
                if rec["result"] in TERMINAL:
                    print(f"\n{rec['result']} at {rid}{': ' + rec['detail'] if rec.get('detail') else ''}\n"
                          "Power-cycle the unit (it reloads the project), then run the same command with --resume. "
                          f"The rest of USB {usb.upper()}/{r['ladder']} is skipped.")
                    return
            if stream:
                stream.close(); stream = None
    finally:
        try:
            clock.stop(); time.sleep(0.2); clock.stop()
        except Exception:  # noqa: BLE001 -- the unit may be gone
            pass
        clock.close()
        if stream:
            stream.close()
    print(f"done: python3 tools/hw/rec_stress.py report {a.label}")


def _twice(unit):
    a = unit.snapshot(); time.sleep(1.0); b = unit.snapshot()
    return a, b


def result_of(rec):
    """The result, with an earlier file's OVER read as LATE."""
    return rec["result"].replace("OVER", "LATE")


def scr_text(rec):
    sc = rec.get("screen")
    if not sc:
        return ""
    bad = [f"T{t + 1} {tr['missed']}x {max(tr['seen'], key=tr['seen'].get)}" for t, tr in enumerate(sc["tracks"])
           if tr["missed"]]
    return (f"  screen {sc['updates_s']}/s still {sc['longest_still_s']}s"
            + (f" MISSED {', '.join(bad)}" if bad else ""))


def line(rec):
    res = result_of(rec)
    if rec["result"] in ("LOCKUP",):
        return f"{rec['rung']:26s} LOCKUP  {rec.get('detail', '')}"
    sh, p = rec.get("share", {}), rec.get("profile", {})
    au = rec.get("audio")
    aud = ""
    if au:
        aud = ("  audio NO TONE" if au.get("no_tone") else
               f"  audio {au['level_db']:+.1f} dBFS thd+n {au['thdn_db']} (max {au['thdn_max_db']}) "
               f"slips {au['slips']} drops {au['drops']}")
    return (f"{rec['rung']:26s} {res:10s} frame {rec.get('frame_us', 0):5.1f} us "
            f"({100 * rec.get('frame_us', 0) / FRAME_US:4.1f}%)  worst {rec.get('worst_us', 0):5.1f}  "
            f"IDLE {100 * sh.get('IDLE', 0):4.1f}%  rec {p.get('recorder', 0):5.1f}  voices {p.get('voices', 0):5.1f}"
            + aud + scr_text(rec) + (f"  {rec['usb_errors']}" if rec.get("usb_errors") else "")
            + (f"  rates {rec['usb_rates']}" if res.startswith("USB") and rec.get("usb_rates") else ""))


# ------------------------------------------------------------------------------------------------- the report --

def hard_of(rec):
    res = result_of(rec)
    return next((h for h in HARD if h in res), None)


def cmd_report(a):
    runs = {lab: load_done(OUT / f"{lab}.jsonl") for lab in a.labels}
    for lab, recs in runs.items():
        if not recs:
            sys.exit(f"no records for {lab} in {OUT}")
    print("## Scorecard\n")
    print("Each ladder climbed to its first hard failure (USB ERR, AUDIO, USB IN/OUT STOPPED or LOCKUP): the top "
          "rung below it, with the frame interrupt's mean load there, then the failure. LATE (a frame ran past "
          "362.8 us) is not a failure; its first rung is noted. DROP: x8 played, then straight to x1.\n")
    keys = []
    for recs in runs.values():
        for r in recs:
            if r["ladder"] != "BASE" and (r["usb"], r["ladder"]) not in keys:
                keys.append((r["usb"], r["ladder"]))
    keys.sort(key=lambda k: (k[0] != "off", LADDERS.index(k[1])))
    print("| ladder | " + " | ".join(a.labels) + " |")
    print("|---|" + "---|" * len(a.labels))
    for usb, lad in keys:
        cells, drops = [], []
        for lab in a.labels:
            recs = [r for r in runs[lab] if r["usb"] == usb and r["ladder"] == lad]
            climb = sorted((r for r in recs if not r.get("drop")), key=lambda r: r["n"])
            drop = next((r for r in recs if r.get("drop")), None)
            drops.append(result_of(drop) if drop else "-")
            if not climb:
                cells.append("-"); continue
            if lad == "SWITCH":
                cells.append(result_of(climb[0])); continue
            top, fail, late = None, "", None
            for r in climb:
                h = hard_of(r)
                if h:
                    fail = f"; {h} at x{r['n']}"; break
                top = r
                if late is None and "LATE" in result_of(r):
                    late = r["n"]
            if not fail and climb[-1]["n"] < 8:
                fail = f"; not run past x{climb[-1]['n']}"
            head = (f"x{top['n']} ({100 * top.get('frame_us', 0) / FRAME_US:.0f}%)" if top else "none")
            cells.append(head + fail + (f"; LATE from x{late}" if late else ""))
        print(f"| USB {usb.upper()} {lad} | " + " | ".join(cells) + " |")
        if lad != "SWITCH" and any(d != "-" for d in drops):
            print(f"| USB {usb.upper()} {lad} DROP | " + " | ".join(drops) + " |")
    for lab, recs in runs.items():
        bits = {r.get("bits", 16) for r in recs}
        print(f"\n## {lab} ({'/'.join(str(b) for b in sorted(bits))}-bit recorders)\n")
        print("| rung | result | frame us | % frame | worst us | IDLE | recorder | voices | usb out | usb in "
              "| audio | screen |")
        print("|---|---|---|---|---|---|---|---|---|---|---|---|")
        for r in recs:
            if r["result"] == "LOCKUP":
                print(f"| {r['rung']} | LOCKUP | | | | | | | | | {r.get('detail', '')} | |"); continue
            p, sh, au = r.get("profile", {}), r.get("share", {}), r.get("audio")
            f = lambda k: f"{p[k]:.1f}" if isinstance(p.get(k), (int, float)) else ""
            aud = ("" if not au else "no tone" if au.get("no_tone") else
                   f"{au['thdn_db']} dB, {au['slips']} slips, {au['drops']} drops")
            print(f"| {r['rung']} | {result_of(r)} | {r.get('frame_us', '')} | "
                  f"{100 * r.get('frame_us', 0) / FRAME_US:.1f} | {r.get('worst_us', '')} | "
                  f"{100 * sh.get('IDLE', 0):.1f}% | {f('recorder')} | {f('voices')} | "
                  f"{f('usb out shim')} | {f('usb in frame')} | {aud} | {scr_text(r).strip()} |")


class TransportOnly:
    """START, STOP and program changes over MIDI, no clock: the unit runs on its own (ot_ladder.Clock's calls)."""

    def __init__(self, port):
        import ot_midi
        self.out = ot_midi.Out(port)

    def start(self):
        self.out.send([0xFA])

    def stop(self):
        self.out.send([0xFC])

    def pc(self, ch, prog):
        self.out.send([0xC0 | (ch - 1), prog & 0x7f])

    def close(self):
        pass


def make_clock(plan, port):
    """MIDI clock and transport for a project made with --clock midi (and every project before 1 Nov 2026, which
    had clock receive on); transport only for --clock internal."""
    if plan.get("clock", "midi") == "midi":
        import ot_ladder as L
        return L.Clock(plan["bpm"], port)
    return TransportOnly(port)


def parse_rung(name):
    """'MED x3', 'SELF x8', 'BASE' -> a rung as rungs() makes them."""
    m = re.fullmatch(r"\s*(BASE|SELF|DIAG|MED|DENSE)(?:\s*X\s*(\d))?\s*", name.upper())
    if not m or (m.group(1) != "BASE" and not m.group(2)):
        sys.exit(f"--rung {name!r}: want BASE or SELF / DIAG / MED / DENSE x1-x8")
    lad, n = m.group(1), int(m.group(2) or 0)
    if lad == "BASE":
        return {"ladder": "BASE", "n": 0, "program": 16 * SELF_BANK + BASE_PATTERN, "density": None}
    if not 1 <= n <= 8:
        sys.exit("x1 to x8")
    return {"ladder": lad, "n": n, "program": prog(lad, n), "density": lad if lad in DENSITIES else None}


def rung_name(r):
    return "BASE" if r["ladder"] == "BASE" else f"{r['ladder']} x{r['n']}"


def start_rung(clock, unit, plan, r, settle):
    """STOP twice, the rung's masks, the program change, START, settle. -> START's monotonic time."""
    clock.stop(); time.sleep(0.2); clock.stop(); time.sleep(0.5)
    if r["density"]:
        unit.set_masks(r["density"])
    clock.pc(plan["pc_channel"], r["program"]); time.sleep(0.8)
    clock.start()
    t = time.monotonic()
    time.sleep(settle)
    return t


def open_usb(a, unit):
    """The host side for --usb on / in / out / off. -> (stream or None, IN packets/s, OUT frames/s at the start)."""
    mode = a.usb.lower()
    if mode not in ("on", "in", "out", "off"):
        sys.exit("--usb on, in, out or off")
    if mode == "off":
        pin, pout = usb_rates(*_twice(unit), 1.0)
        if pin or pout:
            sys.exit(f"--usb off, but the host is streaming (IN {pin}/s, OUT {pout} frames/s): quit every app using "
                     "the Octatrack's audio")
        print("USB OFF: no host stream")
        return None, None, None
    dirs = {"on": ("in", "out"), "in": ("in",), "out": ("out",)}[mode]
    stream = Stream(a.usb_in, dirs)
    u0 = unit.snapshot(); time.sleep(1.0); u1 = unit.snapshot()
    pin, pout = usb_rates(u0, u1, 1.0)
    for d, rate in (("in", pin), ("out", pout)):
        if d in dirs and not rate:
            stream.close()
            sys.exit(f"--usb {mode}: USB {d.upper()} is not moving; check the device and that it is on")
    print(f"USB {mode.upper()}: IN {pin:.0f} packets/s, OUT {pout:.0f} frames/s" if pin is not None and pout is not None
          else f"USB {mode.upper()}: IN {pin} packets/s, OUT {pout} frames/s")
    return stream, (pin if "in" in dirs else None), (pout if "out" in dirs else None)


def usb_dead(series, in_ref, out_ref):
    """'USB IN STOPPED' / 'USB OUT STOPPED' when the last two 0.5 s rows fell under half the start's rate."""
    rows = series.get("usb", [])[-2:]
    if len(rows) < 2:
        return None
    if in_ref and all(r[1] is not None and r[1] < 0.5 * in_ref for r in rows):
        return "USB IN STOPPED"
    if out_ref and all(r[2] is not None and r[2] < 0.5 * out_ref for r in rows):
        return "USB OUT STOPPED"
    return None


def print_event(ev):
    t, bar, trk, old, new = ev
    print(f"    {t:7.2f} s  bar {bar:6.2f}  T{trk}  {old} -> {new}", flush=True)


def _context(rec):
    """The frame windows and USB rows around a stop, for the console."""
    lm = rec.get("series", {}).get("lm", [])[-3:]
    us = rec.get("series", {}).get("usb", [])[-2:]
    return (f"last windows (s, mean, worst us): {lm}; last USB rows (s, IN/s, OUT/s, counters): {us}")


def cmd_hold(a):
    import ot_ladder as L
    plan = json.loads((pathlib.Path(a.dest) / PLAN_FILE).read_text())
    r = parse_rung(a.rung)
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"{a.label}.jsonl"
    unit = Unit()
    if r["density"] and not unit.has_mtrx:
        sys.exit("no REC MATRIX test command in this image")
    if not unit.has_peek:
        sys.exit("no 0xc0/0x59 in this image: hold needs the screen")
    clock = make_clock(plan, a.midi)
    stream = None
    print(f"hold {rung_name(r)}, USB {a.usb.upper()}, {a.minutes:g} min x up to {a.repeats}; writing {path}")
    total_s = total_stops = 0.0
    try:
        stream, in_ref, out_ref = open_usb(a, unit)
        for rep_i in range(1, a.repeats + 1):
            print(f"  hold {rep_i}:")
            t_start = start_rung(clock, unit, plan, r, a.settle)
            held, seg, stops = 0.0, 0, 0
            while held < a.minutes * 60:
                seg += 1
                scr = Screen(expected_states(r), t_start, plan["bpm"], on_event=print_event)
                t0 = time.monotonic()
                rec = {"kind": "hold", "rung": rung_name(r), "usb": a.usb, "hold": rep_i, "segment": seg,
                       "time": time.strftime("%Y-%m-%d %H:%M:%S"), "bits": plan.get("bits", 16)}
                try:
                    rec.update(measure(unit, min(a.segment, a.minutes * 60 - held), screen=scr, usb_every=0.5,
                                       until=lambda: bool(scr.stopped)))
                except Lockup as e:
                    rec.update({"result": "LOCKUP", "detail": str(e)})
                    with path.open("a") as f:
                        f.write(json.dumps(rec) + "\n")
                    print(f"\nLOCKUP: {e}\nPower-cycle the unit, load the project, SRC page, then run again.")
                    return
                held += time.monotonic() - t0
                dead = usb_dead(rec.get("series", {}), in_ref, out_ref)
                stopped = rec.get("screen", {}).get("stopped", [])
                rec["result"] = dead or ("STOP" if stopped else "CLEAN")
                with path.open("a") as f:
                    f.write(json.dumps(rec) + "\n")
                if dead:
                    print(f"  {dead} after {held:.0f} s; {_context(rec)}\n"
                          "Power-cycle the unit, load the project, SRC page, then run again.")
                    return
                if stopped:
                    stops += 1
                    print(f"  STOP: tracks {stopped} after {held:.0f} s of this hold; {_context(rec)}")
                    if a.observe:
                        print(f"  watching {a.observe:g} s more before the restart (do they come back?)")
                        scr2 = Screen(expected_states(r), t_start, plan["bpm"], on_event=print_event)
                        obs = {"kind": "hold-observe", "rung": rung_name(r), "usb": a.usb, "hold": rep_i,
                               "segment": seg, "time": time.strftime("%Y-%m-%d %H:%M:%S")}
                        try:
                            obs.update(measure(unit, a.observe, screen=scr2, usb_every=0.5))
                        except Lockup as e:
                            obs.update({"result": "LOCKUP", "detail": str(e)})
                        obs.setdefault("result", "OBSERVED")
                        with path.open("a") as f:
                            f.write(json.dumps(obs) + "\n")
                        held += a.observe
                        if obs["result"] == "LOCKUP":
                            print(f"\nLOCKUP while watching: {obs['detail']}")
                            return
                    print("  restarting the transport")
                    t_start = start_rung(clock, unit, plan, r, a.settle)
            total_s += held; total_stops += stops
            print(f"  hold {rep_i}: {stops} stop(s) in {held / 60:.1f} min")
            if stops and not a.all:
                break
    finally:
        try:
            clock.stop(); time.sleep(0.2); clock.stop()
        except Exception:  # noqa: BLE001
            pass
        clock.close()
        if stream:
            stream.close()
    rate = total_stops / (total_s / 60) if total_s else 0
    print(f"{rung_name(r)}, USB {a.usb.upper()}: {int(total_stops)} stop(s) in {total_s / 60:.1f} min "
          f"({rate:.2f} a minute)")


def cmd_cycle(a):
    import ot_ladder as L
    plan = json.loads((pathlib.Path(a.dest) / PLAN_FILE).read_text())
    r_from, r_to = parse_rung(getattr(a, "from")), parse_rung(a.to)
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"{a.label}.jsonl"
    unit = Unit()
    if (r_from["density"] or r_to["density"]) and not unit.has_mtrx:
        sys.exit("no REC MATRIX test command in this image")
    if not unit.has_peek:
        sys.exit("no 0xc0/0x59 in this image: cycle needs the screen")
    clock = make_clock(plan, a.midi)
    stream = None
    print(f"cycle {rung_name(r_from)} -> {rung_name(r_to)}, USB {a.usb.upper()}, {a.count} times; writing {path}")
    stops = 0
    try:
        stream, in_ref, out_ref = open_usb(a, unit)
        for i in range(1, a.count + 1):
            rec = {"kind": "cycle", "from": rung_name(r_from), "rung": rung_name(r_to), "usb": a.usb, "cycle": i,
                   "time": time.strftime("%Y-%m-%d %H:%M:%S"), "bits": plan.get("bits", 16)}
            try:
                start_rung(clock, unit, plan, r_from, a.settle)
                t_start = start_rung(clock, unit, plan, r_to, a.settle)
                scr = Screen(expected_states(r_to), t_start, plan["bpm"], on_event=print_event)
                rec.update(measure(unit, a.secs, screen=scr, usb_every=0.5))
            except Lockup as e:
                rec.update({"result": "LOCKUP", "detail": str(e)})
                with path.open("a") as f:
                    f.write(json.dumps(rec) + "\n")
                print(f"\nLOCKUP at cycle {i}: {e}\nPower-cycle the unit, load the project, SRC page, then run again.")
                return
            dead = usb_dead(rec.get("series", {}), in_ref, out_ref)
            stopped = rec.get("screen", {}).get("stopped", [])
            rec["result"] = dead or ("STOP" if stopped else "CLEAN")
            with path.open("a") as f:
                f.write(json.dumps(rec) + "\n")
            print(f"  cycle {i:3d}: {rec['result']}  frame {rec.get('frame_us', 0):5.1f} us  "
                  f"worst {rec.get('worst_us', 0):5.1f}" + (f"  tracks {stopped}" if stopped else ""), flush=True)
            if stopped:
                stops += 1
            if dead:
                print(f"  {dead}; {_context(rec)}\nPower-cycle the unit, load the project, SRC page, then run again.")
                return
    finally:
        try:
            clock.stop(); time.sleep(0.2); clock.stop()
        except Exception:  # noqa: BLE001
            pass
        clock.close()
        if stream:
            stream.close()
    print(f"{rung_name(r_from)} -> {rung_name(r_to)}, USB {a.usb.upper()}: {stops} stop(s) in {a.count} changes")


def cmd_masks(a):
    unit = Unit()
    if not unit.has_mtrx:
        sys.exit("no 0xc0/0x58 in this image (needs FRAME PROFILE and REC MATRIX)")
    for s in a.set or ():
        rec, val = s.split("=")
        unit.mask(int(rec) - 1, int(val, 0))
    for t in range(8):
        print(f"REC{t + 1}  {unit.mask(t):#06x}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("plan")
    p = sub.add_parser("proj"); p.add_argument("template"); p.add_argument("dest")
    p.add_argument("--bits", type=int, choices=(16, 24), default=None, help="the template's when not given")
    p.add_argument("--clock", choices=("internal", "midi"), default="internal",
                   help="internal: the unit is the clock, the script sends transport only (default); midi: the script "
                        "sends MIDI clock")
    p = sub.add_parser("run"); p.add_argument("dest"); p.add_argument("label")
    p.add_argument("--midi", default="Elektron Octatrack DPS-1"); p.add_argument("--usb-in", default="Octatrack")
    p.add_argument("--usb", default="off,on"); p.add_argument("--ladders", default=",".join(LADDERS))
    p.add_argument("--secs", type=float, default=10.0); p.add_argument("--settle", type=float, default=4.0)
    p.add_argument("--flip", type=float, default=0.5); p.add_argument("--resume", action="store_true")
    p.add_argument("--audio", action="store_true", help="check MAIN L's tone (only with tracks kept off MAIN)")
    p = sub.add_parser("report"); p.add_argument("labels", nargs="+")
    p = sub.add_parser("masks"); p.add_argument("--set", nargs="*")
    for name in ("hold", "cycle"):
        p = sub.add_parser(name); p.add_argument("dest"); p.add_argument("label")
        p.add_argument("--midi", default="Elektron Octatrack DPS-1"); p.add_argument("--usb-in", default="Octatrack")
        p.add_argument("--usb", default="on"); p.add_argument("--settle", type=float, default=4.0)
        if name == "hold":
            p.add_argument("--rung", required=True); p.add_argument("--minutes", type=float, default=5.0)
            p.add_argument("--repeats", type=int, default=3); p.add_argument("--all", action="store_true")
            p.add_argument("--segment", type=float, default=10.0, help="seconds a written segment")
            p.add_argument("--observe", type=float, default=8.0, help="seconds watched after a stop, before the "
                                                                       "restart (0: restart at once)")
        else:
            p.add_argument("--from", required=True); p.add_argument("--to", required=True)
            p.add_argument("--count", type=int, default=30); p.add_argument("--secs", type=float, default=10.0)
    a = ap.parse_args()
    {"plan": cmd_plan, "proj": cmd_proj, "run": cmd_run, "report": cmd_report, "masks": cmd_masks,
     "hold": cmd_hold, "cycle": cmd_cycle}[a.cmd](a)


if __name__ == "__main__":
    main()
