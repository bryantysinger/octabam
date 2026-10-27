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


class Accumulator:
    """Ledger readings in, per-task counts out: each poll's delta is taken modulo 2^32 and summed,
    so a measurement can run for any length as long as polls stay under the wrap."""

    def __init__(self):
        self.prev = None
        self.counts = [0] * 12
        self.irq_shares = []
        self.last_seq = None
        self.polls = 0

    def add(self, ledger, stats=None):
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

    def result(self):
        total = sum(self.counts)
        raw = [c / total if total else 0.0 for c in self.counts]
        irq = sum(self.irq_shares) / len(self.irq_shares) if self.irq_shares else None
        shares = [r * (1 - irq) for r in raw] if irq is not None else raw
        return {"seconds": total / CF_HZ, "polls": self.polls, "frame_irq": irq,
                "raw": dict(zip(NAMES, raw)), "share": dict(zip(NAMES, shares)),
                "counts": dict(zip(NAMES, self.counts))}


def measure(unit, secs, interval=0.25):
    if interval >= 30:
        sys.exit("--interval must stay well under the ledger's 32.5 s wrap")
    acc = Accumulator()
    t_end = time.monotonic() + secs
    acc.add(unit.ledger(), unit.stats())
    while True:
        time.sleep(interval)
        acc.add(unit.ledger(), unit.stats())
        if time.monotonic() >= t_end:
            return acc.result()


def fmt(res, top=None):
    order = sorted(NAMES, key=lambda n: -res["share"][n])
    parts = []
    if res["frame_irq"] is not None:
        parts.append(f"FRAME IRQ {100 * res['frame_irq']:5.1f}%")
    for n in order[:top] if top else order:
        if top or res["share"][n] > 0:
            parts.append(f"{n} {100 * res['share'][n]:5.1f}%")
    return f"{res['seconds']:5.2f} s  " + "  ".join(parts)


CSV_FIELDS = ["time", "label", "seconds", "polls", "FRAME IRQ"] + NAMES + [f"raw {n}" for n in NAMES]


def csv_row(res, label):
    row = {"time": time.strftime("%Y-%m-%d %H:%M:%S"), "label": label, "seconds": f"{res['seconds']:.3f}",
           "polls": res["polls"], "FRAME IRQ": "" if res["frame_irq"] is None else f"{res['frame_irq']:.5f}"}
    row.update({n: f"{res['share'][n]:.5f}" for n in NAMES})
    row.update({f"raw {n}": f"{res['raw'][n]:.5f}" for n in NAMES})
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
    print("task_meter selftest: ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--for", dest="secs", type=float, default=2.0, help="seconds to measure (default 2)")
    ap.add_argument("--interval", type=float, default=0.25, help="seconds between polls (well under 32 s)")
    ap.add_argument("--watch", type=float, default=0, help="a measurement of this many seconds, repeated until interrupted")
    ap.add_argument("--csv", help="append the measurement to this CSV")
    ap.add_argument("--label", default="", help="the CSV row's label")
    ap.add_argument("--selftest", action="store_true", help="check the arithmetic, no unit needed")
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
