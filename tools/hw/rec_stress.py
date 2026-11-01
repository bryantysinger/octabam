#!/usr/bin/env python3
"""The recorder stress test: one project, ladders of recorder load stepped over USB MIDI, the frame interrupt and
the tasks read over USB at every rung, a scorecard per image.

    python3 tools/hw/rec_stress.py plan
    python3 tools/hw/rec_stress.py proj TEMPLATE DEST [--bits 24]   # TEMPLATE: a fresh project (the unit's, or ot_fresh.py's)
    python3 tools/hw/rec_stress.py run DEST LABEL [--midi Octatrack] [--usb-in Octatrack] [--usb off,on]
                                                  [--ladders SELF,DIAG,MED,DENSE,SWITCH] [--secs 10] [--settle 4]
                                                  [--resume]
    python3 tools/hw/rec_stress.py report LABEL [LABEL ...]      # the scorecard; two or more labels side by side
    python3 tools/hw/rec_stress.py masks [--set REC=MASK ...]    # read (or set) REC MATRIX's masks over USB

WHY. "Is it better than last build" and "what do we have to tell users before they rely on it" both need the same
conditions every time, run without anyone at the panel. The ladders climb in load and stop where the unit does.

THE PROJECT (128 BPM, every pattern LEN 16 1X; RECORD_24BIT from --bits, 24 by default; DIR AB 127, so USB IN A/B
reaches MAIN; every track's LEVEL 0 in part 1, so MAIN carries only that input: the recorders' taps are pre-fader):
  bank A, part 1  SELF: track t a FLEX machine on its own recorder buffer R(t), INAB A B, INCD -, SRC3 the track
                  itself, RLEN 16, LOOP off, TSTR off on the buffers (Bryan T's 8-buffer lockup case). Pattern n
                  (1-8): the first n tracks with PLAY + REC1 + REC2 + REC3 on step 1. Pattern 16: no trigs (BASE).
  bank B, part 1  MTRX: the same machines, INAB -, INCD -, SRC3 MTRX. Pattern n: the first n tracks with PLAY +
                  REC3 on step 1. The matrix is not in the project: `run` sets every recorder's row over USB
                  before each rung (vendor request 0xc0/0x58, images with FRAME PROFILE and REC MATRIX):
                    DIAG   recorder t records Tt                                   (1 source)
                    MED    Tt + AB + MAIN                                          (3 sources)
                    DENSE  AB + CD + T1-T8 + MAIN + CUE                            (12 sources, every non-overlapping one)
                  SWITCH holds MTRX x4 and flips every row between DIAG and DENSE every --flip seconds (the
                  64-sample ramps on every change, QUANT as the project has it: OFF in a fresh one).
A program change (channel --pc-channel, default 1) selects 16 x bank + pattern; `run` sends the clock.

A RUN. --usb off,on runs every ladder with USB audio idle, then again with the host streaming: a 997 Hz sine at
-20 dBFS into USB IN ABCD and MAIN L taken back from the unit's output. Within a phase: BASE; each ladder from x1
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
  LOCKUP         the unit stopped answering, or LOAD METER's window count stopped for 3 s.
LOCKUP and the STOPPEDs end the run: power-cycle the unit (it reloads the project), then the same command with
--resume skips the rungs already done and the rest of the ladder that ended it. The scorecard climbs each ladder to
the first USB ERR, AUDIO, STOPPED or LOCKUP and gives the frame interrupt's mean load at the top clean rung.

What it cannot see: the screen (IDLE's share falling is the stand-in; the UI task's share stays near 0.1%);
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
LEVEL_OFF = 0x01b                                     # a part's track LEVELs, every other byte (ot_project.py)
NS = range(1, 9)
SWITCH_N = 4
TONE_HZ, TONE_DBFS = 997.0, -20.0
HARD = ("LOCKUP", "USB IN STOPPED", "USB OUT STOPPED", "USB ERR", "AUDIO")
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

def write_bank(dest, bank, setup, src3, trigs):
    for suffix in ("work", "strd"):
        path = dest / f"bank{bank + 1:02d}.{suffix}"
        if not path.exists():
            continue
        data = bytearray(path.read_bytes())
        for p in (0, 4):                                    # part 1 and its saved copy
            base = AZ.PART_BASE + p * AZ.PART_STRIDE
            for t in range(8):
                data[base + AZ.MTYPE_OFF + t] = 1           # FLEX
                data[base + AZ.SLOT_OFF + t * 5 + 1] = 128 + t   # on recorder buffer R(t+1)
                data[base + LEVEL_OFF + 2 * t] = 0          # LEVEL 0: MAIN carries only DIR AB
                rs = base + AZ.REC_SETUP_OFF + t * 12
                for f, v in setup.items():
                    data[rs + AZ.REC_FIELDS.index(f)] = v
                data[rs + AZ.REC_FIELDS.index("SRC3")] = src3(t)
        for pat in range(16):
            for t in range(8):
                off = AZ.trac_off(pat, t)
                data[off:off + 64] = bytes(64)              # no trigs or trigless locks
                data[off + 0x50], data[off + 0x51] = 16, 2
            tail = AZ.PTRN0 + pat * AZ.PTRN_FSTRIDE + AZ.PTRN_FSTRIDE - 11
            data[tail + 2], data[tail + 3] = 16, 2          # LEN 16, 1X
            data[AZ.PTRN0 + pat * AZ.PTRN_FSTRIDE + AZ.PTRN_FSTRIDE - 5] = 0   # part 1
        for n in NS:
            for t in range(n):
                for mask in trigs:
                    data[AZ.trac_off(n - 1, t) + mask + 7] |= 1    # step 1
        data[-2:] = (sum(data[0x10:-2]) & 0xFFFF).to_bytes(2, "big")
        path.write_bytes(bytes(data))


def check_bank(dest, bank, setup, src3, trigs):
    data = (dest / f"bank{bank + 1:02d}.work").read_bytes()
    for n in NS:
        for mask in (AZ.MASK_PLAY, AZ.MASK_REC1, AZ.MASK_REC2, AZ.MASK_REC3):
            on = [t for t in range(8) if data[AZ.trac_off(n - 1, t) + mask + 7] & 1]
            assert on == (list(range(n)) if mask in trigs else []), (bank, n, hex(mask), on)
    for pat in (8, BASE_PATTERN):
        assert not any(data[AZ.trac_off(pat, t) + m + 7] & 1 for t in range(8)
                       for m in (AZ.MASK_PLAY, AZ.MASK_REC1, AZ.MASK_REC2, AZ.MASK_REC3)), (bank, pat)
    for t in range(8):
        base = AZ.PART_BASE
        assert data[base + AZ.MTYPE_OFF + t] == 1 and data[base + AZ.SLOT_OFF + t * 5 + 1] == 128 + t
        assert data[base + LEVEL_OFF + 2 * t] == 0
        rs = base + AZ.REC_SETUP_OFF + t * 12
        assert data[rs + AZ.REC_FIELDS.index("SRC3")] == src3(t)
        assert all(data[rs + AZ.REC_FIELDS.index(f)] == v for f, v in setup.items())
    assert (sum(data[0x10:-2]) & 0xFFFF) == int.from_bytes(data[-2:], "big"), "bank checksum"


def write_project_text(dest, bits):
    """TSTR and loop off on the eight recorder buffers; MIDI clock, transport and program change in; 128 BPM;
    the recorders' depth; DIR AB up."""
    for name in ("project.work", "project.strd"):
        path = dest / name
        if not path.exists():
            continue
        raw = path.read_bytes()

        def rec_attrs(m):
            b = re.sub(rb"TSMODE=\d+", b"TSMODE=0", m.group(0))
            return re.sub(rb"LOOPMODE=\d+", b"LOOPMODE=0", b)
        raw, k = re.subn(rb"\[SAMPLE\]\r?\nTYPE=FLEX\r?\nSLOT=(129|13[0-6])\r?\n.*?\[/SAMPLE\]", rec_attrs, raw,
                         flags=re.S)
        if k != 8:
            sys.exit(f"{path}: {k} recorder sample blocks (FLEX 129-136), want 8")
        path.write_bytes(raw)
    import ot_matrix as M
    settings = M.test_settings(1)
    settings.update({"TEMPOx24": BPM * 24, "RECORD_24BIT": 1 if bits == 24 else 0, "DIR_AB": 127})
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
    shutil.copytree(src, dest)
    changed = write_project_text(dest, a.bits)
    write_bank(dest, SELF_BANK, REC_SELF, lambda t: t + 1, TRIGS_SELF)
    write_bank(dest, MTRX_BANK, REC_MTRX, lambda t: SRC3_MTRX, TRIGS_MTRX)
    check_bank(dest, SELF_BANK, REC_SELF, lambda t: t + 1, TRIGS_SELF)
    check_bank(dest, MTRX_BANK, REC_MTRX, lambda t: SRC3_MTRX, TRIGS_MTRX)
    plan = {"bpm": BPM, "bits": a.bits, "pc_channel": 1, "rungs": rungs(), "settings_changed": changed}
    (dest / PLAN_FILE).write_text(json.dumps(plan, indent=1))
    print(f"{dest}: banks A (SELF) and B (MTRX), {a.bits}-bit recorders, {len(rungs())} rungs a USB phase; "
          "copy the folder into a set on the card and load it")


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

    def __init__(self, device):
        import numpy as np
        import sounddevice as sd
        self.np = np
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
        self.ostream = sd.OutputStream(device=outs[0], channels=self.ch, samplerate=FS, dtype="float32",
                                       callback=out_cb)
        self.istream = sd.InputStream(device=ins[0], channels=self.in_ch, samplerate=FS, dtype="float32",
                                      callback=in_cb)
        self.ostream.start(); self.istream.start()

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


# ---------------------------------------------------------------------------------------------- a measurement --

def measure(unit, secs, interval=0.25, flip=None):
    """Poll for secs. -> dict with the task shares (task_meter's Accumulator), the frame interrupt's mean and worst
    frame per LOAD METER window, FRAME PROFILE's sections per window, and every window (`series`)."""
    T = unit.T
    acc = T.Accumulator()
    t0 = time.monotonic()
    lm_seq, lm_moved = None, t0
    fp_seq = None
    wins, fps = [], []                                 # (t, mean us, longest us), (t, {section: us})
    state, next_flip = 0, (t0 + flip if flip else None)
    while True:
        led, st, fp = unit.read()
        now = time.monotonic()
        acc.add(led, st, fp)
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
    out = {"seconds": round(res["seconds"], 2), "frame_irq": res["frame_irq"],
           "share": {k: round(v, 5) for k, v in res["share"].items()},
           "profile": {k: (round(v, 2) if isinstance(v, float) else v) for k, v in (res["profile"] or {}).items()},
           "windows": len(wins),
           "series": {"lm": [[round(t, 2), round(m, 1), round(l, 1)] for t, m, l in wins],
                      "fp": [[round(t, 2), {k: round(v, 1) for k, v in d.items()}] for t, d in fps]}}
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
    clock = L.Clock(plan["bpm"], a.midi)
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
                                       flip=a.flip if r["ladder"] == "SWITCH" else None))
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
                        au = tone_check(lo, x, stream.w)
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
            + aud + (f"  {rec['usb_errors']}" if rec.get("usb_errors") else "")
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
              "| audio |")
        print("|---|---|---|---|---|---|---|---|---|---|---|")
        for r in recs:
            if r["result"] == "LOCKUP":
                print(f"| {r['rung']} | LOCKUP | | | | | | | | | {r.get('detail', '')} |"); continue
            p, sh, au = r.get("profile", {}), r.get("share", {}), r.get("audio")
            f = lambda k: f"{p[k]:.1f}" if isinstance(p.get(k), (int, float)) else ""
            aud = ("" if not au else "no tone" if au.get("no_tone") else
                   f"{au['thdn_db']} dB, {au['slips']} slips, {au['drops']} drops")
            print(f"| {r['rung']} | {result_of(r)} | {r.get('frame_us', '')} | "
                  f"{100 * r.get('frame_us', 0) / FRAME_US:.1f} | {r.get('worst_us', '')} | "
                  f"{100 * sh.get('IDLE', 0):.1f}% | {f('recorder')} | {f('voices')} | "
                  f"{f('usb out shim')} | {f('usb in frame')} | {aud} |")


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
    p.add_argument("--bits", type=int, choices=(16, 24), default=24)
    p = sub.add_parser("run"); p.add_argument("dest"); p.add_argument("label")
    p.add_argument("--midi", default="Octatrack"); p.add_argument("--usb-in", default="Octatrack")
    p.add_argument("--usb", default="off,on"); p.add_argument("--ladders", default=",".join(LADDERS))
    p.add_argument("--secs", type=float, default=10.0); p.add_argument("--settle", type=float, default=4.0)
    p.add_argument("--flip", type=float, default=0.5); p.add_argument("--resume", action="store_true")
    p = sub.add_parser("report"); p.add_argument("labels", nargs="+")
    p = sub.add_parser("masks"); p.add_argument("--set", nargs="*")
    a = ap.parse_args()
    {"plan": cmd_plan, "proj": cmd_proj, "run": cmd_run, "report": cmd_report, "masks": cmd_masks}[a.cmd](a)


if __name__ == "__main__":
    main()
