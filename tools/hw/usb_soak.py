#!/usr/bin/env python3
"""USB audio IN/OUT soak: round-trip latency, click by click, for as long as
you like, with the unit's ring counters alongside. Bryan T, 22 Oct 2026.

    tools/hw/usb_soak.py --minutes 20
    tools/hw/usb_soak.py --minutes 20 --csv out/soak.csv --label build4

One full-duplex stream on the Octatrack (sounddevice, one device clock both
ways). A short click goes out on host channel --play-ch (1 = input A) once a
second; each one is found on unit channel --rec-ch (1 = MAIN L) by
cross-correlation, and its round trip is the sample index it came back at
minus the index it went out at. Both indices count frames of the same
stream, so the figure is the round trip as a host app sees it: CoreAudio's
buffers both ways, the two USB rings, the DSP frames.

What a fault looks like:
  latency step   every click after it comes back a fixed number of samples
                 early or late: frames lost or repeated somewhere in the path
                 (the host's buffers or the unit's rings). Reported with the
                 click it happened at.
  missing click  no peak above --min-corr: a click lost or corrupted.
  host xrun      sounddevice's input overflow / output underflow flags: the
                 HOST side missed a deadline (not the unit).
  counters       the audio-out ring (0x55: overruns, underruns, bankdup,
                 srcjump, reprimes) and the audio-in ring (0x56: underruns,
                 overruns, reprimes, bad, err, partial), read over EP0 every
                 --poll seconds as tools/hw/usb_counters.py does; the deltas
                 while the stream ran are reported. Needs pyusb and libusb
                 (usb_counters.py's docstring); without them the soak runs on
                 the audio alone.

On the unit: the remix carries USB IN and USB OUT with MAIN (e.g.
usb-io-main-cue-abcd); the mixer routes the input to MAIN (DIR up for AB),
nothing else playing. Needs numpy and sounddevice. The stream opens with
small buffers (--latency low, as a DAW would); each click is searched for in
1.5x the stream's reported latency plus 50 ms.

Measured (22 Oct 2026, Bryan T's MKII, usb-io-stock14 / OCTABAM4, macOS,
--minutes 20): 1,200 clicks, every one at 1231.01 samples (27.91 ms), spread
0.02 samples; no step, no missing click, no host xrun; every counter on both
rings +0. CoreAudio reported 10.00 ms in + 15.92 ms out for its own buffers.
"""
import argparse
import csv
import os
import sys
import threading
import time

import numpy as np
import sounddevice as sd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

FS = 44100
PERIOD = FS                 # one click a second
FIRST = FS // 2             # the first click half a second in
CLICK_LEN = 48
OUT_FIELDS = ("overruns", "underruns", "bankdup", "srcjump", "reprimes")
IN_FIELDS = ("underruns", "overruns", "reprimes", "bad", "err", "partial")


def click():
    n = np.arange(CLICK_LEN)
    w = 0.5 - 0.5 * np.cos(2 * np.pi * (n + 0.5) / CLICK_LEN)
    return (w * np.sin(2 * np.pi * 3000 * n / FS)).astype(np.float64)


def find_audio(name):
    for i, d in enumerate(sd.query_devices()):
        if name.lower() in d["name"].lower() and d["max_input_channels"] >= 1 and d["max_output_channels"] >= 2:
            return i
    sys.exit(f"no audio device matching '{name}' (try --list)")


def open_counters():
    try:
        import usb_probe
        dev = usb_probe.find_device()
        if dev is None:
            return None, None, "the unit was not found over libusb"
        return dev, usb_probe.read_counters, None
    except Exception as e:  # noqa: BLE001
        return None, None, f"counters unavailable ({e})"


class Soak:
    def __init__(self, n_out, n_in, play_ch, rec_ch, level, maxlat):
        self.n_out, self.n_in = n_out, n_in
        self.play, self.rec = play_ch - 1, rec_ch - 1
        self.tpl = click()
        self.amp = level
        self.maxlat = maxlat
        self.ring = np.zeros(8 * FS, dtype=np.float32)
        self.w = 0                  # frames written into the ring (global index)
        self.o = 0                  # frames sent out (global index)
        self.xin = self.xout = 0
        self.lock = threading.Lock()

    def cb(self, indata, outdata, frames, t, status):
        if status.input_overflow:
            self.xin += 1
        if status.output_underflow:
            self.xout += 1
        outdata.fill(0)
        # the first click that still has samples at or after this block's
        # start: one that began in the previous block finishes here
        k0 = max(0, -(-(self.o - FIRST - CLICK_LEN + 1) // PERIOD))
        while True:
            start = FIRST + k0 * PERIOD
            if start >= self.o + frames:
                break
            a, b = max(start, self.o), min(start + CLICK_LEN, self.o + frames)
            if a < b:
                outdata[a - self.o:b - self.o, self.play] = self.amp * self.tpl[a - start:b - start]
            k0 += 1
        self.o += frames
        r = len(self.ring)
        i = self.w % r
        x = indata[:, self.rec]
        j = min(frames, r - i)
        self.ring[i:i + j] = x[:j]
        self.ring[:frames - j] = x[j:]
        with self.lock:
            self.w += frames

    def window(self, a, n):
        r = len(self.ring)
        idx = (np.arange(a, a + n)) % r
        return self.ring[idx].astype(np.float64)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--device", default="Octatrack")
    ap.add_argument("--minutes", type=float, default=20)
    ap.add_argument("--play-ch", type=int, default=1, help="host output channel, 1 = input A")
    ap.add_argument("--rec-ch", type=int, default=1, help="unit channel the click comes back on, 1 = MAIN L")
    ap.add_argument("--level", type=float, default=-12, help="click peak, dBFS")
    ap.add_argument("--maxlat", type=float, default=None,
                    help="longest round trip searched, ms (default: the stream's reported in + out latency, x1.5, + 50 ms)")
    ap.add_argument("--latency", default="low",
                    help="sounddevice stream latency: low (a DAW's small buffers), high, or seconds")
    ap.add_argument("--min-corr", type=float, default=0.9, help="a click below this normalised correlation is missing")
    ap.add_argument("--poll", type=float, default=5, help="seconds between counter reads")
    ap.add_argument("--report", type=float, default=60, help="seconds between progress lines")
    ap.add_argument("--csv", default=None, help="write every click: index, seconds, latency samples, ms, corr")
    ap.add_argument("--label", default="")
    a = ap.parse_args()
    if a.list:
        print(sd.query_devices())
        return
    dev = int(a.device) if a.device.isdigit() else find_audio(a.device)
    info = sd.query_devices(dev)
    n_in, n_out = int(info["max_input_channels"]), int(info["max_output_channels"])
    if not 1 <= a.play_ch <= n_out or not 1 <= a.rec_ch <= n_in:
        sys.exit(f"{info['name']} has {n_out} outputs and {n_in} inputs")
    s = Soak(n_out, n_in, a.play_ch, a.rec_ch, 10 ** (a.level / 20), 0)
    try:
        lat_arg = float(a.latency)
    except ValueError:
        lat_arg = a.latency
    udev, read, why = open_counters()
    print(f"device {dev}: {info['name']}, {n_in} in / {n_out} out; click host ch {a.play_ch} -> unit ch {a.rec_ch}, "
          f"{a.minutes:g} min{', ' + a.label if a.label else ''}")
    if why:
        print(f"  {why}: audio only")

    def counters():
        if udev is None:
            return None
        out = {}
        for ep3out, key in ((False, "out"), (True, "in")):
            try:
                out[key] = read(udev, ep3out)
            except Exception:  # noqa: BLE001
                out[key] = None
        return out

    def deltas(c0, c1):
        d = {}
        for key, fields in (("out", OUT_FIELDS), ("in", IN_FIELDS)):
            if c0 and c1 and c0.get(key) and c1.get(key):
                d.update({f"{key}.{f}": c1[key][f] - c0[key][f] for f in fields})
        return d

    rows, lat_ref, steps, missing = [], None, [], []
    tpl = s.tpl
    tn = np.linalg.norm(tpl)
    end_frames = int(a.minutes * 60 * FS)
    with sd.Stream(device=dev, samplerate=FS, channels=(n_in, n_out), dtype="float32",
                   latency=lat_arg, callback=s.cb) as st:
        lat_io = st.latency
        ms = a.maxlat if a.maxlat is not None else 1.5 * 1000 * (lat_io[0] + lat_io[1]) + 50
        s.maxlat = int(min(ms, 900) * FS / 1000)
        print(f"  stream latency in {lat_io[0] * 1000:.2f} ms + out {lat_io[1] * 1000:.2f} ms; "
              f"each click searched for {s.maxlat * 1000 / FS:.0f} ms")
        time.sleep(1.0)
        c_start = counters()
        t0 = time.monotonic()
        k, last_report, last_poll = 0, t0, t0
        c_last = c_start
        while True:
            with s.lock:
                w = s.w
            start = FIRST + k * PERIOD
            if start > end_frames and w > start:
                break
            need = start + s.maxlat + CLICK_LEN
            if w >= need and w - start >= len(s.ring) - FS:
                # this click's window was overwritten before it was read (the
                # analysis fell behind): count it as unread and move on
                missing.append((k, float("nan")))
                rows.append((k, start / FS, float("nan"), float("nan"), 0.0, False))
                k += 1
                continue
            if w >= need:
                y = s.window(start, s.maxlat + CLICK_LEN)
                c = np.correlate(y, tpl, mode="valid")
                i = int(np.argmax(np.abs(c)))
                seg = y[i:i + CLICK_LEN]
                corr = float(abs(c[i]) / (tn * max(np.linalg.norm(seg), 1e-12)))
                frac = 0.0
                if 0 < i < len(c) - 1:
                    y0, y1, y2 = abs(c[i - 1]), abs(c[i]), abs(c[i + 1])
                    den = y0 - 2 * y1 + y2
                    frac = 0.5 * (y0 - y2) / den if den else 0.0
                lat = i + frac
                ok = corr >= a.min_corr
                if not ok:
                    missing.append((k, corr))
                elif lat_ref is None:
                    lat_ref = lat
                elif abs(lat - lat_ref) > 0.5:
                    steps.append((k, lat_ref, lat))
                    lat_ref = lat
                rows.append((k, start / FS, lat, lat * 1000 / FS, corr, ok))
                k += 1
                continue
            if w < start and time.monotonic() - t0 > a.minutes * 60 + 30:
                print("  the stream stopped delivering input; ending")
                break
            now = time.monotonic()
            if now - last_poll >= a.poll:
                c_last = counters() or c_last
                last_poll = now
            if now - last_report >= a.report:
                good = [r[2] for r in rows if r[5]]
                d = deltas(c_start, c_last)
                bad = {kk: v for kk, v in d.items() if v}
                print(f"  {(now - t0) / 60:5.1f} min  clicks {len(rows)}  latency "
                      + (f"{min(good):.1f}..{max(good):.1f} samples ({np.median(good) * 1000 / FS:.2f} ms)" if good else "-")
                      + f"  steps {len(steps)}  missing {len(missing)}  host xruns in/out {s.xin}/{s.xout}"
                      + (f"  counters {bad}" if bad else ("  counters clean" if d else "")))
                last_report = now
            time.sleep(0.05)
        c_end = counters()
    good = np.array([r[2] for r in rows if r[5]])
    print(f"\nlabel {a.label or '-'}: {len(rows)} clicks over {rows[-1][1] / 60 if rows else 0:.1f} min")
    if len(good):
        print(f"  round trip: median {np.median(good):.2f} samples ({np.median(good) * 1000 / FS:.2f} ms), "
              f"min {good.min():.2f}, max {good.max():.2f}, spread {good.max() - good.min():.2f} samples")
    print(f"  CoreAudio's own figure for the stream: in {lat_io[0] * 1000:.2f} ms + out {lat_io[1] * 1000:.2f} ms")
    print(f"  latency steps: {len(steps)}" + "".join(f"\n    click {kk} ({kk + 0.5:.0f} s): {r0:.2f} -> {r1:.2f} samples ({r1 - r0:+.2f})" for kk, r0, r1 in steps[:20]))
    print(f"  missing clicks: {len(missing)}" + "".join(f"\n    click {kk}: corr {cc:.3f}" for kk, cc in missing[:20]))
    print(f"  host xruns: input overflow {s.xin}, output underflow {s.xout}")
    d = deltas(c_start, c_end)
    if d:
        print("  unit counters over the run: " + ", ".join(f"{kk} {v:+d}" for kk, v in d.items()))
    else:
        print("  unit counters: not read")
    clean = not steps and not missing and not s.xin and not s.xout and not any(d.values())
    print(f"  verdict: {'CLEAN' if clean else 'NOT CLEAN'}")
    if a.csv:
        with open(a.csv, "w", newline="") as fh:
            wr = csv.writer(fh)
            wr.writerow(["click", "seconds", "latency_samples", "latency_ms", "corr", "found"])
            wr.writerows(rows)
        print(f"  clicks written to {a.csv}")


if __name__ == "__main__":
    main()
