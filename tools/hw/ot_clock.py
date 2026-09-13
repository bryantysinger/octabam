#!/usr/bin/env python3
"""Drive the Octatrack's transport over MIDI: clock + START/STOP.

    python3 tools/hw/ot_clock.py <bpm> <seconds> [port]

A bare START (0xFA) does NOTHING on a unit slaved to external sync -- it
needs clock alongside it (Sam, 13 Sep 2026: "start requires tempo, maybe you
missed that?"). This sends 0xFA, then 0xF8 at 24 ppqn on an absolute
schedule, then 0xFC. Measured 121.00 BPM against a 6 s window, error -0.00.

The unit still shows its own project tempo unless it is slaved; following the
transport does not imply following the tempo.
"""
import sys, time, pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import ot_midi                                        # noqa: E402


def run(bpm, secs, port="UM-ONE", stop_event=None):
    """START, clock at `bpm` for `secs` (or until stop_event), STOP."""
    out = ot_midi.Out(port)
    period = 60.0 / (bpm * 24.0)
    out.send([0xFA])
    t0 = time.time()
    n = 0
    while time.time() - t0 < secs:
        if stop_event is not None and stop_event.is_set():
            break
        out.send([0xF8])
        n += 1
        d = t0 + n * period - time.time()
        if d > 0:
            time.sleep(d)
    out.send([0xFC])
    return n


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    bpm, secs = float(sys.argv[1]), float(sys.argv[2])
    port = sys.argv[3] if len(sys.argv) > 3 else "UM-ONE"
    n = run(bpm, secs, port)
    print(f"START + {n} clocks at {bpm:g} BPM + STOP ({secs:g}s)")
