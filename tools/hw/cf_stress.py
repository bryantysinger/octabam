#!/usr/bin/env python3
"""ColdFire / DSP load stress test, one image at a time, read through CF METER.

    python3 tools/hw/cf_stress.py check  --image 3 --layout maincue
    python3 tools/hw/cf_stress.py run    --image 3 --layout maincue [--sweep burn]
    python3 tools/hw/cf_stress.py sweep  --image 7 --layout tracksmaincue --what burn

Needs: an image with CF METER + CF METER IDLE (T8 FX2 = CF Meter, BURN and
DBRN at 0), the recorder compiled (swiftc -O tools/hw/rec.swift -o tools/hw/rec),
USB to the Mac, and a MIDI route to the OT (PROG CHANGE receive on, transport
receive on).

The project carries the recorder count as patterns, same playback trigs in
each (T1-7), recorder trigs only:

    pattern  PC   state
    A01      0    rec0   no recorder trigs
    A02      1    rec2   2 recorders
    A03      2    rec4   4 recorders
    A04      3    rec8   all 8 recorders

Override with --patterns rec0:0,rec2:1,rec4:2,rec8:3. Each state is entered
from STOP (program change while stopped switches at once), then START.

States per image (run): stopped, then for each pattern: playing. Two takes
of 12 s each by default (a CF METER cycle is 2 s; 12 s gives 4-5 rows). After
each state you are asked for a screen-lag rating (0 none .. 3 unusable;
Enter skips); poke the UI during the takes so the rating means something.

Sweep: in the heaviest pattern, playing, step BURN (CC 40, 2 us of busy-wait
per step in the frame interrupt) or DBRN (CC 42, 24 x DBRN DSP cycles per
sample) on T8's channel until the readout breaks. The knob is put back to 0
on every exit path; if the unit freezes, power-cycle it and do NOT save the
Part before checking BURN/DBRN are 0 (they are stored like any knob).

Every take is appended to <out>/cf_stress.csv, wavs beside it.

Readout channels (0-based L,R of T8 in the capture), by --layout:
    tracks, tracksmaincue   14,15  (T8 on USB channels 15/16)
    master                  0,1    (OUT MASTER carries T8's L/R)
    maincue                 2,3    (CUE: cue T8 ALONE; verify with `check` first)
"""
import argparse, csv, datetime as dt, math, pathlib, statistics, subprocess, sys, time

ROOT = pathlib.Path(__file__).resolve().parents[2]
REC = ROOT / "tools/hw/rec"
sys.path.insert(0, str(ROOT / "tools/harness"))
sys.path.insert(0, str(ROOT / "tools/hw"))
import cfmeter                                             # noqa: E402

LAYOUT_LR = {"tracks": (14, 15), "tracksmaincue": (14, 15), "master": (0, 1), "maincue": (2, 3)}
PERIOD_US = 16 / 44100 * 1e6                               # 362.8 us
CC_BURN, CC_DBRN = 40, 42                                  # T8 FX2 page-1 slots 0 and 2

FIELDS = ["time", "image", "layout", "phase", "state", "take", "knob", "knob_val", "rows",
          "idle_pct", "isr_mean_us", "isr_max_us", "isr_max_worst_us", "isr_pct", "period_us",
          "burn_us", "spin_min", "spin_max", "tue", "roe", "dsp_per_min_us", "dsp_per_max_us",
          "frames", "lag", "verdict", "wav"]


# ---------------------------------------------------------------- decode

def decode(path, lr):
    """cfmeter's own decode, reduced to one record: medians over the cycles,
    plus the worst ISR max seen in any cycle. None if no sync was found."""
    L, R = cfmeter.load_wav(str(path), lr)
    rows = cfmeter.cycles(cfmeter.per_block(L, R))
    if not rows:
        return None
    us = lambda q: q * 4 / cfmeter.CLK * 1e6
    dus = lambda q: q * 4 / cfmeter.DSPCLK2 * 1e6
    med = lambda j: statistics.median(r[j] for r in rows)
    per = us(med(5))
    return {
        "rows": len(rows),
        "idle_pct": med(2) / 16384 * 100,
        "isr_mean_us": us(med(3)),
        "isr_max_us": us(med(4)),
        "isr_max_worst_us": max(us(r[4]) for r in rows),
        "isr_pct": us(med(3)) / per * 100 if per else math.nan,
        "period_us": per,
        "burn_us": us(med(7)),
        "spin_min": med(8), "spin_max": med(9),
        "tue": med(10), "roe": med(11),
        "dsp_per_min_us": dus(med(13)), "dsp_per_max_us": dus(med(14)),
        "frames": med(15),
    }


def summary(d):
    if d is None:
        return "NO SYNC (readout not found on these channels, or the unit stopped streaming)"
    return (f"idle {d['idle_pct']:5.1f} %  isr mean {d['isr_mean_us']:6.1f} us  "
            f"max {d['isr_max_us']:6.1f} (worst {d['isr_max_worst_us']:6.1f})  "
            f"period {d['period_us']:6.1f}  spin min {d['spin_min']:.0f}  "
            f"TUE {d['tue']:.0f} ROE {d['roe']:.0f}  [{d['rows']} rows]")


def broken(d, what):
    """Why this reading counts as the wall, or '' if it does not."""
    if d is None:
        return "no sync"
    if abs(d["period_us"] - PERIOD_US) > 0.02 * PERIOD_US:
        return f"CF period {d['period_us']:.1f} us"
    if d["tue"] > 0 or d["roe"] > 0:
        return f"ESAI TUE {d['tue']:.0f} ROE {d['roe']:.0f}"
    if what == "dbrn" and d["dsp_per_max_us"] > 1.5 * PERIOD_US:
        return f"DSP period max {d['dsp_per_max_us']:.1f} us (late frame)"
    return ""


# ---------------------------------------------------------------- hardware

class Rig:
    def __init__(self, a):
        import ot_midi                                     # CoreMIDI: macOS only
        self.a = a
        self.out = ot_midi.Out(a.port)
        self.lr = tuple(int(v) for v in a.lr.split(",")) if a.lr else LAYOUT_LR[a.layout]
        self.dir = pathlib.Path(a.out)
        self.dir.mkdir(parents=True, exist_ok=True)
        self.csv = self.dir / "cf_stress.csv"
        if not REC.is_file():
            sys.exit(f"compile the recorder: swiftc -O tools/hw/rec.swift -o {REC}")

    def midi(self, data):
        self.out.send(data)
        time.sleep(0.05)

    def stop(self):
        self.midi([0xFC])

    def start(self):
        self.midi([0xFA])

    def pattern(self, pc):
        self.midi([0xC0 | (self.a.auto_ch - 1), pc])

    def knob(self, cc, val):
        self.midi([0xB0 | (self.a.t8_ch - 1), cc, val])

    def take(self, tag, secs=None):
        secs = secs or self.a.secs
        ts = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        wav = self.dir / f"img{self.a.image}_{tag}_{ts}.wav"
        try:
            subprocess.run([str(REC), f"{secs:g}", str(wav), self.a.device],
                           stdout=subprocess.DEVNULL, check=True, timeout=secs + 15)
        except subprocess.TimeoutExpired:
            print("  recorder timed out (the USB stream may have stopped)")
            return wav, None
        except subprocess.CalledProcessError as e:
            print(f"  recorder failed ({e.returncode}); is the device name right? --device {self.a.device!r}")
            return wav, None
        return wav, decode(wav, self.lr)

    def log(self, phase, state, take, d, wav, knob="", knob_val="", lag="", verdict=""):
        new = not self.csv.exists()
        with open(self.csv, "a", newline="") as f:
            w = csv.DictWriter(f, fieldnames=FIELDS)
            if new:
                w.writeheader()
            row = {"time": dt.datetime.now().isoformat(timespec="seconds"), "image": self.a.image,
                   "layout": self.a.layout, "phase": phase, "state": state, "take": take,
                   "knob": knob, "knob_val": knob_val, "lag": lag, "verdict": verdict,
                   "wav": wav.name}
            if d:
                row.update({k: (f"{v:.2f}" if isinstance(v, float) else v) for k, v in d.items()})
            w.writerow(row)


def ask_lag():
    while True:
        s = input("  screen lag 0-3 (Enter to skip): ").strip()
        if s in ("", "0", "1", "2", "3"):
            return s


def parse_patterns(s):
    out = []
    for item in s.split(","):
        name, pc = item.split(":")
        out.append((name.strip(), int(pc)))
    return out


# ---------------------------------------------------------------- phases

def do_check(rig):
    """One short take, stopped: proves the readout channels for this layout."""
    rig.stop()
    print(f"check: image {rig.a.image}, layout {rig.a.layout}, T8 on channels {rig.lr} (0-based)")
    wav, d = rig.take("check", secs=8)
    print("  " + summary(d))
    rig.log("check", "stopped", 1, d, wav, verdict="" if d else "no sync")
    if d and abs(d["period_us"] - PERIOD_US) > 0.02 * PERIOD_US:
        print(f"  note: period reads {d['period_us']:.1f} us, not 362.8: DTIM3 is not at 132 MHz, "
              f"scale every us figure by 362.8 / period")
    return d is not None


def do_run(rig):
    pats = parse_patterns(rig.a.patterns)
    states = [("stopped", pats[0][1], False)] + [(n, pc, True) for n, pc in pats]
    for name, pc, play in states:
        rig.stop()
        time.sleep(0.5)
        rig.pattern(pc)
        time.sleep(0.5)
        if play:
            rig.start()
        print(f"\n[{name}] {'playing' if play else 'stopped'}, pattern PC {pc}; settling {rig.a.settle:g} s")
        time.sleep(rig.a.settle)
        results = []
        for t in range(1, rig.a.takes + 1):
            wav, d = rig.take(f"{name}_t{t}")
            print(f"  take {t}: {summary(d)}")
            results.append((t, wav, d))
        lag = "" if rig.a.no_lag else ask_lag()
        for t, wav, d in results:
            rig.log("run", name, t, d, wav, lag=lag)
    rig.stop()


def do_sweep(rig, what):
    cc = CC_BURN if what == "burn" else CC_DBRN
    name, pc = parse_patterns(rig.a.patterns)[-1]           # the heaviest state
    rig.knob(cc, 0)
    rig.stop()
    time.sleep(0.5)
    rig.pattern(pc)
    time.sleep(0.5)
    rig.start()
    print(f"\nsweep {what.upper()} (CC {cc} on ch {rig.a.t8_ch}) in [{name}], playing")
    time.sleep(rig.a.settle)
    last_ok = 0
    try:
        for v in range(0, rig.a.sweep_max + 1, rig.a.sweep_step):
            rig.knob(cc, v)
            time.sleep(3)
            wav, d = rig.take(f"{what}{v}")
            why = broken(d, what)
            print(f"  {what.upper()} {v:3d}: {summary(d)}" + (f"  <<< {why}" if why else ""))
            rig.log("sweep", name, 1, d, wav, knob=what, knob_val=v, verdict=why)
            if why:
                print(f"\n  wall: between {what.upper()} {last_ok} and {v} ({why})")
                if what == "burn":
                    print(f"  headroom at {name}: ~{2 * last_ok}-{2 * v} us of frame-interrupt time")
                break
            last_ok = v
        else:
            print(f"  no break up to {what.upper()} {rig.a.sweep_max}")
    finally:
        rig.knob(cc, 0)
        time.sleep(0.2)
        rig.knob(cc, 0)
        rig.stop()
        print(f"  {what.upper()} sent back to 0. If the unit froze: power-cycle, check {what.upper()} "
              f"reads 0 on T8 FX2 before saving anything.")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["check", "run", "sweep"])
    ap.add_argument("--image", required=True, help="label for this image (e.g. 3)")
    ap.add_argument("--layout", required=True, choices=sorted(LAYOUT_LR))
    ap.add_argument("--lr", help="override T8's 0-based L,R channels in the capture")
    ap.add_argument("--device", default="Octatrack", help="CoreAudio device-name substring")
    ap.add_argument("--port", default="Octatrack", help="CoreMIDI destination name (ot_midi.py list)")
    ap.add_argument("--auto-ch", type=int, default=11, help="OT auto channel (program change)")
    ap.add_argument("--t8-ch", type=int, default=8, help="track 8's MIDI channel (BURN/DBRN CCs)")
    ap.add_argument("--patterns", default="rec0:0,rec2:1,rec4:2,rec8:3")
    ap.add_argument("--takes", type=int, default=2)
    ap.add_argument("--secs", type=float, default=12)
    ap.add_argument("--settle", type=float, default=4)
    ap.add_argument("--no-lag", action="store_true", help="skip the screen-lag prompt")
    ap.add_argument("--sweep", choices=["burn", "dbrn"], help="run: finish with this sweep")
    ap.add_argument("--what", choices=["burn", "dbrn"], default="burn", help="sweep: which knob")
    ap.add_argument("--sweep-step", type=int, default=10)
    ap.add_argument("--sweep-max", type=int, default=127)
    ap.add_argument("--out", default=str(ROOT / "out/hw/cf_stress"))
    a = ap.parse_args()

    rig = Rig(a)
    if a.cmd == "check":
        sys.exit(0 if do_check(rig) else 1)
    if a.cmd == "run":
        if not do_check(rig):
            sys.exit("readout not found; fix --layout/--lr (or the CUE routing) before a run")
        do_run(rig)
        if a.sweep:
            do_sweep(rig, a.sweep)
    else:
        do_sweep(rig, a.what)
    print(f"\nlog: {rig.csv}")


if __name__ == "__main__":
    main()
