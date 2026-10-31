#!/usr/bin/env python3
"""Each ColdFire task's share of the processor, read from a unit over USB (BRAIN's task ledger).

    tools/hw/task_meter.py                          # one 2 s measurement, printed
    tools/hw/task_meter.py --watch 1                # a line a second, the busiest tasks first
    tools/hw/task_meter.py --for 10 --csv out.csv --label "8 FLEX loop on"   # one row appended to out.csv

What it reads. BRAIN's scheduler detour (modules/brain hooks.s, brain_sched) charges the DMA
timer 3 counts (132 MHz) since the last scheduler entry to the task that was running, into
brain_ts: 12 slots of {TCB, running total}, the last one any task not in the table. The USB
module serves that block as vendor request 0xc0/0x57, wValue 4 (modules/usb/usbaudio.s), 96
bytes, big-endian. The totals wrap every 2^32 counts (32.5 s), so the poll interval must stay
well under that; the deltas are taken modulo 2^32.

A task's share is its delta over the sum of all twelve deltas, which is the elapsed time (every
count is charged to exactly one slot). The frame interrupt's time lands on whichever task it
interrupted. With LOAD METER in the image (block 0, lm_stats) its share over the same polls is
read too, reported as FRAME IRQ, and taken off the tasks in proportion to their shares: BRAIN's
CPU tab does the same (cpu_update in brain.c), on the same inferred assumption that the
interrupt arrives independently of the task switches. Without LOAD METER the raw shares are
reported and FRAME IRQ is blank. Other interrupts stay inside the tasks, as on BRAIN's screen.

Needs pyusb and a libusb (tools/hw/load_meter.py's docstring). The image must carry BRAIN and
USB (with an output on); the request STALLs otherwise.
"""
import argparse
import csv
import pathlib
import struct
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

CF_HZ = 132e6
LEDGER_BLOCK, LEDGER_BYTES = 4, 96
STATS_BLOCK, STATS_BYTES = 0, 20
DSP_BLOCK, DSP_BYTES = 1, 48
FP_BLOCK, FP_BYTES = 5, 96
FRAME_US = 16 / 44100 * 1e6                      # 362.8 us
# FRAME PROFILE's sections (modules/frame-profile/profile.s), in order
SECTIONS = ("head", "calls", "prep", "recorder", "voices", "mix")
WRAP = 1 << 32

# brain_ts's TCBs (hooks.s) and BRAIN's names for them (brain.c cpu_name), in slot order.
TASKS = ((0x46c7fb0c, "MIDI"), (0x460bcc2c, "STORAGE"), (0x460d4f80, "KEYS"), (0x460d59d4, "UI"),
         (0x460fab80, "TASK 91D18"), (0x460ffd44, "TASK 921C4"), (0x460e0e38, "TASK 9203C"),
         (0x460ddde4, "ENGINE"), (0x46105508, "TASK 98A5C"), (0x46c7bed8, "SYS"), (0x46c7ae84, "IDLE"),
         (0, "OTHER"))
NAMES = [n for _, n in TASKS]


def decode_ledger(raw):
    """96 bytes -> [(tcb, total)] x 12. Refuses a table whose TCBs are not BRAIN's: a different
    build's ledger would put the counts under the wrong names."""
    if len(raw) != LEDGER_BYTES:
        raise ValueError(f"ledger: {len(raw)} bytes, want {LEDGER_BYTES}")
    words = struct.unpack(">24I", raw)
    slots = [(words[2 * i], words[2 * i + 1]) for i in range(12)]
    for i, ((tcb, _), (want, name)) in enumerate(zip(slots, TASKS)):
        if tcb != want:
            raise ValueError(f"ledger slot {i} holds TCB {tcb:#010x}, BRAIN's table has {want:#010x} ({name})")
    return slots


def decode_stats(raw):
    """lm_stats (modules/load-meter meter.s): {seq, window, sum, count, longest} in timer 3 counts."""
    return dict(zip(("seq", "window", "sum", "count", "longest"), struct.unpack(">5I", raw)))


def decode_fp(raw):
    """FRAME PROFILE's window (modules/frame-profile profile.s): 24 longs, timer 3 counts."""
    w = struct.unpack(">24I", raw)
    return {"seq": w[0], "window": w[1], "frames": w[2], "alt": w[3], "sec": list(w[4:10]),
            "xin": w[10], "xall": w[11], "xcnt": w[12], "shc": w[13], "sd3": w[14], "sd5": w[15],
            "uout": w[16], "uprod": w[17], "uin": w[18], "ubuild": w[19],
            "ucopy": w[20], "uenq": w[21], "uheal": w[22], "upkts": w[23]}


class Unit:
    """The USB side: one vendor request per block."""

    def __init__(self):
        import load_meter as L
        self._L = L
        self.dev = L.libusb_device()
        self.has_stats = True

    def _ctrl(self, w, off, n):
        return bytes(self.dev.ctrl_transfer(0xc0, 0x57, w, off, n, timeout=1000))

    def ledger(self):
        return decode_ledger(self._L.read_block(self._ctrl, LEDGER_BLOCK, LEDGER_BYTES))

    def stats(self):
        if not self.has_stats:
            return None
        try:
            return decode_stats(self._L.read_block(self._ctrl, STATS_BLOCK, STATS_BYTES))
        except Exception:  # noqa: BLE001 -- a STALL: no LOAD METER in this image
            self.has_stats = False
            return None

    def _opt(self, flag, block, size, decode):
        if not getattr(self, flag, True):
            return None
        try:
            return decode(self._L.read_block(self._ctrl, block, size))
        except Exception:  # noqa: BLE001 -- a STALL: the image does not carry that module
            setattr(self, flag, False)
            return None

    def fp(self):
        return self._opt("has_fp", FP_BLOCK, FP_BYTES, decode_fp)

    def dsp(self):
        """LOAD METER's per-core DSP busy over its period, the last good frame (block 1)."""
        def dec(raw):
            d = struct.unpack(">12I", raw)
            return [d[2] / d[3] if d[3] else None, d[4] / d[5] if d[5] else None]
        return self._opt("has_dsp", DSP_BLOCK, DSP_BYTES, dec)


class Accumulator:
    """Ledger readings in, per-task counts out: each poll's delta is taken modulo 2^32 and summed,
    so a measurement can run for any length as long as polls stay under the wrap."""

    def __init__(self):
        self.prev = None
        self.counts = [0] * 12
        self.irq_shares = []
        self.last_seq = None
        self.polls = 0
        self.lm_sum = self.lm_cnt = 0
        self.fp = None
        self.fp_seq = None
        self.dsp = [[], []]

    def add(self, ledger, stats=None, fp=None, dsp=None):
        totals = [t for _, t in ledger]
        if self.prev is not None:
            for i, (a, b) in enumerate(zip(self.prev, totals)):
                self.counts[i] += (b - a) % WRAP
            self.polls += 1
        self.prev = totals
        # lm_stats publishes a fresh 0.5 s window with a new seq; count each window once
        if stats and stats["window"] and stats["seq"] != self.last_seq:
            self.irq_shares.append(stats["sum"] / stats["window"])
            self.last_seq = stats["seq"]
            self.lm_sum += stats["sum"]
            self.lm_cnt += stats["count"]
        if fp and fp["window"] and fp["seq"] != self.fp_seq:
            if self.fp_seq is not None:              # the window open at the start is not counted
                if self.fp is None:
                    self.fp = {k: (list(v) if isinstance(v, list) else 0) for k, v in fp.items()}
                    self.fp["sec"] = [0] * len(SECTIONS)
                for k, v in fp.items():
                    if k == "sec":
                        self.fp["sec"] = [a + b for a, b in zip(self.fp["sec"], v)]
                    elif k != "seq":
                        self.fp[k] += v
            self.fp_seq = fp["seq"]
        if dsp:
            for i in (0, 1):
                if dsp[i] is not None:
                    self.dsp[i].append(dsp[i])

    def result(self):
        total = sum(self.counts)
        raw = [c / total if total else 0.0 for c in self.counts]
        irq = sum(self.irq_shares) / len(self.irq_shares) if self.irq_shares else None
        shares = [r * (1 - irq) for r in raw] if irq is not None else raw
        out = {"seconds": total / CF_HZ, "polls": self.polls, "frame_irq": irq,
               "raw": dict(zip(NAMES, raw)), "share": dict(zip(NAMES, shares)),
               "counts": dict(zip(NAMES, self.counts)), "profile": None,
               "dsp": [sum(v) / len(v) if v else None for v in self.dsp]}
        f = self.fp
        if f and f["frames"]:
            us = lambda c: c / f["frames"] / CF_HZ * 1e6              # counts summed over frames -> us a frame
            prof = {name: us(c) for name, c in zip(SECTIONS, f["sec"])}
            prof["xfer in frame"] = us(f["xin"])
            total = self.lm_sum / self.lm_cnt / CF_HZ * 1e6 if self.lm_cnt else None
            prof["frame"] = total
            prof["rest"] = total - sum(prof[n] for n in SECTIONS) - prof["xfer in frame"] if total else None
            prof["wait hostcmd"] = us(f["shc"])
            prof["wait dma3"] = us(f["sd3"])
            prof["wait dma5"] = us(f["sd5"])
            secs = f["window"] / CF_HZ if f["window"] else None
            prof["xfer per s"] = f["xcnt"] / secs if secs else None
            prof["xfer us each"] = f["xall"] / f["xcnt"] / CF_HZ * 1e6 if f["xcnt"] else None
            prof["usb out shim"] = us(f["uout"])        # producer + EP3 + packet builds (frame end)
            prof["usb producer"] = us(f["uprod"])
            prof["usb in frame"] = us(f["uin"])         # in_frame, inside the level-6 handler
            prof["usb in build"] = us(f["ubuild"])
            prof["usb out copy"] = us(f["ucopy"])        # the ring -> packet copy (audio_pkt_build)
            prof["usb out enqueue"] = us(f["uenq"])      # the dTD, the add-dTD tripwire, the prime
            prof["usb out heal"] = us(f["uheal"])        # usbaudio_kick's self-heal
            prof["usb out pkts"] = f["upkts"] / f["frames"]   # packets queued a frame (0 on images before BUILD 35)
            prof["alt frames"] = f["alt"]
            prof["frames"] = f["frames"]
            out["profile"] = prof
        return out


def measure(unit, secs, interval=0.25):
    if interval >= 30:
        sys.exit("--interval must stay well under the ledger's 32.5 s wrap")
    acc = Accumulator()
    t_end = time.monotonic() + secs
    acc.add(unit.ledger(), unit.stats(), unit.fp(), unit.dsp())
    while True:
        time.sleep(interval)
        acc.add(unit.ledger(), unit.stats(), unit.fp(), unit.dsp())
        if time.monotonic() >= t_end:
            return acc.result()


WIN_FIELDS = ("t", "frames", "frame", "longest") + SECTIONS + ("xfer in frame", "usb out shim", "usb producer",
                                                            "usb out copy", "usb out enqueue", "usb in frame", "usb in build")


def windows(unit, secs, path, factor=2.0):
    """Every FRAME PROFILE window (0.5 s) for `secs` seconds, one CSV row each, in us a frame.
    Prints a line whenever the OUT copy runs over `factor` x its running median (a spike),
    then the spikes' times and the gaps between them."""
    us = lambda c, n: c / n / CF_HZ * 1e6
    t0 = time.monotonic(); seq = None; lm_seq = None; longest = None; rows = []; spikes = []
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh); w.writerow(WIN_FIELDS)
        while time.monotonic() - t0 < secs:
            st = unit.stats()
            if st and st["seq"] != lm_seq:
                lm_seq = st["seq"]; longest = st["longest"] / CF_HZ * 1e6
            f = unit.fp()
            if f is None:
                sys.exit("no FRAME PROFILE in this image (block 5)")
            if f["seq"] != seq and f["frames"]:
                first = seq is None; seq = f["seq"]
                if first:
                    continue                                   # the window open at the start
                n = f["frames"]; t = time.monotonic() - t0
                sec = [us(c, n) for c in f["sec"]]
                frame = (us(st["sum"], st["count"]) if st and st["count"] else None)
                row = [round(t, 2), n, frame and round(frame, 1), longest and round(longest, 1)] + \
                      [round(v, 1) for v in sec] + [round(us(f[k], n), 1) for k in
                                                    ("xin", "uout", "uprod", "ucopy", "uenq", "uin", "ubuild")]
                w.writerow(row); fh.flush(); rows.append(row)
                copy = us(f["ucopy"], n); hist = sorted(r[-4] for r in rows[-120:])
                med = hist[len(hist) // 2]
                if len(rows) > 10 and copy > factor * med:
                    spikes.append(t)
                    print(f"{t:7.1f} s  spike: copy {copy:5.1f} us (median {med:4.1f}), OUT shim {us(f['uout'], n):5.1f}, "
                          f"producer {us(f['uprod'], n):5.1f}, longest frame {longest or 0:5.1f}", flush=True)
            time.sleep(0.1)
    print(f"{len(rows)} windows to {path}; {len(spikes)} spike window(s)")
    if len(spikes) > 1:
        print("gaps between spikes (s): " + ", ".join(f"{b - a:.1f}" for a, b in zip(spikes, spikes[1:])))


def fmt(res, top=None):
    order = sorted(NAMES, key=lambda n: -res["share"][n])
    parts = []
    if res["frame_irq"] is not None:
        parts.append(f"FRAME IRQ {100 * res['frame_irq']:5.1f}%")
    for n in order[:top] if top else order:
        if top or res["share"][n] > 0:
            parts.append(f"{n} {100 * res['share'][n]:5.1f}%")
    line = f"{res['seconds']:5.2f} s  " + "  ".join(parts)
    p = res.get("profile")
    if p:
        line += ("\n  frame us: " + "  ".join(f"{n} {p[n]:6.1f}" for n in
                 ("frame",) + SECTIONS + ("xfer in frame", "rest", "wait hostcmd", "wait dma3", "wait dma5",
                                          "usb out shim", "usb producer", "usb in frame", "usb in build",
                                          "usb out copy", "usb out enqueue", "usb out heal", "usb out pkts")
                 if p.get(n) is not None))
    d = res.get("dsp")
    if d and d[0] is not None:
        line += f"\n  DSP busy: core0 {100 * d[0]:5.1f}%  core1 {100 * (d[1] or 0):5.1f}%"
    return line


PROFILE_FIELDS = (["frame"] + list(SECTIONS) + ["xfer in frame", "rest", "wait hostcmd", "wait dma3", "wait dma5",
                  "xfer per s", "xfer us each", "usb out shim", "usb producer", "usb in frame", "usb in build",
                  "usb out copy", "usb out enqueue", "usb out heal", "usb out pkts",
                  "alt frames", "frames"])
CSV_FIELDS = (["time", "label", "seconds", "polls", "FRAME IRQ"] + NAMES + [f"raw {n}" for n in NAMES]
              + [f"us {n}" for n in PROFILE_FIELDS] + ["DSP0 busy", "DSP1 busy"])


def csv_row(res, label):
    row = {"time": time.strftime("%Y-%m-%d %H:%M:%S"), "label": label, "seconds": f"{res['seconds']:.3f}",
           "polls": res["polls"], "FRAME IRQ": "" if res["frame_irq"] is None else f"{res['frame_irq']:.5f}"}
    row.update({n: f"{res['share'][n]:.5f}" for n in NAMES})
    row.update({f"raw {n}": f"{res['raw'][n]:.5f}" for n in NAMES})
    p = res.get("profile") or {}
    for n in PROFILE_FIELDS:
        v = p.get(n)
        row[f"us {n}"] = "" if v is None else (str(v) if isinstance(v, int) else f"{v:.3f}")
    d = res.get("dsp") or [None, None]
    row["DSP0 busy"] = "" if d[0] is None else f"{d[0]:.5f}"
    row["DSP1 busy"] = "" if d[1] is None else f"{d[1]:.5f}"
    return row


def append_csv(path, res, label):
    path = pathlib.Path(path)
    new = not path.exists()
    with path.open("a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        if new:
            w.writeheader()
        w.writerow(csv_row(res, label))


def selftest():
    """The arithmetic, with no unit: a wrap inside a poll, the FRAME IRQ correction, a wrong table."""
    def ledger(totals):
        return [(tcb, t % WRAP) for (tcb, _), t in zip(TASKS, totals)]
    acc = Accumulator()
    base = [WRAP - 1000] * 12                      # every total about to wrap
    acc.add(ledger(base), {"seq": 1, "window": 1000, "sum": 100, "count": 1, "longest": 1})
    step = [0] * 12
    step[NAMES.index("TASK 98A5C")] = 3000
    step[NAMES.index("IDLE")] = 7000
    acc.add(ledger([b + s for b, s in zip(base, step)]), {"seq": 2, "window": 1000, "sum": 100, "count": 1, "longest": 1})
    r = acc.result()
    assert r["counts"]["TASK 98A5C"] == 3000 and r["counts"]["IDLE"] == 7000, r["counts"]
    assert abs(r["raw"]["TASK 98A5C"] - 0.3) < 1e-12
    assert abs(r["frame_irq"] - 0.1) < 1e-12
    assert abs(r["share"]["TASK 98A5C"] - 0.27) < 1e-12 and abs(r["share"]["IDLE"] - 0.63) < 1e-12
    raw = struct.pack(">24I", *[w for tcb, t in ledger(base) for w in (tcb, t)])
    assert decode_ledger(raw)[8][0] == 0x46105508
    bad = bytearray(raw); bad[0] ^= 1
    try:
        decode_ledger(bytes(bad))
        raise AssertionError("a wrong TCB was accepted")
    except ValueError:
        pass
    fpw = lambda seq: struct.pack(">24I", seq, 66000000, 1378, 0, *[13200] * 6, 1320, 2640, 2756, 660, 0, 0,
                                  1320, 660, 1320, 660, 0, 0, 0, 0)
    acc = Accumulator()
    acc.add(ledger(base), {"seq": 1, "window": 66000000, "sum": 1378 * 26400, "count": 1378, "longest": 1}, decode_fp(fpw(1)))
    acc.add(ledger(base), {"seq": 2, "window": 66000000, "sum": 1378 * 26400, "count": 1378, "longest": 1}, decode_fp(fpw(2)))
    p = acc.result()["profile"]
    assert abs(p["head"] - 13200 / 1378 / CF_HZ * 1e6) < 1e-9, p
    assert abs(p["usb producer"] - 660 / 1378 / CF_HZ * 1e6) < 1e-9, p
    assert abs(p["frame"] - 200.0) < 1e-9 and abs(p["rest"] - (200.0 - 6 * p["head"] - p["xfer in frame"])) < 1e-9, p
    print("task_meter selftest: ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--for", dest="secs", type=float, default=2.0, help="seconds to measure (default 2)")
    ap.add_argument("--interval", type=float, default=0.25, help="seconds between polls (well under 32 s)")
    ap.add_argument("--watch", type=float, default=0, help="a measurement of this many seconds, repeated until interrupted")
    ap.add_argument("--csv", help="append the measurement to this CSV")
    ap.add_argument("--label", default="", help="the CSV row's label")
    ap.add_argument("--selftest", action="store_true", help="check the arithmetic, no unit needed")
    ap.add_argument("--windows", metavar="CSV", help="log every FRAME PROFILE window (0.5 s) for --for seconds to CSV, flagging OUT copy spikes")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    try:
        import usb.core  # noqa: F401
    except ImportError:
        sys.exit("pyusb is not installed: pip install pyusb libusb-package")
    unit = Unit()
    try:
        unit.ledger()
    except Exception as e:  # noqa: BLE001
        sys.exit(f"block 4 failed: {e} (a STALL means the image has no BRAIN, no USB, or a USB module without block 4)")
    if a.windows:
        return windows(unit, a.secs, a.windows)
    if a.watch:
        while True:
            print(fmt(measure(unit, a.watch, a.interval), top=6), flush=True)
    res = measure(unit, a.secs, a.interval)
    print(fmt(res))
    if res["frame_irq"] is None:
        print("(no LOAD METER in this image: shares are raw, the frame interrupt's time is inside the tasks)")
    if a.csv:
        append_csv(a.csv, res, a.label)
        print(f"appended to {a.csv}")


if __name__ == "__main__":
    sys.exit(main())
