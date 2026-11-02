#!/usr/bin/env python3
"""Where the ColdFire's time goes on the unit: PC SAMPLER's histograms
(modules/pc-sampler, a 20 kHz level-6 PC sample on PIT3), read twice over USB
and differenced.

    python3 tools/hw/pc_sampler.py LABEL [--secs 10] [--map out/platform/runtime/runtime.map] [--top 30]

Set the unit up first (load the project, pick the pattern, press play); the
script only reads, so the USB traffic is two snapshots (about 24 KB each over
0xc0/0x59) and nothing in between. It prints:

  ipl      the share of samples by the interrupted context's IPL: 5 is the
           frame interrupt (and anything that masks to 5), 0 tasks and idle
  hot      runs of hot code: address range, a name where the code is known
           (KNOWN below; payload code by --map's nearest symbol), percent of
           all samples and microseconds per frame (2,756.25 frames a second)
  frame    the IPL-5 samples alone, as microseconds per frame: comparable with
           LOAD METER's frame mean

and writes out/hw/pcs/LABEL.json (header, the two snapshots' totals, the
differenced buckets). Samples at level 6 and above are not taken inside the
level-6 eDMA handler or a 0x2700 section (sampler.s): their time lands on the
instruction after.
"""
import argparse
import bisect
import json
import pathlib
import struct
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import load_meter as L  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "out/hw/pcs"
FRAMES_S = 44100 / 16

# stock code that matters for the recorders (docs/firmware/RECORDER.md, FRAME PROFILE's sections,
# the port's --isr-meter, 1 Nov 2026): (start, end, name); the first match names a bucket
KNOWN = [
    (0x400076f8, 0x40007738, "rec write: stage 1, source gains (EMAC)"),
    (0x40007786, 0x40007814, "rec write: stage 2, mix with old (EMAC)"),
    (0x40007826, 0x400078ca, "rec write: pack to buffer"),
    (0x40007920, 0x40007b40, "rec write: unpack from buffer"),
    (0x40007540, 0x400076f8, "rec write: source fetch"),
    (0x40007240, 0x40007480, "rec write: segments / position"),
    (0x400068e4, 0x4000795c, "rec write: other"),
    (0x40005ff0, 0x40006100, "rec trig handler"),
    (0x40005c7c, 0x40005e48, "rec arm"),
    (0x40003500, 0x40003900, "renderer (voices; eDMA polls 0x400035a8 / 0x40003780)"),
    (0x40004840, 0x40004bd0, "eDMA level-6 handler"),
    (0x4000aad0, 0x4000ab08, "frame: entry"),
    (0x4000ab08, 0x4000d0de, "frame: head (host commands, sequencer)"),
    (0x4000d0de, 0x4000d31a, "frame: calls, track prep"),
    (0x4000d31a, 0x4000d3d4, "frame: recorder dispatcher"),
    (0x4000d3d4, 0x4000d562, "frame: packer, renderers"),
    (0x4000d562, 0x4000d9b0, "frame: mix, MIDI, exit"),
    (0x40008400, 0x40008900, "per-voice (0x400084c0.., grows with loops)"),
    (0x40004000, 0x40004400, "0x40004000.. (grows with loops)"),
    (0x4001fc80, 0x4001fcc0, "idle (main's wait, 0x4001fc9c)"),
]


def known(addr):
    for a, b, n in KNOWN:
        if a <= addr < b:
            return n
    return None


def load_map(path):
    syms = []
    try:
        for line in pathlib.Path(path).read_text().splitlines():
            p = line.split()
            if len(p) == 2 and p[0].startswith("0x") and not p[1].startswith(("0x", ".", "*")) and "=" not in line:
                try:
                    syms.append((int(p[0], 16), p[1]))
                except ValueError:
                    pass
    except OSError:
        return [], []
    syms.sort()
    return [a for a, _ in syms], [n for _, n in syms]


class Unit:
    def __init__(self):
        self.dev = L.libusb_device()
        try:
            raw = L.read_block(self._ctrl, 6, 64)
        except Exception as e:  # noqa: BLE001
            sys.exit(f"no PC SAMPLER header (0xc0/0x57 block 6 STALLs: {e}); flash a remix with PC SAMPLER")
        h = struct.unpack(">16I", raw)
        if h[0] != 0x50435331:
            sys.exit(f"block 6 is not PC SAMPLER's header (magic {h[0]:#x})")
        self.rate = h[3]
        self.lo = dict(base=h[4], size=h[5], n=h[6], addr=h[7])
        self.hi = dict(base=h[8], size=h[9], n=h[10], addr=h[11])
        self.ipl_addr = h[12]
        self.hdr_addr = None

    def _ctrl(self, w, off, n):
        return bytes(self.dev.ctrl_transfer(0xc0, 0x57, w, off, n, timeout=1000))

    def peek(self, addr, n):
        """One USB packet a request (60 bytes): replies of 255 bytes came back with their last bytes wrong
        now and then (1 Nov 2026: the counters either side of a 255-byte boundary, x4 and x7), so no
        multi-packet reply is trusted until 0xc0/0x59's long replies are understood."""
        out = b""
        while len(out) < n:
            k = min(n - len(out), 60)
            a = addr + len(out)
            out += bytes(self.dev.ctrl_transfer(0xc0, 0x59, a & 0xFFFF, a >> 16, k, timeout=1000))
        return out

    def snapshot(self):
        hdr = struct.unpack(">16I", L.read_block(self._ctrl, 6, 64))
        ipl = struct.unpack(">8I", self.peek(self.ipl_addr, 32))
        lo = struct.unpack(f">{self.lo['n']}I", self.peek(self.lo["addr"], 4 * self.lo["n"]))
        hi = struct.unpack(f">{self.hi['n']}I", self.peek(self.hi["addr"], 4 * self.hi["n"]))
        return {"t": time.monotonic(), "total": hdr[1], "other": hdr[2], "ipl": ipl, "lo": lo, "hi": hi}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("label")
    ap.add_argument("--secs", type=float, default=10.0)
    ap.add_argument("--map", default=str(ROOT / "out/platform/runtime/runtime.map"),
                    help="the flashed image's runtime map, for octabam code's names (the last `make` here)")
    ap.add_argument("--top", type=int, default=30)
    a = ap.parse_args()
    u = Unit()
    s0 = u.snapshot()
    time.sleep(a.secs)
    s1 = u.snapshot()
    secs = s1["t"] - s0["t"]
    n = (s1["total"] - s0["total"]) % (1 << 32)
    if not n:
        sys.exit("no samples between the two reads: is the sampler running?")
    per_frame = lambda c: c / n * 1e6 / FRAMES_S     # a share of the time, as microseconds of each 362.8 us frame
    ipl = [(b - c) % (1 << 32) for b, c in zip(s1["ipl"], s0["ipl"])]
    print(f"{a.label}: {n} samples in {secs:.1f} s ({n / secs:.0f}/s; nominal {u.rate})")
    print("ipl    " + "  ".join(f"{i}:{100 * c / n:5.1f}%" for i, c in enumerate(ipl) if c))
    print(f"frame  IPL 5 = {per_frame(ipl[5]):.1f} us a frame (LOAD METER's mean is the comparable figure)")
    addrs, names = load_map(a.map)
    buckets = []
    for rng, key in ((u.lo, "lo"), (u.hi, "hi")):
        for i, (b, c) in enumerate(zip(s1[key], s0[key])):
            d = (b - c) % (1 << 32)
            if d > n:                                  # a counter cannot rise by more than every sample: a bad read
                print(f"  dropped {rng['base'] + i * rng['size']:#x}: {c} -> {b} (a bad read, not a count)")
                continue
            if d:
                buckets.append((rng["base"] + i * rng["size"], rng["size"], d))
    other = (s1["other"] - s0["other"]) % (1 << 32)

    def name(addr):
        k = known(addr)
        if k:
            return k
        if addrs and addr >= 0x40a00000:
            j = bisect.bisect_right(addrs, addr) - 1
            if j >= 0:
                return f"{names[j]}+{addr - addrs[j]:#x}"
        return ""
    # runs: neighbouring buckets with the same name
    buckets.sort()
    runs = []
    for addr, size, c in buckets:
        nm = name(addr)
        if runs and runs[-1]["name"] == nm and addr <= runs[-1]["end"] + size and nm:
            runs[-1]["end"] = addr + size
            runs[-1]["n"] += c
        elif runs and not nm and not runs[-1]["name"] and addr == runs[-1]["end"]:
            runs[-1]["end"] = addr + size
            runs[-1]["n"] += c
        else:
            runs.append({"start": addr, "end": addr + size, "name": nm, "n": c})
    runs.sort(key=lambda r: -r["n"])
    print(f"hot    (other code, outside both ranges: {100 * other / n:.1f}%)")
    for r in runs[:a.top]:
        print(f"  {r['start']:#010x}-{r['end']:#010x} {100 * r['n'] / n:5.1f}%  {per_frame(r['n']):6.1f} us/frame  {r['name']}")
    # by name, summed
    by = {}
    for r in runs:
        by[r["name"] or "(unnamed)"] = by.get(r["name"] or "(unnamed)", 0) + r["n"]
    print("by name")
    for k, c in sorted(by.items(), key=lambda kv: -kv[1])[:a.top]:
        print(f"  {per_frame(c):6.1f} us/frame  {100 * c / n:5.1f}%  {k}")
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"{a.label}.json"
    path.write_text(json.dumps({"label": a.label, "secs": secs, "samples": n, "rate": u.rate, "ipl": ipl,
                                "other": other, "buckets": buckets, "time": time.strftime("%Y-%m-%d %H:%M:%S")}))
    print(f"wrote {path}")


if __name__ == "__main__":
    main()
