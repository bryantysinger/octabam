#!/usr/bin/env python3
"""A hardware probe for USB AUDIO OUT (host -> A-D), for anyone with an
Octatrack on `usb-io` (or any image carrying USB AUDIO / USB AUDIO OUT) to
run against their own unit.

Written after a report (docs review, USB_AUDIO_PR468_REVIEW.md, 27 Sep 2026,
from an MKI tester) of macOS CoreAudio repeatedly restarting the stream's IO
context (100s-450s of times in short windows), output-only playback taking
roughly 2x its nominal length, and the EP3 IN ring (the implicit-feedback
source) losing thousands of frames -- none of which showed up on the one
MKII this was first measured on (PR #468's author). The USB controller code
has no MKI/MKII branch anywhere, so if the split is real it's most likely a
host/cable/macOS-version difference, or something about the unit itself
outside firmware -- this script exists to gather comparable numbers from
more testers and more hardware rather than guess.

Two modes:

  sustained (default): one continuous tone for --duration seconds, output
    only. Reproduces the "does a plain session run at nominal speed"
    question.

      tools/harness/usb_hw_probe.py --mode sustained --duration 10

  churn: opens and closes the output stream repeatedly (a short tone burst,
    a pause, repeat), which is closer to what actually triggered the
    reported failure -- CoreAudio's real host apps started and stopped the
    OT's IO context hundreds of times, not once.

      tools/harness/usb_hw_probe.py --mode churn --churn-cycles 100 \\
          --churn-on 0.3 --churn-off 0.1

Both modes poll USB AUDIO's counters (vendor 0xc0/0x55, the EP3 IN ring:
produced/overruns/bankdup/...) and USB AUDIO OUT's (0xc0/0x56, the EP3 OUT
ring: produced/underruns/overruns/bad/...) throughout, the same requests
tools/hw/usb_counters.py uses -- a device-recipient control request needs no
interface claim, so it runs alongside the CoreAudio client undisturbed.

  tools/harness/usb_hw_probe.py --list-devices     # find the CoreAudio name
  tools/harness/usb_hw_probe.py --unit mkii --json out/probe_mkii.json

Needs: `brew install portaudio`, then
`python3 -m pip install --user --break-system-packages sounddevice numpy pyusb`
(the libusb backend-finding is copied from tools/hw/usb_counters.py; see its
docstring if pyusb can't find libusb on this Mac).

`0x56` STALLs (reported, not fatal) on an image with no USB AUDIO OUT; the
EP3 OUT section of the report is then empty. `0x55` STALLs on an image with
no USB AUDIO at all.

If you hit anything that looks like the reported failure, please attach the
--json report to the PR or issue thread -- what's useful across testers is
the raw numbers, your unit (MKI/MKII), macOS version and host app, not just
a "worked" / "didn't work".
"""
import argparse
import glob
import json
import platform
import struct
import subprocess
import sys
import threading
import time

import numpy as np

OUT_NAMES = ("produced", "consumed", "pkts", "lastn", "lastfill", "underruns", "overruns",
             "reprimes", "bad", "frames", "seconds", "minfill", "maxfill",
             "err", "partial", "errmask", "lasttok", "lastslot",
             "depth", "badfr", "badfr_prev", "dry", "late", "maxpass",
             "good_nz", "bad_nz", "bad_nzw", "last_nzw")
IN_NAMES = ("consumed", "acc", "overruns", "underruns", "lastn", "lastfill", "lastbank",
            "bankdup", "lastsamp", "srcjump", "reprimes", "produced")

EXPECTED_RATE = 44100.0


def find_device():
    import usb.core
    import usb.backend.libusb1
    libs = (glob.glob("/usr/local/opt/libusb/lib/libusb-1.0.dylib") + glob.glob("/opt/homebrew/opt/libusb/lib/libusb-1.0.dylib")
            + glob.glob("/usr/local/lib/libusb-1.0*.dylib") + glob.glob("/usr/local/Cellar/libusb/*/lib/libusb-1.0*.dylib")
            + glob.glob("/opt/homebrew/lib/libusb-1.0*.dylib") + glob.glob("/opt/homebrew/Cellar/libusb/*/lib/libusb-1.0*.dylib"))
    backend = usb.backend.libusb1.get_backend(find_library=lambda _: libs[0]) if libs else None
    dev = usb.core.find(idVendor=0x1935, idProduct=0x0002, backend=backend)
    if dev is None:
        sys.exit("no Octatrack on USB (1935:0002) -- is it connected and enumerated?")
    return dev


def read_counters(dev, out):
    req, names = (0x56, OUT_NAMES) if out else (0x55, IN_NAMES)
    n = 4 * len(names)
    raw = bytes(dev.ctrl_transfer(0xc0, req, 0, 0, n, timeout=1000))
    if len(raw) != n:
        raise RuntimeError(f"{len(raw)} bytes back for {'OUT' if out else 'IN'} counters, expected {n}")
    return dict(zip(names, struct.unpack(f">{len(names)}I" if out else f">{len(names)}i", raw)))


class Poller(threading.Thread):
    """Polls both counter sets on a fixed interval until told to stop.
    Each STALL (an image missing that vendor request) is recorded once and
    then that ring is skipped for the rest of the run, so a probe on an
    older image still reports what it can."""

    def __init__(self, dev, interval):
        super().__init__(daemon=True)
        self.dev, self.interval = dev, interval
        self.samples = []   # (t, in_counters_or_None, out_counters_or_None)
        self.errors = []
        self._stop = threading.Event()
        self._have_in = self._have_out = True

    def run(self):
        t0 = time.monotonic()
        while not self._stop.is_set():
            t = time.monotonic() - t0
            ci = co = None
            if self._have_in:
                try:
                    ci = read_counters(self.dev, out=False)
                except Exception as e:  # noqa: BLE001
                    self.errors.append((t, "in", str(e)))
                    self._have_in = False
            if self._have_out:
                try:
                    co = read_counters(self.dev, out=True)
                except Exception as e:  # noqa: BLE001
                    self.errors.append((t, "out", str(e)))
                    self._have_out = False
            self.samples.append((t, ci, co))
            self._stop.wait(self.interval)

    def stop(self):
        self._stop.set()


def list_devices():
    import sounddevice as sd
    for i, d in enumerate(sd.query_devices()):
        print(f"{i}: {d['name']!r}  in={d['max_input_channels']} out={d['max_output_channels']}"
              f" default_sr={d['default_samplerate']}")


def find_output_device(name_substr):
    import sounddevice as sd
    devs = sd.query_devices()
    matches = [i for i, d in enumerate(devs) if name_substr.lower() in d["name"].lower() and d["max_output_channels"] > 0]
    if not matches:
        sys.exit(f"no CoreAudio output device matching {name_substr!r}; run --list-devices")
    if len(matches) > 1:
        sys.exit(f"{len(matches)} devices match {name_substr!r}: {[devs[i]['name'] for i in matches]}; be more specific")
    return matches[0]


def make_tone(duration, freq, level_dbfs, channel, n_channels, fs):
    amp = 10 ** (level_dbfs / 20)
    n = int(duration * fs)
    t = np.arange(n) / fs
    tone = (amp * np.sin(2 * np.pi * freq * t)).astype(np.float32)
    buf = np.zeros((n, n_channels), dtype=np.float32)
    buf[:, channel - 1] = tone
    return buf


def run_sustained(device, duration, freq, level_dbfs, channel, fs=44100, n_channels=4):
    import sounddevice as sd
    buf = make_tone(duration, freq, level_dbfs, channel, n_channels, fs)
    wall0 = time.monotonic()
    sd.play(buf, samplerate=fs, device=device, blocking=True)
    return {"wall_s": time.monotonic() - wall0, "cycles": 1, "requested_s": duration}


def run_churn(device, cycles, on_s, off_s, freq, level_dbfs, channel, fs=44100, n_channels=4):
    import sounddevice as sd
    buf = make_tone(on_s, freq, level_dbfs, channel, n_channels, fs)
    wall0 = time.monotonic()
    for _ in range(cycles):
        sd.play(buf, samplerate=fs, device=device, blocking=True)   # each call opens and closes the stream
        if off_s:
            time.sleep(off_s)
    return {"wall_s": time.monotonic() - wall0, "cycles": cycles, "requested_s": cycles * (on_s + off_s)}


def host_fingerprint():
    info = {"platform": platform.platform(), "python": sys.version.split()[0]}
    try:
        import sounddevice as sd
        info["sounddevice"] = sd.__version__
        info["portaudio"] = sd.get_portaudio_version()[1]
    except Exception:  # noqa: BLE001
        pass
    try:
        info["macos_version"] = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True, timeout=2).stdout.strip()
    except Exception:  # noqa: BLE001
        pass
    return info


def summarize(samples, errors):
    in_samples = [(t, c) for t, c, _ in samples if c is not None]
    out_samples = [(t, c) for t, _, c in samples if c is not None]
    summary = {"in_ring": None, "out_ring": None, "poll_errors": len(errors)}
    if len(in_samples) >= 2:
        (t0, c0), (t1, c1) = in_samples[0], in_samples[-1]
        dt = t1 - t0
        d_produced = c1["produced"] - c0["produced"]
        summary["in_ring"] = {
            "poll_span_s": dt,
            "produced_delta": d_produced,
            "implied_rate_hz": d_produced / dt if dt > 0 else None,
            "rate_ratio": (d_produced / dt / EXPECTED_RATE) if dt > 0 else None,
            "overruns_delta": c1["overruns"] - c0["overruns"],
            "underruns_delta": c1["underruns"] - c0["underruns"],
            "bankdup_delta": c1["bankdup"] - c0["bankdup"],
            "reprimes_delta": c1["reprimes"] - c0["reprimes"],
        }
    if len(out_samples) >= 2:
        (t0, c0), (t1, c1) = out_samples[0], out_samples[-1]
        summary["out_ring"] = {
            "produced_delta": c1["produced"] - c0["produced"],
            "underruns_delta": c1["underruns"] - c0["underruns"],
            "overruns_delta": c1["overruns"] - c0["overruns"],
            "bad_delta": c1["bad"] - c0["bad"],
            "minfill_final": c1["minfill"],
            "maxfill_final": c1["maxfill"],
        }
    return summary


def verdict(play_result, summary):
    # The wall/requested ratio only means "device pacing" in sustained mode.
    # In churn mode, each cycle opens a fresh PortAudio/CoreAudio stream, and
    # that per-cycle open/teardown overhead is pure host cost that has
    # nothing to do with the device -- 100 cycles easily adds 10-20s of
    # PortAudio overhead on top of the actual tone+pause time, so the same
    # 0.9-1.1 threshold used for sustained mode produces false failures here.
    # The EP3 counters (rate ratio, overrun/underrun/bankdup/bad) are the
    # unconfounded signal in churn mode; the wall ratio is reported but does
    # not gate the verdict.
    ratio = play_result["wall_s"] / play_result["requested_s"] if play_result["requested_s"] else None
    reasons = []
    if play_result["cycles"] == 1 and ratio is not None and not (0.9 <= ratio <= 1.1):
        reasons.append(f"wall/requested ratio {ratio:.3f} is outside 0.9-1.1 (the reported failure was 0.48-0.63)")
    ir = summary.get("in_ring")
    if ir:
        rr = ir.get("rate_ratio")
        if rr is not None and rr < 0.9:
            reasons.append(f"EP3 IN implied rate is {rr:.2f}x the expected 44,100/s")
        if ir["overruns_delta"] > 0 or ir["bankdup_delta"] > 0:
            reasons.append(f"EP3 IN overruns +{ir['overruns_delta']}, bankdup +{ir['bankdup_delta']} during an output-only session"
                            " (the reported failure's signature)")
    orr = summary.get("out_ring")
    if orr and orr["bad_delta"] > 0:
        reasons.append(f"EP3 OUT bad packets +{orr['bad_delta']}")
    if reasons:
        return "MATCHES_REPORTED_FAILURE", reasons
    if ratio is None or ir is None:
        return "AMBIGUOUS", ["not enough counter data to judge (STALLs or too few polls -- see poll_errors)"]
    return "CLEAN", ["ratio near 1.0, no overrun/bankdup/bad growth on either ring"]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mode", choices=("sustained", "churn"), default="sustained")
    ap.add_argument("--duration", type=float, default=10.0, help="sustained mode: requested playback length, seconds")
    ap.add_argument("--churn-cycles", type=int, default=100, help="churn mode: number of open/close cycles")
    ap.add_argument("--churn-on", type=float, default=0.3, help="churn mode: seconds of tone per cycle")
    ap.add_argument("--churn-off", type=float, default=0.1, help="churn mode: silent pause between cycles")
    ap.add_argument("--freq", type=float, default=440.0, help="tone frequency, Hz")
    ap.add_argument("--level", type=float, default=-20.0, help="tone level, dBFS")
    ap.add_argument("--channel", type=int, default=1, choices=(1, 2, 3, 4), help="host output channel (1=A .. 4=D); others silent")
    ap.add_argument("--poll-interval", type=float, default=0.1, help="seconds between counter polls")
    ap.add_argument("--device", default="Octatrack", help="substring matching the CoreAudio device name")
    ap.add_argument("--unit", choices=("mki", "mkii", "unknown"), default="unknown",
                     help="which hardware this is -- can't be read over USB, please set it")
    ap.add_argument("--build-note", default="", help="free text: image/build number, remix name, etc.")
    ap.add_argument("--json", type=str, default=None, help="write a structured report here")
    ap.add_argument("--list-devices", action="store_true", help="list CoreAudio devices and exit")
    args = ap.parse_args()

    if args.list_devices:
        list_devices()
        return 0

    dev = find_device()
    device = find_output_device(args.device)

    poller = Poller(dev, args.poll_interval)
    poller.start()
    if args.mode == "sustained":
        print(f"[sustained] {args.freq} Hz at {args.level} dBFS on channel {args.channel}, "
              f"requesting {args.duration:.1f} s, polling every {args.poll_interval*1000:.0f} ms ...")
        play_result = run_sustained(device, args.duration, args.freq, args.level, args.channel)
    else:
        print(f"[churn] {args.churn_cycles} cycles of {args.churn_on}s on / {args.churn_off}s off, "
              f"{args.freq} Hz at {args.level} dBFS on channel {args.channel} ...")
        play_result = run_churn(device, args.churn_cycles, args.churn_on, args.churn_off, args.freq, args.level, args.channel)
    time.sleep(0.3)   # let a couple more polls land after the stream closes
    poller.stop()
    poller.join(timeout=2)

    summary = summarize(poller.samples, poller.errors)
    verdict_str, reasons = verdict(play_result, summary)

    ratio = play_result["wall_s"] / play_result["requested_s"] if play_result["requested_s"] else float("nan")
    note = "" if play_result["cycles"] == 1 else "  (informational only in churn mode -- per-cycle stream-open overhead inflates this; see EP3 counters)"
    print(f"\nwall clock: {play_result['wall_s']:.2f} s over {play_result['cycles']} cycle(s), "
          f"requested {play_result['requested_s']:.2f} s (ratio {ratio:.3f}){note}")
    if summary["in_ring"]:
        ir = summary["in_ring"]
        print(f"EP3 IN:  produced +{ir['produced_delta']} over {ir['poll_span_s']:.2f}s poll span "
              f"(implied {ir['implied_rate_hz']:.0f}/s, ratio {ir['rate_ratio']:.3f}); "
              f"overruns +{ir['overruns_delta']} underruns +{ir['underruns_delta']} "
              f"bankdup +{ir['bankdup_delta']} reprimes +{ir['reprimes_delta']}")
    else:
        print("EP3 IN:  no data (STALLed -- image has no USB AUDIO?)")
    if summary["out_ring"]:
        orr = summary["out_ring"]
        print(f"EP3 OUT: produced +{orr['produced_delta']}, underruns +{orr['underruns_delta']} "
              f"overruns +{orr['overruns_delta']} bad +{orr['bad_delta']}, "
              f"minfill/maxfill {orr['minfill_final']}/{orr['maxfill_final']}")
    else:
        print("EP3 OUT: no data (STALLed -- image has no USB AUDIO OUT?)")
    if poller.errors:
        print(f"{len(poller.errors)} poll error(s) during the run (see JSON for detail)")

    print(f"\nVERDICT: {verdict_str}")
    for r in reasons:
        print(f"  - {r}")

    if args.json:
        report = {
            "mode": args.mode,
            "params": vars(args),
            "host": host_fingerprint(),
            "unit": args.unit,
            "build_note": args.build_note,
            "play_result": play_result,
            "summary": summary,
            "poll_errors": poller.errors,
            "verdict": verdict_str,
            "verdict_reasons": reasons,
        }
        with open(args.json, "w") as f:
            json.dump(report, f, indent=2)
        print(f"\nwrote {args.json} -- attach this to the PR/issue thread if you hit MATCHES_REPORTED_FAILURE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
