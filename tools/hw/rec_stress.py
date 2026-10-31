#!/usr/bin/env python3
"""The recorder stress test: one project, ladders of recorder load stepped over USB MIDI, the frame interrupt and
the tasks read over USB at every rung, a scorecard per image.

    python3 tools/hw/rec_stress.py plan
    python3 tools/hw/rec_stress.py proj TEMPLATE DEST            # TEMPLATE: a fresh project (the unit's, or ot_fresh.py's)
    python3 tools/hw/rec_stress.py run DEST LABEL [--midi Octatrack] [--usb-in Octatrack] [--usb off,on]
                                                  [--ladders SELF,DIAG,MED,DENSE,SWITCH] [--secs 10] [--settle 4]
                                                  [--resume]
    python3 tools/hw/rec_stress.py report LABEL [LABEL ...]      # the scorecard; two or more labels side by side
    python3 tools/hw/rec_stress.py masks [--set REC=MASK ...]    # read (or set) REC MATRIX's masks over USB

WHY. "Is it better than last build" and "what do we have to tell users before they rely on it" both need the same
conditions every time, run without anyone at the panel. The ladders climb in load and stop where the unit does.

THE PROJECT (128 BPM, every pattern LEN 16 1X, the template's other settings kept; recorders record at whatever
depth the template's project uses):
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

A RUN. --usb off,on runs every ladder with USB audio idle, then again with the host streaming (a 997 Hz sine into
USB IN ABCD, the unit's output taken and discarded, as analyzer_sweep.py --usb-in does). Within a phase: BASE, then
each ladder from x1 up. Per rung: STOP twice, the program change, START, --settle seconds (two bars at 128 BPM by
default: the first take, then sound on sound), then --secs of polling: BRAIN's task ledger (block 4), LOAD METER's
windows (block 0: the frame interrupt's mean and its longest single run) and FRAME PROFILE's sections (block 5),
the USB error counters before and after. One JSON line per rung in out/hw/stress/LABEL.jsonl.

WHAT A RUNG REPORTS. CLEAN; OVER when a frame interrupt ran past the 362.8 us frame in any window (the next frame
started late); USB ERR when an IN or OUT error, underrun or overrun counter moved; LOCKUP when the unit stopped
answering or LOAD METER's window count stopped moving for 3 s (the frame engine stopped). A LOCKUP ends the run:
power-cycle the unit (it reloads the project), then the same command with --resume skips the rungs already done
and the rest of the ladder that locked. The spike column names the FRAME PROFILE section that rose most over its
median in the window nearest the worst frame (windows are 0.5 s: a section, not a single frame).

What it cannot see: the screen (UI lag shows as the UI task's and IDLE's shares falling, not directly); interrupts
other than the frame interrupt stay inside the tasks they hit; FRAME PROFILE's sections are window means.
"""
import argparse
import json
import pathlib
import re
import shutil
import statistics
import struct
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import analyzer_sweep as AZ                           # noqa: E402  (bank layout, USB IN stream, USB counters)

BPM = 128
PLAN_FILE = "OCTABAM_STRESS.json"
OUT = pathlib.Path("out/hw/stress")
FRAME_US = 16 / 44100 * 1e6                           # 362.8 us
CF_HZ = 132e6
SELF_BANK, MTRX_BANK, BASE_PATTERN = 0, 1, 15
SRC3_MTRX = 11                                        # the stored SRC3 value REC MATRIX formats as MTRX (rmx.s)
REC_SELF = {"INAB": 1, "INCD": 0, "RLEN": 15, "LOOP": 0}    # A B, -, 16 steps (raw), off
REC_MTRX = {"INAB": 0, "INCD": 0, "RLEN": 15, "LOOP": 0}
TRIGS_SELF = (AZ.MASK_PLAY, AZ.MASK_REC1, AZ.MASK_REC2, AZ.MASK_REC3)
TRIGS_MTRX = (AZ.MASK_PLAY, AZ.MASK_REC3)
NS = range(1, 9)
SWITCH_N = 4

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

def rungs(ladders=LADDERS):
    """The rungs of one USB phase, in run order: BASE, then each ladder from x1 up."""
    out = [{"ladder": "BASE", "n": 0, "program": 16 * SELF_BANK + BASE_PATTERN, "density": None}]
    for lad in ladders:
        if lad == "SELF":
            out += [{"ladder": "SELF", "n": n, "program": 16 * SELF_BANK + n - 1, "density": None} for n in NS]
        elif lad in DENSITIES:
            out += [{"ladder": lad, "n": n, "program": 16 * MTRX_BANK + n - 1, "density": lad} for n in NS]
        elif lad == "SWITCH":
            out.append({"ladder": "SWITCH", "n": SWITCH_N, "program": 16 * MTRX_BANK + SWITCH_N - 1,
                        "density": "DIAG/DENSE"})
        else:
            sys.exit(f"no ladder {lad!r}: {', '.join(LADDERS)}")
    return out


def rung_id(usb, r):
    return f"USB {usb.upper()}/{r['ladder']} x{r['n']}" if r["n"] else f"USB {usb.upper()}/BASE"


def cmd_plan(_a):
    for r in rungs():
        dens = f"  masks {r['density']}" if r["density"] else ""
        print(f"PC {r['program']:3d}  bank {'AB'[r['program'] // 16]} pattern {r['program'] % 16 + 1:2d}  "
              f"{r['ladder']:6s} x{r['n']}{dens}")
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
        rs = base + AZ.REC_SETUP_OFF + t * 12
        assert data[rs + AZ.REC_FIELDS.index("SRC3")] == src3(t)
        assert all(data[rs + AZ.REC_FIELDS.index(f)] == v for f, v in setup.items())
    assert (sum(data[0x10:-2]) & 0xFFFF) == int.from_bytes(data[-2:], "big"), "bank checksum"


def write_project_text(dest):
    """TSTR and loop off on the eight recorder buffers; MIDI clock, transport and program change in; 128 BPM."""
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
    settings["TEMPOx24"] = BPM * 24
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
    changed = write_project_text(dest)
    write_bank(dest, SELF_BANK, REC_SELF, lambda t: t + 1, TRIGS_SELF)
    write_bank(dest, MTRX_BANK, REC_MTRX, lambda t: SRC3_MTRX, TRIGS_MTRX)
    check_bank(dest, SELF_BANK, REC_SELF, lambda t: t + 1, TRIGS_SELF)
    check_bank(dest, MTRX_BANK, REC_MTRX, lambda t: SRC3_MTRX, TRIGS_MTRX)
    plan = {"bpm": BPM, "pc_channel": 1, "rungs": rungs(), "settings_changed": changed}
    (dest / PLAN_FILE).write_text(json.dumps(plan, indent=1))
    print(f"{dest}: banks A (SELF) and B (MTRX), {len(rungs())} rungs a USB phase; "
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


def measure(unit, secs, interval=0.25, flip=None):
    """Poll for secs. -> dict with the task shares (task_meter's Accumulator), the frame interrupt's mean and worst
    frame per LOAD METER window, FRAME PROFILE's sections per window, and the spike's section."""
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
           "windows": len(wins)}
    if wins:
        means = [w[1] for w in wins]
        worst = max(wins, key=lambda w: w[2])
        out.update({"frame_us": round(statistics.fmean(means), 1), "frame_us_max_window": round(max(means), 1),
                    "worst_us": round(worst[2], 1), "over_windows": sum(1 for w in wins if w[2] >= FRAME_US)})
        if fps:
            near = min(fps, key=lambda f: abs(f[0] - worst[0]))[1]
            med = {k: statistics.median(f[1][k] for f in fps) for k in near}
            rise = {k: near[k] - med[k] for k in near}
            k = max(rise, key=rise.get)
            out["spike"] = {"section": k, "rise_us": round(rise[k], 1), "at_s": round(worst[0], 1)}
    return out


# ------------------------------------------------------------------------------------------------------- a run --

def usb_moving(dev):
    """(IN packets, OUT frames) a second the host is moving, over 1 s."""
    a = AZ.usb_snapshot(dev); time.sleep(1.0); b = AZ.usb_snapshot(dev)
    rate = lambda side, k: ((b[side][k] - a[side][k]) % (1 << 32)) if a.get(side) and b.get(side) else 0
    return rate(True, "pkts"), rate(False, "consumed")


def errors_of(delta):
    return {k: int(v) for k, v in delta.items() if v not in ("", "0") and not k.endswith("consumed")}


def verdict(rec):
    if rec.get("result") == "LOCKUP":
        return "LOCKUP"
    tags = []
    if rec.get("over_windows"):
        tags.append("OVER")
    if rec.get("usb_errors"):
        tags.append("USB ERR")
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
    locked = {(d["usb"], d["ladder"]) for d in done if d["result"] == "LOCKUP"}
    unit = Unit()
    ladders = [x.strip().upper() for x in a.ladders.split(",") if x.strip()]
    if not (unit.has_mtrx and unit.has_fp):
        dropped = [x for x in ladders if x != "SELF"]
        ladders = [x for x in ladders if x == "SELF"]
        if dropped:
            print(f"no REC MATRIX test command in this image (0xc0/0x58): skipping {', '.join(dropped)}")
    clock = L.Clock(plan["bpm"], a.midi)
    usb_in = None
    print(f"writing {path}")
    try:
        for usb in [x.strip().lower() for x in a.usb.split(",")]:
            if usb == "on":
                usb_in = AZ.UsbInStream(a.usb_in)
                print(f"USB ON: 997 Hz into {usb_in.ch} channels of {usb_in.name!r}, "
                      f"{usb_in.check(unit.dev):.0f} IN packets a second; the unit's output taken")
            else:
                pin, pout = usb_moving(unit.dev)
                if pin or pout:
                    sys.exit(f"USB OFF asked, but the host is streaming (IN {pin}/s, OUT {pout} frames/s): quit "
                             "every app using the Octatrack's audio (Logic, the aggregate device's users)")
                print("USB OFF: no host stream")
            for r in rungs(ladders):
                rid = rung_id(usb, r)
                if rid in skip or (usb, r["ladder"]) in locked:
                    continue
                clock.stop(); time.sleep(0.2); clock.stop(); time.sleep(0.5)
                if r["density"]:
                    unit.set_masks("DIAG" if r["ladder"] == "SWITCH" else r["density"])
                clock.pc(plan["pc_channel"], r["program"]); time.sleep(0.8)
                clock.start()
                rec = {"rung": rid, "usb": usb, "ladder": r["ladder"], "n": r["n"], "program": r["program"],
                       "density": r["density"], "time": time.strftime("%Y-%m-%d %H:%M:%S")}
                try:
                    time.sleep(a.settle)
                    u0 = AZ.usb_snapshot(unit.dev)
                    rec.update(measure(unit, a.secs if r["ladder"] != "SWITCH" else 2 * a.secs,
                                       flip=a.flip if r["ladder"] == "SWITCH" else None))
                    u1 = AZ.usb_snapshot(unit.dev)
                    rec["usb_errors"] = errors_of(AZ.usb_delta(u0, u1))
                    rec["result"] = verdict(rec)
                except Lockup as e:
                    rec.update({"result": "LOCKUP", "detail": str(e)})
                with path.open("a") as f:
                    f.write(json.dumps(rec) + "\n")
                print(line(rec), flush=True)
                if rec["result"] == "LOCKUP":
                    print(f"\nLOCKUP at {rid}: {rec['detail']}\nPower-cycle the unit (it reloads the project), "
                          f"then run the same command with --resume. The rest of USB {usb.upper()}/{r['ladder']} "
                          "is skipped.")
                    return
            if usb_in:
                usb_in.close(); usb_in = None
    finally:
        try:
            clock.stop(); time.sleep(0.2); clock.stop()
        except Exception:  # noqa: BLE001 -- the unit may be gone
            pass
        clock.close()
        if usb_in:
            usb_in.close()
    print(f"done: python3 tools/hw/rec_stress.py report {a.label}")


def line(rec):
    if rec["result"] == "LOCKUP":
        return f"{rec['rung']:24s} LOCKUP  {rec.get('detail', '')}"
    sh, p = rec.get("share", {}), rec.get("profile", {})
    spike = rec.get("spike") or {}
    return (f"{rec['rung']:24s} {rec['result']:8s} frame {rec.get('frame_us', 0):5.1f} us "
            f"({100 * rec.get('frame_us', 0) / FRAME_US:4.1f}%)  worst {rec.get('worst_us', 0):5.1f}  "
            f"IDLE {100 * sh.get('IDLE', 0):4.1f}%  UI {100 * sh.get('UI', 0):4.1f}%  "
            f"rec {p.get('recorder', 0):5.1f}  voices {p.get('voices', 0):5.1f}  "
            f"spike {spike.get('section', '-')} +{spike.get('rise_us', 0)}"
            + (f"  {rec['usb_errors']}" if rec.get("usb_errors") else ""))


# ------------------------------------------------------------------------------------------------- the report --

def cmd_report(a):
    runs = {lab: load_done(OUT / f"{lab}.jsonl") for lab in a.labels}
    for lab, recs in runs.items():
        if not recs:
            sys.exit(f"no records for {lab} in {OUT}")
    print("## Scorecard\n")
    print("Highest rung with every lower rung CLEAN (OVER, USB ERR or LOCKUP end the climb); in brackets, the "
          "first rung that was not.\n")
    phases = sorted({(r["usb"], r["ladder"]) for recs in runs.values() for r in recs if r["ladder"] != "BASE"},
                    key=lambda k: (k[0] != "off", LADDERS.index(k[1])))
    print("| ladder | " + " | ".join(a.labels) + " |")
    print("|---|" + "---|" * len(a.labels))
    for usb, lad in phases:
        cells = []
        for lab in a.labels:
            recs = sorted((r for r in runs[lab] if r["usb"] == usb and r["ladder"] == lad), key=lambda r: r["n"])
            if not recs:
                cells.append("-"); continue
            if lad == "SWITCH":
                cells.append(recs[0]["result"]); continue
            clean, first = 0, ""
            for r in recs:
                if r["result"] != "CLEAN":
                    first = f" ({r['result']} at x{r['n']})"; break
                clean = r["n"]
            if not first and recs[-1]["n"] < 8:
                first = f" (not run past x{recs[-1]['n']})"
            cells.append(f"x{clean}{first}" if clean else f"none{first}")
        print(f"| USB {usb.upper()} {lad} | " + " | ".join(cells) + " |")
    for lab, recs in runs.items():
        print(f"\n## {lab}\n")
        print("| rung | result | frame us | % frame | worst us | IDLE | UI | recorder | voices | usb out | usb in "
              "| spike |")
        print("|---|---|---|---|---|---|---|---|---|---|---|---|")
        for r in recs:
            if r["result"] == "LOCKUP":
                print(f"| {r['rung']} | LOCKUP | | | | | | | | | | {r.get('detail', '')} |"); continue
            p, sh, s = r.get("profile", {}), r.get("share", {}), r.get("spike") or {}
            f = lambda k: f"{p[k]:.1f}" if isinstance(p.get(k), (int, float)) else ""
            print(f"| {r['rung']} | {r['result']} | {r.get('frame_us', '')} | "
                  f"{100 * r.get('frame_us', 0) / FRAME_US:.1f} | {r.get('worst_us', '')} | "
                  f"{100 * sh.get('IDLE', 0):.1f}% | {100 * sh.get('UI', 0):.1f}% | {f('recorder')} | {f('voices')} | "
                  f"{f('usb out shim')} | {f('usb in frame')} | {s.get('section', '')} {s.get('rise_us', '')} |")


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
