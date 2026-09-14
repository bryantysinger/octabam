#!/usr/bin/env python3
"""Soak one rig configuration on the unit and report what broke.

    python3 tools/hw/ot_soak.py <label> <minutes> [--bpm 121] [--idle 30]
                               [--device MicroBook] [--port UM-ONE]

Three answers per run, none of them a listening call:

  FREEZE   the audio engine wedges: output goes to the noise floor and never
           comes back while the transport still runs. Reported with the
           second it happened at. Distinguished from a recovered dropout.
  TICK     the idle 2048-sample tick (FAILURE_MODES). Only detectable with
           the transport STOPPED -- under material every note attack trips a
           first-difference threshold -- so the soak plays, then stops and
           measures a quiet tail.
  LEVEL    rms/peak, to catch a rung whose audio never started."""
import argparse, pathlib, subprocess, sys, threading, time, wave

import numpy as np

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import ot_clock                                        # noqa: E402

REC = ROOT / "tools/hw/rec"
DEAD_DBFS = -80.0        # below this a 0.5 s frame counts as no audio
TICK_DX = 3e-3           # first-difference threshold for a tick


def db(x):
    return 20.0 * np.log10(max(float(x), 1e-12))


def capture(secs, path, device):
    subprocess.run([str(REC), f"{secs:.0f}", str(path), device],
                   stdout=subprocess.DEVNULL, check=True)
    w = wave.open(str(path))
    n, ch, sr = w.getnframes(), w.getnchannels(), w.getframerate()
    a = np.frombuffer(w.readframes(n), dtype="<i4").reshape(-1, ch)
    return a.astype(np.float64) / 2**31, sr


def tick_scan(x, sr):
    """Events, and the 2048-sample grid fit if they lock to one."""
    dx = np.abs(np.diff(x))
    ev = []
    for k in np.flatnonzero(dx > TICK_DX):
        if ev and k - ev[-1] < 200:
            continue
        ev.append(int(k + np.argmax(dx[k:k + 5])))
    ev = np.array(ev)
    if len(ev) < 4:
        return ev, None
    q = np.round((ev - ev[0]) / 2048.0)
    if len(set(q)) != len(q):
        return ev, None
    A, B = np.polyfit(q, ev, 1)
    r = float(np.std(ev - (A * q + B)))
    return ev, ((A, r) if r < 3 else None)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("label")
    ap.add_argument("minutes", type=float)
    ap.add_argument("--bpm", type=float, default=121.0)
    ap.add_argument("--idle", type=float, default=30.0, help="0 to skip the tick tail")
    ap.add_argument("--device", default="MicroBook")
    ap.add_argument("--port", default="UM-ONE")
    args = ap.parse_args()
    if not REC.is_file():
        sys.exit(f"compile the recorder: swiftc -O tools/hw/rec.swift -o {REC}")

    out = ROOT / "out/hw"
    out.mkdir(parents=True, exist_ok=True)
    secs = args.minutes * 60
    stop = threading.Event()
    th = threading.Thread(target=ot_clock.run,
                          args=(args.bpm, secs + 30, args.port, stop), daemon=True)
    th.start()
    time.sleep(1.0)
    L, sr = capture(secs, out / f"soak_{args.label}.wav", args.device)
    stop.set(); th.join(timeout=2)
    x = L[:, 2]

    print(f"== soak {args.label!r}  {args.minutes:g} min @ {args.bpm:g} BPM ==")
    print(f"  rms {db(np.sqrt(np.mean(x**2))):.1f} dBFS   peak {db(np.abs(x).max()):.1f}")
    win = int(0.5 * sr)
    lv = np.array([db(np.sqrt(np.mean(x[i:i + win]**2)))
                   for i in range(0, len(x) - win, win)])
    alive = lv > DEAD_DBFS
    print(f"  alive: {100 * alive.mean():.0f}% of 0.5 s frames")
    if not alive.any():
        print("  *** SILENT THROUGHOUT -- this configuration made no audio at all")
    elif alive.all():
        print("  no dropouts")
    else:
        falls = np.flatnonzero(np.diff(alive.astype(int)) == -1)
        froze = next((f for f in falls if not alive[f + 1:].any()), None)
        if froze is not None:
            print(f"  *** WENT SILENT at t={froze * 0.5:.1f}s AND NEVER RECOVERED  <<< FREEZE")
        else:
            print(f"  {len(falls)} dropouts, all recovered")

    if args.idle > 0:
        ot_midi_stop = ot_clock.ot_midi.Out(args.port)
        ot_midi_stop.send([0xFC])
        time.sleep(1.5)
        I, sr2 = capture(args.idle, out / f"soak_{args.label}_idle.wav", args.device)
        i = I[:, 2]
        ev, grid = tick_scan(i, sr2)
        msg = (f"  IDLE {args.idle:g}s: floor {db(np.sqrt(np.mean(i**2))):.1f} dBFS  "
               f"ticks {len(ev)}")
        if grid:
            msg += f"   *** 2048-GRID LOCK {grid[0]:.3f} res {grid[1]:.2f}  <<< THE TICK"
        print(msg)


if __name__ == "__main__":
    main()
