#!/usr/bin/env python3
"""The rig LADDER: one rung per bank, stepped over MIDI, measured after STOP.

Built 13 Sep 2026 for the evening the rig's defaults are settled on the
unit. The idea: effect selection cannot be driven over MIDI, but every
effect id and knob byte lives in the PROJECT, and a pattern selects a part.
So a ladder of configurations is a project -- the same pattern copied into
pattern 1 of banks A..H, and each bank's four parts holding one rung's
layout -- and a rung is selected by STOP, program change, START. Nobody
touches the panel between rungs.

    python3 tools/hw/ot_ladder.py proj SRC DEST REMIX [--pattern A2]
    python3 tools/hw/ot_ladder.py run LABEL [--rungs A,C,E] [--minutes 4]
                                  [--pc-channel 1] [--bpm 121] [--port UM-ONE]
                                  [--device MicroBook] [--tail 14] [--no-assert]
    python3 tools/hw/ot_ladder.py analyse LABEL        # re-run the analysis on captures
    python3 tools/hw/ot_ladder.py rungs                # print the ladder

WHAT A RUNG REPORTS, none of it a listening call:

  CRASH    no audio at all from START: the sequencer stuck on step 1 (a DSP
           hang -- FAILURE_MODES). The ladder STOPS here: only a power-cycle
           clears it.
  FREEZE   the output dies to the noise floor mid-run while the transport
           keeps running. Logged with its second; the runner then restarts
           the transport (that cleared it on 13 Sep) and continues, so an
           unattended run keeps counting events instead of ending at the
           first.
  LEVEL    rms/peak of the play phase, and the difference from rung A (the
           same material, the same clock, no effects) -- the gain-staging
           number. A station at passthrough must read 0.0 dB here.
  BANDS    the play phase's spectrum against rung A's in octave bands: a hash
           or hiss that the full rig adds shows up as a band that rose. The
           material is identical between rungs, so a band difference is the
           configuration's. (What this cannot see: a defect that is also in
           rung A.)
  TAIL     THE INSTRUMENT THE 13 SEP SESSION LACKED. After STOP the only
           thing sounding is what the effects hold: the tail's length says
           whether the bus is connected at all (every soak that day read the
           same rms wet or dry, which is how two rungs passed with the bus
           disconnected), its slope is the reverb's decay, and the spacing of
           its decaying repeats is the delay time -- with no material in it,
           so no tempo-locked peak can masquerade as one (the retracted
           "TIME is inert" reading autocorrelated the whole mix).
  TICK     the idle 2048-grid tick, from the quiet part of the tail capture.

⚠️ CONNECTIONS ARE ASSERTED OVER MIDI before every rung (page-1 CCs: FX2
slot 0 = CC 40 on the track's channel, T8's return level = FX1 slot 2 =
CC 36), from the same table the project was stamped from. A panel
re-select loads the manifest defaults and both bus knobs default to 0.

⚠️ PROGRAM CHANGE needs PROG CH RECEIVE on (PROJECT > MIDI > SYNC) and the
transport slaved (CLOCK + TRANSPORT RECEIVE). The unit takes a pattern
change at the next boundary while running, so the runner stops first
(Sam, 13 Sep 2026). A program is A01 = 0 .. H16 = 127.
"""
import argparse
import json
import pathlib
import re
import shutil
import subprocess
import sys
import threading
import time
import wave

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import ot_midi                                        # noqa: E402
import ot_project as P                                # noqa: E402

REC = HERE / "rec"
DEAD_DBFS = -80.0
BANKS = "ABCDEFGH"

# ---------------------------------------------------------------------------
# The ladder. Each rung: {track: (FX1 (key, knobs) | None, FX2 (key, knobs) | None)}
# A track not named keeps FX1 NONE and FX2 SEND with AUX 0 (a client that
# registers nothing). Knob names are the manifest's (a ModeView alias works
# too, e.g. RET); values beat the mode view's defaults, which beat the
# manifest's -- ot_project.module_defaults.
# ---------------------------------------------------------------------------
_RIG_AUX = {1: 30, 2: 40, 3: 30, 4: 40, 5: 40, 6: 50, 7: 40}   # the RIG table's sends
_RET = ("CHARACTER", {"SAT": 3, "RET": 127})
_RET_GLUE = ("CHARACTER", {"SAT": 3, "RET": 127, "CMOD": 1, "COMP": 40})


def _sends(aux, verb=False, delay=False):
    """FX2 for tracks 1..7: the engines on their hosts, SEND elsewhere."""
    out = {}
    for t in range(1, 8):
        if t == 1 and delay:
            out[t] = ("DELAY SERVER", {"AUX": aux.get(t, 0)})
        elif t == 5 and verb:
            out[t] = ("REVERB SERVER", {"AUX": aux.get(t, 0)})
        else:
            out[t] = ("SEND", {"AUX": aux.get(t, 0)})
    return out


def _rung(fx1, fx2):
    return {t: (fx1.get(t), fx2.get(t)) for t in range(1, 9)}


_STATIONS_PASS = {1: ("CHARACTER", {}), 2: ("SPECTRUM", {}), 3: ("SPECTRUM", {}),
                  4: ("SPECTRUM", {}), 5: ("MODULATION", {}), 6: ("SPECTRUM", {}),
                  7: ("SPECTRUM", {})}

RUNGS = (
    # bank, name, what it adds, layout
    ("A", "STOCK", "no effect of ours: FX1 NONE, FX2 SEND with AUX 0",
     _rung({}, _sends({}))),
    ("B", "RETURN", "+ T8 Character SAT=BUS, RET 127 (nothing to return yet)",
     _rung({8: _RET}, _sends({}))),
    ("C", "VERB", "+ BusVerb on T5, the RIG's AUX on every track",
     _rung({8: _RET}, _sends(_RIG_AUX, verb=True))),
    ("D", "DELAY", "BusDelay on T1 INSTEAD of the reverb (splits a freeze between engines)",
     _rung({8: _RET}, _sends(_RIG_AUX, delay=True))),
    ("E", "CHAIN", "+ both engines: delay on T1 -> reverb on T5 -> return on T8",
     _rung({8: _RET}, _sends(_RIG_AUX, verb=True, delay=True))),
    ("F", "STNPASS", "+ the stations on FX1 at their passthrough defaults (level must equal E)",
     _rung({**_STATIONS_PASS, 8: _RET}, _sends(_RIG_AUX, verb=True, delay=True))),
    ("G", "RIG", "the RIG table: stations + T8 GLUE comp 40 (= ot_project.RIG)",
     _rung({**_STATIONS_PASS, 8: _RET_GLUE}, _sends(_RIG_AUX, verb=True, delay=True))),
    ("H", "RIG+DLY", "the RIG with the stock DELAY on T3's FX2 (that track loses its AUX)",
     _rung({**_STATIONS_PASS, 8: _RET_GLUE},
           {**_sends(_RIG_AUX, verb=True, delay=True), 3: ("DELAY", {})})),
)


def rung_by_bank(bank):
    for r in RUNGS:
        if r[0] == bank.upper():
            return r
    sys.exit(f"no rung on bank {bank!r}")


def cmd_rungs():
    for bank, name, what, layout in RUNGS:
        print(f"bank {bank}  {name:8s} {what}")
        for t in range(1, 9):
            f1, f2 = layout[t]
            print(f"      T{t}  FX1 {f1[0] if f1 else '-':14s} {f1[1] if f1 else ''}"
                  f"   FX2 {f2[0] if f2 else '-':14s} {f2[1] if f2 else ''}")


# ---------------------------------------------------------------------------
# proj: the ladder project
# ---------------------------------------------------------------------------
def _slot_bytes(spec, remix, mods):
    if spec is None:
        return 0x00, bytes(12)
    key, knobs = spec
    if key not in remix.modules:
        sys.exit(f"the ladder names {key!r}, which remix {remix.name!r} does not place")
    m = mods[key]
    return m.menu.fx2_id, P.module_defaults(m, knobs)


def _pattern_ref(s):
    m = re.fullmatch(r"([A-Ha-h])(\d{1,2})", s)
    if not m or not 1 <= int(m.group(2)) <= 16:
        sys.exit("--pattern is like A2 (bank A, pattern 2)")
    return BANKS.index(m.group(1).upper()) + 1, int(m.group(2))


def make_ladder_project(src, dest, remix_name, pattern="A2"):
    """Copy SRC to DEST; put SRC's `pattern` (with its part) into pattern 1
    of every bank A..H, and each bank's parts (all eight records, current
    and saved) hold one rung. Checksums recomputed, everything read back."""
    src, dest = pathlib.Path(src), pathlib.Path(dest)
    if dest.exists():
        sys.exit(f"{dest} exists -- refusing to overwrite. Pick a new name.")
    if not (src / "project.work").is_file():
        sys.exit(f"{src} is not an Octatrack project directory")
    sys.path.insert(0, str(HERE.parent)); import toolpath  # noqa: E402,F401
    from remix import registry
    remix = registry.remix(remix_name)
    mods = registry.modules()

    sbank, spat = _pattern_ref(pattern)
    sdata = (src / f"bank{sbank:02d}.work").read_bytes()
    p0 = P.PTRN0 + (spat - 1) * P.PTRN_FSTRIDE
    ptrn = sdata[p0:p0 + P.PTRN_FSTRIDE]
    if ptrn[:4] != b"PTRN":
        sys.exit(f"bank{sbank:02d} pattern {spat}: no PTRN chunk at {p0:#x}")
    spart = ptrn[P.PTRN_FSTRIDE - 5]          # 0-based part the pattern plays
    if spart > 3:
        sys.exit(f"pattern {pattern} names part {spart}, not 0..3")
    part_cur = sdata[P.PART_BASE + spart * P.PART_STRIDE:][:P.PART_STRIDE]
    part_sav = sdata[P.PART_BASE + (spart + 4) * P.PART_STRIDE:][:P.PART_STRIDE]
    print(f"material: {src.name} {pattern} -> part {spart + 1}")

    plans = {}
    for bank, name, what, layout in RUNGS:
        plans[bank] = [(t, _slot_bytes(f1, remix, mods), _slot_bytes(f2, remix, mods))
                       for t, (f1, f2) in layout.items()]

    shutil.copytree(src, dest)
    lines = [f"# LADDER project for remix {remix_name!r}: pattern 1 of every bank is",
             f"# {src.name} {pattern} (part {spart + 1}); each bank's parts are one rung.",
             "# Select a rung: STOP, program change (A01=0, B01=16, ...), START.", ""]
    for bank, name, what, layout in RUNGS:
        num = BANKS.index(bank) + 1
        plan = plans[bank]

        def mut(data, plan=plan, name=name):
            # the material: pattern 1 <- the source pattern, playing part 1
            d0 = P.PTRN0
            data[d0:d0 + P.PTRN_FSTRIDE] = ptrn
            data[d0 + P.PTRN_FSTRIDE - 5] = 0
            # every part record <- the source part (machines, slots, levels,
            # amp/LFO/recorder pages), then this rung's effects on top
            for p in range(P.NPARTS_ALL):
                off = P.PART_BASE + p * P.PART_STRIDE
                data[off:off + P.PART_STRIDE] = part_cur if p < 4 else part_sav
                for t, (id1, v1), (id2, v2) in plan:
                    i = t - 1
                    data[off + P.FX1_OFF + i] = id1
                    data[off + P.FX2_OFF + i] = id2
                    a = off + P.P1_OFF + i * P.TRACK_STRIDE
                    b = off + P.P2_OFF + i * P.P2_STRIDE
                    data[a:a + 6] = v1[:6]; data[a + 6:a + 12] = v2[:6]
                    data[b:b + 6] = v1[6:]; data[b + 6:b + 12] = v2[6:]
            # part names: the rung, on all four
            for p in range(4):
                o = len(data) - 2 - 4 * 7 + p * 7
                field = name.encode("latin1")[:6]
                data[o:o + 7] = field + b"\x00" * (7 - len(field))

        P._bank_write(dest, num, mut, guard=False)
        # READ BACK
        data = (dest / f"bank{num:02d}.work").read_bytes()
        if int.from_bytes(data[-2:], "big") != (sum(data[0x10:-2]) & 0xFFFF):
            sys.exit(f"bank{num:02d}: checksum did not take -- do NOT use this")
        if data[P.PTRN0:P.PTRN0 + P.PTRN_FSTRIDE - 5] != ptrn[:-5]:
            sys.exit(f"bank{num:02d}: pattern 1 read-back disagrees")
        for p in range(P.NPARTS_ALL):
            off = P.PART_BASE + p * P.PART_STRIDE
            for t, (id1, v1), (id2, v2) in plan:
                i = t - 1
                a = off + P.P1_OFF + i * P.TRACK_STRIDE
                b = off + P.P2_OFF + i * P.P2_STRIDE
                got = (data[off + P.FX1_OFF + i], data[off + P.FX2_OFF + i],
                       bytes(data[a:a + 12]), bytes(data[b:b + 12]))
                if got != (id1, id2, v1[:6] + v2[:6], v1[6:] + v2[6:]):
                    sys.exit(f"bank{num:02d} part {p + 1} T{t}: read-back disagrees")
        lines.append(f"bank {bank}  program {num * 16 - 16:3d}  {name:8s} {what}")
        for t, (f1, f2) in layout.items():
            lines.append(f"    T{t}  FX1 {f1[0] if f1 else '-':14s} {f1[1] if f1 else ''}"
                         f"   FX2 {f2[0] if f2 else '-':14s} {f2[1] if f2 else ''}")
        lines.append("")
    (dest / "OCTABAM_LADDER_MAP.txt").write_text("\n".join(lines) + "\n")
    print(f"8 banks written and verified -> {dest}")
    print(f"map at {dest / 'OCTABAM_LADDER_MAP.txt'}")


# ---------------------------------------------------------------------------
# run: the transport, the connections, the captures
# ---------------------------------------------------------------------------
class Clock:
    """Continuous MIDI clock; START/STOP on demand. A bare START does nothing
    on a slaved unit without clock beside it (ot_clock.py)."""

    def __init__(self, bpm, port):
        self.out = ot_midi.Out(port)
        self.period = 60.0 / (bpm * 24.0)
        self._stop = threading.Event()
        self.th = threading.Thread(target=self._run, daemon=True)
        self.th.start()

    def _run(self):
        t0 = time.time(); n = 0
        while not self._stop.is_set():
            n += 1
            dt = t0 + n * self.period - time.time()
            if dt > 0:
                time.sleep(dt)
            self.out.send([0xF8])

    def start(self):
        self.out.send([0xFA])

    def stop(self):
        self.out.send([0xFC])

    def cc(self, ch, cc, val):
        self.out.send([0xB0 | (ch - 1), cc & 0x7f, val & 0x7f])

    def pc(self, ch, prog):
        self.out.send([0xC0 | (ch - 1), prog & 0x7f])

    def close(self):
        self._stop.set(); self.th.join(timeout=1)


def db(x):
    import numpy as np
    return float(20.0 * np.log10(max(float(x), 1e-12)))


def read_wav(path):
    import numpy as np
    w = wave.open(str(path))
    n, ch, sr = w.getnframes(), w.getnchannels(), w.getframerate()
    a = np.frombuffer(w.readframes(n), dtype="<i4").reshape(-1, ch)
    w.close()
    return a.astype(np.float64) / 2**31, sr


def capture(secs, path, device):
    """Blocking capture; returns (samples[:, ch], sr)."""
    subprocess.run([str(REC), f"{secs:.0f}", str(path), device],
                   stdout=subprocess.DEVNULL, check=True)
    return read_wav(path)


def capture_with_stop(secs, path, device, clock, stop_at):
    """Start a capture, send STOP `stop_at` seconds after the recorder says it
    is live, and return the sample index the STOP was sent at (nominal)."""
    p = subprocess.Popen([str(REC), f"{secs:.0f}", str(path), device],
                         stdout=subprocess.PIPE, text=True)
    t_live = None
    for line in p.stdout:
        if line.startswith("START"):
            t_live = time.time()
            break
    if t_live is None:
        p.wait(); sys.exit("recorder never reported START")
    time.sleep(stop_at)
    t_stop = time.time()
    clock.stop()
    p.wait()
    return t_stop - t_live


def write_excerpt(x, sr, path):
    import numpy as np
    w = wave.open(str(path), "wb")
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(sr)
    w.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())
    w.close()


def assert_connections(clock, layout, verbose=True):
    """Every knob the rung relies on, over page-1 CCs (FX2 slot k = CC 40+k,
    FX1 slot k = CC 34+k, on the track's channel). Page 2 cannot be driven
    (FAILURE_MODES: CC PAGE 2 does not write on hardware)."""
    sys.path.insert(0, str(HERE.parent)); import toolpath  # noqa: E402,F401
    from remix import registry
    mods = registry.modules()
    sent = []
    for t, (f1, f2) in layout.items():
        for base, spec in ((34, f1), (40, f2)):
            if spec is None:
                continue
            key, knobs = spec
            m = mods[key]
            kmap = m.knob_map_all()
            for name, val in knobs.items():
                slot = kmap[name] if isinstance(name, str) else name
                if slot >= 6:
                    continue                  # page 2: not reachable over MIDI
                clock.cc(t, base + slot, val)
                sent.append(f"T{t} CC{base + slot}={val}")
                time.sleep(0.02)
    if verbose and sent:
        print("  asserted: " + " ".join(sent))


# ---------------------------------------------------------------------------
# analysis
# ---------------------------------------------------------------------------
def env_db(x, sr, win_s=0.5):
    import numpy as np
    win = int(win_s * sr)
    return np.array([db(np.sqrt(np.mean(x[i:i + win]**2)))
                     for i in range(0, len(x) - win + 1, win)])


def octave_bands(x, sr):
    """Mean power (dB) per octave band 62 Hz .. 16 kHz, Welch 8192."""
    import numpy as np
    n = 8192
    win = np.hanning(n)
    acc = np.zeros(n // 2 + 1); k = 0
    for i in range(0, len(x) - n, n // 2):
        acc += np.abs(np.fft.rfft(x[i:i + n] * win))**2; k += 1
    if k == 0:
        return {}
    psd = acc / k / (np.sum(win**2) * n / 2)
    f = np.fft.rfftfreq(n, 1 / sr)
    out = {}
    for lo in (62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000):
        hi = min(lo * 2, sr / 2)
        sel = (f >= lo) & (f < hi)
        out[str(lo)] = db(np.sqrt(psd[sel].mean())) if sel.any() else None
    return out


def analyse_play(x, sr):
    import numpy as np
    lv = env_db(x, sr)
    alive = lv > DEAD_DBFS
    res = dict(rms=db(np.sqrt(np.mean(x**2))), peak=db(np.abs(x).max()),
               alive_pct=float(100 * alive.mean()), freeze_at=None, dropouts=0,
               silent=not alive.any())
    if alive.any() and not alive.all():
        falls = np.flatnonzero(np.diff(alive.astype(int)) == -1)
        froze = next((f for f in falls if not alive[f + 1:].any()), None)
        res["freeze_at"] = None if froze is None else float(froze * 0.5)
        res["dropouts"] = int(len(falls))
    res["bands"] = octave_bands(x, sr)
    return res


def analyse_tail(x, sr, stop_nominal):
    """The tail after STOP. Locates the stop as the last 10 ms frame within
    +-1.5 s of the nominal STOP that sits above the pre-stop level - 6 dB,
    then: length to the floor, decay slope over the first 40 dB, and the
    repeat spacing (autocorrelation of the linear envelope, 60 ms .. 1.5 s).
    Also the tick scan on the quiet part."""
    import numpy as np
    win = int(0.010 * sr)
    e = np.array([np.sqrt(np.mean(x[i:i + win]**2)) for i in range(0, len(x) - win + 1, win)])
    edb = 20 * np.log10(np.maximum(e, 1e-12))
    t = np.arange(len(e)) * 0.010
    pre = edb[(t > max(0, stop_nominal - 3.0)) & (t < stop_nominal - 0.2)]
    if len(pre) == 0:
        return dict(error="no pre-stop region")
    pre_lv = float(np.percentile(pre, 90))
    floor = float(np.percentile(edb[t > stop_nominal + 0.5], 5))
    floor = max(floor, -105.0)
    # the last loud frame near the nominal stop
    zone = np.flatnonzero((t > stop_nominal - 1.5) & (t < stop_nominal + 1.5) & (edb > pre_lv - 6))
    if len(zone) == 0:
        return dict(error="no loud frame near the STOP", pre_level=pre_lv, floor=floor)
    k0 = int(zone[-1]) + 1
    tail = edb[k0:]
    tt = t[k0:] - t[k0]
    thr = floor + 6.0
    below = np.flatnonzero(tail < thr)
    # first frame after which it stays under the threshold for 0.3 s
    t_len = None
    for b in below:
        if (tail[b:b + 30] < thr).all():
            t_len = float(tt[b]); break
    res = dict(pre_level=pre_lv, floor=floor, tail_s=t_len)
    # decay slope over the first 40 dB (or to the floor)
    top = tail[0]
    seg = np.flatnonzero((tail < top) & (tail > max(top - 40, thr)))
    if len(seg) > 10:
        seg = seg[seg < (t_len / 0.010 if t_len else len(tail))]
        if len(seg) > 10:
            A, B = np.polyfit(tt[seg], tail[seg], 1)
            res["decay_db_per_s"] = float(A)
            res["t60_s"] = float(-60.0 / A) if A < 0 else None
    # repeats: autocorrelation of the linear envelope of the tail
    lin = e[k0:k0 + int(min(len(e) - k0, 8.0 / 0.010))]
    lin = lin - lin.mean()
    if len(lin) > 200 and lin.std() > 0:
        ac = np.correlate(lin, lin, "full")[len(lin) - 1:]
        ac /= ac[0]
        lo, hi = 6, min(150, len(ac) - 1)          # 60 ms .. 1.5 s
        if hi > lo + 5:
            seg = ac[lo:hi]
            k = int(np.argmax(seg)) + lo
            # a peak that is a local maximum and stands out
            if 0 < k < len(ac) - 1 and ac[k] > ac[k - 1] and ac[k] > ac[k + 1] and ac[k] > 0.25:
                y0, y1, y2 = ac[k - 1], ac[k], ac[k + 1]
                frac = 0.5 * (y0 - y2) / (y0 - 2 * y1 + y2) if (y0 - 2 * y1 + y2) != 0 else 0.0
                res["repeat_ms"] = float((k + frac) * 10.0); res["repeat_corr"] = float(ac[k])
    # ticks in the quiet part
    quiet_from = k0 * win + int((t_len or 0) * sr) + int(0.5 * sr)
    q = x[quiet_from:]
    if len(q) > sr * 3:
        sys.path.insert(0, str(HERE)); import ot_soak
        ev, grid = ot_soak.tick_scan(q, sr)
        res["ticks"] = int(len(ev)); res["tick_grid"] = None if not grid else float(grid[0])
        res["idle_floor"] = db(np.sqrt(np.mean(q**2)))
    return res


# ---------------------------------------------------------------------------
# the run
# ---------------------------------------------------------------------------
def fmt_row(bank, name, play, tail, ref):
    d_rms = "" if ref is None else f"{play['rms'] - ref['rms']:+.1f}"
    hf = ""
    if ref is not None and play.get("bands") and ref.get("bands"):
        deltas = [(k, play["bands"][k] - ref["bands"][k]) for k in play["bands"]
                  if play["bands"][k] is not None and ref["bands"][k] is not None]
        hot = [f"{k}:{d:+.1f}" for k, d in deltas if abs(d) >= 1.5]
        hf = " ".join(hot) if hot else "flat"
    status = ("CRASH" if play["silent"] else
              f"FREEZE@{play['freeze_at']:.0f}s" if play["freeze_at"] is not None else
              f"{play['dropouts']} drops" if play["dropouts"] else "ok")
    tl = tail or {}
    return (f"| {bank} {name:8s} | {status:12s} | {play['rms']:6.1f} | {play['peak']:6.1f} | {d_rms:5s} "
            f"| {hf:24s} | {('%.2f' % tl['tail_s']) if tl.get('tail_s') is not None else '-':>6s} "
            f"| {('%.1f' % tl['t60_s']) if tl.get('t60_s') else '-':>6s} "
            f"| {('%.0f' % tl['repeat_ms']) if tl.get('repeat_ms') else '-':>6s} "
            f"| {tl.get('ticks', '-')} |")


HEADER = ("| rung | status | rms | peak | d rms | bands vs A | tail s | T60 s | rpt ms | ticks |\n"
          "|---|---|---|---|---|---|---|---|---|---|")


def run(args):
    if not REC.is_file():
        sys.exit(f"compile the recorder: swiftc -O tools/hw/rec.swift -o {REC}")
    out = ROOT / "out/hw/ladder" / args.label
    out.mkdir(parents=True, exist_ok=True)
    rungs = [rung_by_bank(b) for b in args.rungs.split(",")] if args.rungs else list(RUNGS)
    results = json.loads((out / "results.json").read_text()) if (out / "results.json").is_file() else {}
    clock = Clock(args.bpm, args.port)
    report = out / "REPORT.md"
    if not report.is_file():
        report.write_text(f"# ladder {args.label}  ({args.minutes:g} min/rung @ {args.bpm:g} BPM)\n\n"
                          + HEADER + "\n")
    try:
        for bank, name, what, layout in rungs:
            prog = (BANKS.index(bank)) * 16
            print(f"\n== rung {bank} {name}: {what}")
            clock.stop(); time.sleep(1.0)
            clock.pc(args.pc_channel, prog); time.sleep(1.5)
            if not args.no_assert:
                assert_connections(clock, layout)
            clock.start()
            t0 = time.time()
            chunks = []
            freezes = []
            secs_total = args.minutes * 60
            n_chunks = max(1, int(round(secs_total / args.chunk)))
            crashed = False
            for c in range(n_chunks):
                path = out / f"{bank}_{name}_play{c:02d}.wav"
                x, sr = capture(args.chunk, path, args.device)
                L = x[:, 2]
                chunks.append(L)
                a = analyse_play(L, sr)
                if a["silent"]:
                    print(f"  chunk {c}: SILENT -- no audio at all")
                    if c == 0:
                        crashed = True
                        break
                    # a freeze that began in an earlier chunk's last frame
                    freezes.append(time.time() - t0 - args.chunk)
                    print("  >>> transport restart"); clock.stop(); time.sleep(1.0); clock.start()
                elif a["freeze_at"] is not None:
                    at = time.time() - t0 - args.chunk + a["freeze_at"]
                    freezes.append(at)
                    print(f"  chunk {c}: FREEZE at t={at:.0f}s  >>> transport restart")
                    clock.stop(); time.sleep(1.0); clock.start()
                else:
                    print(f"  chunk {c}: rms {a['rms']:.1f} peak {a['peak']:.1f} "
                          + ("ok" if not a["dropouts"] else f"{a['dropouts']} dropouts"))
            import numpy as np
            play_all = np.concatenate(chunks)
            play = analyse_play(play_all, sr)
            play["freezes"] = freezes
            if freezes and play["freeze_at"] is None:
                play["freeze_at"] = freezes[0]
            # excerpt for the ear: 20..28 s of the first chunk, stereo
            x0, _ = read_wav(out / f"{bank}_{name}_play00.wav")
            if len(x0) > 28 * sr:
                write_excerpt(x0[20 * sr:28 * sr, 2:4], sr, out / f"{bank}_{name}_excerpt.wav")
            solos = None
            if args.solo and not crashed:
                # per-track level with the rung's effects: solo each track in
                # turn (CC 50 on its channel), 8 s each. Soloing T8 leaves the
                # return alone: the bus wet on its own (only that track's send).
                solos = {}
                for t in range(1, 9):
                    clock.cc(t, 50, 127); time.sleep(0.5)
                    xs, sr = capture(8, out / f"{bank}_{name}_solo{t}.wav", args.device)
                    a = analyse_play(xs[2 * sr:, 2], sr)
                    solos[t] = dict(rms=a["rms"], peak=a["peak"])
                    clock.cc(t, 50, 0); time.sleep(0.3)
                print("  solos rms: " + " ".join(f"T{t}={v['rms']:.1f}" for t, v in solos.items()))
            tail = None
            if not crashed:
                tpath = out / f"{bank}_{name}_tail.wav"
                stop_nominal = capture_with_stop(args.tail, tpath, args.device, clock, 3.0)
                xt, sr = read_wav(tpath)
                tail = analyse_tail(xt[:, 2], sr, stop_nominal)
                tail["stop_nominal"] = stop_nominal
            else:
                clock.stop()
            results[bank] = dict(name=name, what=what, play=play, tail=tail, solos=solos,
                                 minutes=args.minutes, when=time.strftime("%H:%M:%S"))
            (out / "results.json").write_text(json.dumps(results, indent=1))
            ref = results.get("A", {}).get("play") if bank != "A" else None
            row = fmt_row(bank, name, play, tail, ref)
            print(row)
            with report.open("a") as f:
                f.write(row + "\n")
            if crashed:
                print("\n*** CRASH: no audio from START. The DSP is hung; the ladder stops here. "
                      "Power-cycle the unit.")
                break
    finally:
        clock.stop()
        clock.close()
    print(f"\nreport: {report}")


def reanalyse(args):
    import numpy as np
    out = ROOT / "out/hw/ladder" / args.label
    results = json.loads((out / "results.json").read_text())
    rows = [HEADER]
    for bank, name, what, layout in RUNGS:
        r = results.get(bank)
        if r is None:
            continue
        chunks = sorted(out.glob(f"{bank}_{name}_play*.wav"))
        xs = [read_wav(p)[0][:, 2] for p in chunks]
        sr = read_wav(chunks[0])[1]
        play = analyse_play(np.concatenate(xs), sr)
        play["freezes"] = r["play"].get("freezes", [])
        tail = None
        tp = out / f"{bank}_{name}_tail.wav"
        if tp.is_file() and r.get("tail"):
            xt, sr = read_wav(tp)
            tail = analyse_tail(xt[:, 2], sr, r["tail"]["stop_nominal"])
            tail["stop_nominal"] = r["tail"]["stop_nominal"]
        r["play"], r["tail"] = play, tail
        rows.append(fmt_row(bank, name, play, tail, results.get("A", {}).get("play") if bank != "A" else None))
    (out / "results.json").write_text(json.dumps(results, indent=1))
    print("\n".join(rows))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("proj"); p.add_argument("src"); p.add_argument("dest"); p.add_argument("remix")
    p.add_argument("--pattern", default="A2")
    p = sub.add_parser("run"); p.add_argument("label")
    p.add_argument("--rungs", default=None, help="comma list of banks, default all")
    p.add_argument("--minutes", type=float, default=4.0)
    p.add_argument("--chunk", type=float, default=60.0, help="capture chunk seconds")
    p.add_argument("--tail", type=float, default=14.0, help="tail capture seconds (STOP at 3 s)")
    p.add_argument("--pc-channel", type=int, default=1)
    p.add_argument("--bpm", type=float, default=121.0)
    p.add_argument("--port", default="UM-ONE")
    p.add_argument("--device", default="MicroBook")
    p.add_argument("--no-assert", action="store_true")
    p.add_argument("--solo", action="store_true", help="after the play phase, solo each track for 8 s")
    p = sub.add_parser("analyse"); p.add_argument("label")
    sub.add_parser("rungs")
    args = ap.parse_args()
    if args.cmd == "proj":
        make_ladder_project(args.src, args.dest, args.remix, args.pattern)
    elif args.cmd == "run":
        run(args)
    elif args.cmd == "analyse":
        reanalyse(args)
    elif args.cmd == "rungs":
        cmd_rungs()


if __name__ == "__main__":
    main()
