#!/usr/bin/env python3
"""Drive the Octatrack's transport over MIDI: clock + START/STOP.

    python3 tools/hw/ot_clock.py <bpm> <seconds> [port]

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
