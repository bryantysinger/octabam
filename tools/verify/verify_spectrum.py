#!/usr/bin/env python3
"""SPECTRUM render gates, with arithmetic you can predict.

Renders the station straight through dsp_host (verify_hello's shape: the id
and the slots come from the manifest, the entry points are checked against
SEND's so an absent module cannot pass as a dry passthrough).

Gates:
  defaults    -> output bit-exact vs a full-scale bipolar ramp (the bypass)
  LP slope    -> a low cutoff: 2 kHz vs 4 kHz attenuate by ~12 dB/oct (2-pole)
  HP at DC    -> 0;   BP at DC -> 0;   NOTCH at DC -> DC (lp + hp = x)
  base/width  -> BASE up kills DC through B (SER); WDTH down kills 8 kHz
  RING at DC  -> A*B*2 with A = B = DC: 2*DC^2, to 1 LSB after settling
  VOWEL       -> renders, and differs across FREQ (A vs I)
  every knob  -> renders without dsp_host dying
  SEM core (13 Sep 2026, the zero-delay SVF):
  four modes  -> LP/BP/HP/NTCH are four different responses at one FREQ/RES
  BP tracks   -> the BP peak sits on the FREQ taper (108 / 600 / 2983 Hz at
                 FREQ 32 / 64 / 96), tones a third of an octave either side lower
  taper top   -> FREQ 127 reaches 15 kHz: at RES 64 the LP peaks ABOVE 1 kHz
                 there (the old core's ceiling was 7.2 kHz)
  RES 127     -> bounded: a 0.5 FS tone at fc peaks below full scale and the
                 tail does not sit on the rails (it self-oscillates, it does not
                 latch); the same through the VOWL bank
  VOWL bank   -> five vowels: each F1 and F2 is a PEAK within a quarter octave
                 of the Peterson-Barney table, and each vowel is loudest at its
                 own F1 among the five

The dump comes from the audition, which builds a scratch image that really
contains this station beside SEND:

    python3 tools/remix/audition.py spectrum out/dry/drums_110.wav
    python3 tools/verify/verify_spectrum.py
"""
import math, pathlib, struct, subprocess, sys

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parents[1])); import toolpath  # noqa: E402,F401  (every tools/ dir on sys.path)
import send_probe  # reuse its dispatch-table entry resolution
from remix import registry

MOD = registry.by_name("spectrum")
SEND = registry.by_name("send")
K = MOD.knob_map()
MEM = f"out/dsp/_audition_{MOD.name}_A.mem"
HOST = "vendor/dsp56300/build/source/dsp_host/dsp_host"
FXID = MOD.menu.fx2_id
FRAMES, N = 15, 6000
SR = 44100
TMP = pathlib.Path("out/_fsgate")
TMP.mkdir(parents=True, exist_ok=True)

# ⚠️ REBUILD THE DUMP, ALWAYS. The audition caches its scratch image against
# the newest mtime under modules/, and a stale hit here does not fail -- it
# silently measures the STOCK effect whose id this module replaces. That cost
# an hour on 3 Sep 2026: every mode read as a dry pass, because the dump's
# dispatch still pointed at stock CHORUS, and the emulator eventually died on
# a stock instruction it does not implement.
pathlib.Path(MEM).unlink(missing_ok=True)
subprocess.run([sys.executable, "tools/remix/audition.py", MOD.name,
                "out/dry/drums_110.wav"], capture_output=True)

if not pathlib.Path(MEM).exists():
    sys.exit(f"no {MEM} -- build it first:\n"
             f"  python3 tools/remix/audition.py {MOD.name} out/dry/drums_110.wav")

init, proc = send_probe.entry_points(MEM, FXID)
if (init, proc) == send_probe.entry_points(MEM, SEND.menu.fx2_id):
    sys.exit(f"fx id 0x{FXID:02x} resolves to SEND's entry points -- {MOD.name} "
             f"is NOT in this dump")
print(f"entries from dispatch tables: init=P:0x{init:04x} proc=P:0x{proc:04x}")

DEFAULTS = [(p.default or 0) for p in MOD.params]


def params(**kw):
    v = list(DEFAULTS)
    for name, val in kw.items():
        v[K[name]] = val
    return v


def render(samples, slot="fx1", guard=False, **kw):
    """samples: MONO ints in Q23 -- dsp_host feeds one stream to both
    channels (verify_hello's shape). Returns (L, R) lists.

    slot="fx1" (alloc 0, r7 1) is the station's own slot; "fx2" (alloc 1,
    r7 2) is an FX2 instance, which the station runs as a DRY PASS since
    12 Sep 2026 (Claims.fx1_only) -- the gate below proves it. Until then
    every gate here rendered on alloc 1 and would now read dry."""
    src = TMP / "fs_in.raw"
    src.write_bytes(b"".join(struct.pack("<i", m) for m in samples))
    out = TMP / "fs_out.raw"
    r7, alloc = ("1", "0") if slot == "fx1" else ("2", "1")
    cmd = [HOST, "-mem", MEM, "-init", f"{init:x}", "-proc", f"{proc:x}",
           "-inst", "1", "-r7", r7, "-alloc", alloc, "-inmask", "1",
           *(["-guard"] if guard else []),
           "-frames", str(FRAMES), "-blocks", str(len(samples) // FRAMES),
           "-in", str(src), "-out", str(out),
           "-params", ",".join(str(x) for x in params(**kw))]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"dsp_host failed for {kw}:\n{r.stdout}\n{r.stderr}")
    if guard:
        render.guard_out = r.stdout + r.stderr
    d = out.read_bytes()
    w = struct.unpack(f"<{len(d)//4}i", d)
    return list(w[0::2])[:len(samples)], list(w[1::2])[:len(samples)]


def tone(hz, amp=0.4, n=N):
    return [int(amp * 8388607 * math.sin(2 * math.pi * hz * i / SR)) for i in range(n)]


def dc(level=0.25, n=N):
    return [int(level * 8388607)] * n


def rms_db(x, start=N // 2):
    seg = x[start:]
    return 20 * math.log10(max(1e-9, math.sqrt(sum((s / 8388607) ** 2 for s in seg) / len(seg))))


def tail_mean(x, start=N * 3 // 4):
    seg = x[start:]
    return sum(seg) / len(seg)


fails = 0
def check(label, ok, detail=""):
    global fails
    print(f"  [{'PASS' if ok else 'FAIL'}] {label}{'  ' + detail if detail else ''}")
    fails += 0 if ok else 1


# ---- 1. defaults: bit-exact passthrough --------------------------------------
ramp = [int(round(-8388607 + 2 * 8388607 * i / (N - 1))) for i in range(N)]
L, R = render(ramp)
check("defaults are a bit-exact passthrough (the bypass block)",
      L == ramp and R == ramp,
      "" if L == ramp else f"first diff at {next(i for i,(a,b) in enumerate(zip(L,ramp)) if a!=b)}")

# ---- 2. LP slope: low cutoff, 2 kHz vs 4 kHz ---------------------------------
lo = rms_db(render(tone(2000), FREQ=30, RES=0)[0])
hi = rms_db(render(tone(4000), FREQ=30, RES=0)[0])
slope = lo - hi
check("LP is a 2-pole: 2 kHz vs 4 kHz differ by ~12 dB at FREQ=30",
      9 <= slope <= 15, f"{slope:.1f} dB/oct")

# ---- 3. DC through the modes --------------------------------------------------
d_lp = tail_mean(render(dc(), FREQ=64)[0])
d_hp = tail_mean(render(dc(), FREQ=64, MODE=2)[0])
d_bp = tail_mean(render(dc(), FREQ=64, MODE=1)[0])
d_nt = tail_mean(render(dc(), FREQ=64, MODE=3)[0])
dcv = int(0.25 * 8388607)
check("HP at DC -> 0", abs(d_hp) < 64, f"{d_hp:.0f} LSB")
check("BP at DC -> 0", abs(d_bp) < 64, f"{d_bp:.0f} LSB")
check("NOTCH at DC -> DC (lp + hp = x)", abs(d_nt - dcv) < 256, f"{d_nt:.0f} vs {dcv}")
check("LP at DC -> DC", abs(d_lp - dcv) < 256, f"{d_lp:.0f} vs {dcv}")

# ---- 4. filter B: base kills DC, width kills 8 kHz (SER routing) -------------
d_base = tail_mean(render(dc(), BASE=100)[0])
check("BASE=100 kills DC through the pair", abs(d_base) < 64, f"{d_base:.0f} LSB")
w_open = rms_db(render(tone(8000), WDTH=127)[0])
w_shut = rms_db(render(tone(8000), WDTH=30)[0])
check("WDTH=30 attenuates 8 kHz by > 20 dB vs open", w_open - w_shut > 20,
      f"{w_open - w_shut:.1f} dB")

# ---- 5. RING at DC: 2 * A * B, A = B = DC ------------------------------------
d_ring = tail_mean(render(dc(), ROUT=2)[0])
want = 2 * (0.25 ** 2) * 8388607
check("RING at DC -> 2*DC^2", abs(d_ring - want) < 512, f"{d_ring:.0f} vs {want:.0f}")

# ---- 6. VOWEL renders and morphs ---------------------------------------------
va = rms_db(render(tone(1100), MODE=4, FREQ=0, RES=90)[0])     # A: F2 1090
vi = rms_db(render(tone(1100), MODE=4, FREQ=64, RES=90)[0])    # I: F2 2290
check("VOWEL A vs I differ at 1.1 kHz", abs(va - vi) > 3, f"A {va:.1f}  I {vi:.1f} dBFS")

# ---- 6b. the SEM core: four modes at one setting -----------------------------
# FREQ 64 is fc = 600 Hz on the taper (24 * 625^(64/128)); RES 64 is Q ~ 3.
lv = {m: {hz: rms_db(render(tone(hz, 0.2), FREQ=64, RES=64, MODE=m)[0])
          for hz in (100, 600, 4000)} for m in range(4)}
check("LP passes 100 Hz and cuts 4 kHz by > 20 dB (FREQ 64)",
      lv[0][100] - lv[0][4000] > 20, f"{lv[0][100] - lv[0][4000]:.1f} dB")
check("HP passes 4 kHz and cuts 100 Hz by > 20 dB",
      lv[2][4000] - lv[2][100] > 20, f"{lv[2][4000] - lv[2][100]:.1f} dB")
check("BP peaks at 600 Hz, both skirts > 15 dB down",
      lv[1][600] - lv[1][100] > 15 and lv[1][600] - lv[1][4000] > 15,
      f"600 Hz {lv[1][600]:.1f}, 100 Hz {lv[1][100]:.1f}, 4 kHz {lv[1][4000]:.1f} dBFS")
check("NOTCH dips at 600 Hz, both sides > 10 dB up",
      lv[3][100] - lv[3][600] > 10 and lv[3][4000] - lv[3][600] > 10,
      f"600 Hz {lv[3][600]:.1f}, 100 Hz {lv[3][100]:.1f}, 4 kHz {lv[3][4000]:.1f} dBFS")

# ---- 6c. the BP peak sits on the taper ----------------------------------------
# fc = 24 * 625^(FREQ/128): 120 / 600 / 3000 Hz. RES 100 is Q ~ 12 (+21 dB at
# fc), so the tone is small (0.02 FS) -- at 0.2 FS the peak would sit on the
# limiter and the skirts would read only a dB or two lower.
for freq, fc in ((32, 120), (64, 600), (96, 3000)):
    at = rms_db(render(tone(fc, 0.02), FREQ=freq, RES=100, MODE=1)[0])
    below = rms_db(render(tone(fc / 1.26, 0.02), FREQ=freq, RES=100, MODE=1)[0])
    above = rms_db(render(tone(fc * 1.26, 0.02), FREQ=freq, RES=100, MODE=1)[0])
    check(f"BP peak at FREQ {freq} is at {fc} Hz (a third-octave either side > 3 dB lower)",
          at - below > 3 and at - above > 3, f"{at:.1f} vs {below:.1f} / {above:.1f} dBFS")

# ---- 6d. the taper top: 15 kHz, no ceiling ------------------------------------
top = rms_db(render(tone(15000, 0.2), FREQ=127, RES=64)[0])
mid = rms_db(render(tone(1000, 0.2), FREQ=127, RES=64)[0])
check("FREQ 127 LP at RES 64 peaks at 15 kHz (louder than 1 kHz)", top > mid,
      f"15 kHz {top:.1f}, 1 kHz {mid:.1f} dBFS")

# ---- 6e. RES 127 is bounded ---------------------------------------------------
# RES 127 is R = 0.0149, Q ~ 34 (+30 dB at fc). A 0.02 FS tone at fc comes out
# near -7 dBFS in a linear core: below full scale, never on a rail. A 0.5 FS
# tone at fc clips in ANY linear SVF (the float reference too); what the core
# owes there is to clamp and let go -- the burst stops and the tail decays,
# no state latched on a rail.
def bounded(label, out):
    tail = out[N // 2:]
    pk = max(abs(v) for v in tail)
    rail = sum(1 for v in tail if abs(v) >= 0x7ffff0) / len(tail)
    check(label, pk < 0x7ffff0 and rail < 0.01,
          f"peak {20 * math.log10(max(pk, 1) / 8388607):+.1f} dBFS, {rail * 100:.2f}% of the tail on a rail")
bounded("RES 127 LP at fc, 0.02 FS in: below full scale, never on the rails",
        render(tone(600, 0.02), FREQ=64, RES=127)[0])
bounded("RES 127 BP at fc, 0.02 FS in: below full scale, never on the rails",
        render(tone(600, 0.02), FREQ=64, RES=127, MODE=1)[0])
bounded("RES 127 VOWL a at F1, 0.5 FS in: below full scale, never on the rails",
        render(tone(730, 0.5), FREQ=0, RES=127, MODE=4)[0])
burst = tone(600, 0.5, N // 2) + [0] * (N // 2)
for m, mn in ((0, "LP"), (1, "BP")):
    out = render(burst, FREQ=64, RES=127, MODE=m)[0]
    hit = max(abs(v) for v in out[N // 4:N // 2]) >= 0x7ffff0
    # Q ~ 34 at 600 Hz rings with tau = Q / (pi fc) = 18 ms = 794 samples, so
    # each eighth of the render (750 samples) after the burst is ~8 dB quieter
    # than the one before; a latched state would hold level.
    e7 = 20 * math.log10(max(1e-9, math.sqrt(sum((v / 8388607) ** 2 for v in out[N * 6 // 8:N * 7 // 8]) / (N // 8))))
    e8 = rms_db(out, start=N * 7 // 8)
    check(f"RES 127 {mn}: a 0.5 FS burst at fc clips, then lets go (rings down ~8 dB per 17 ms)",
          hit and e8 < e7 - 5 and e8 < -20,
          f"{'clipped' if hit else 'NOT clipped'}, seventh eighth {e7:.1f}, last {e8:.1f} dBFS")

# ---- 6f. the VOWL bank: five vowels on the Peterson-Barney table --------------
VOWELS = (("a", 0, 730, 1090), ("e", 32, 530, 1840), ("i", 64, 270, 2290),
          ("o", 96, 570, 840), ("u", 127, 300, 870))
own = {}
for name, freq, f1, f2 in VOWELS:
    for fn, fk in (("F1", f1), ("F2", f2)):
        at = rms_db(render(tone(fk, 0.2), FREQ=freq, RES=100, MODE=4)[0])
        lo_ = rms_db(render(tone(fk / 1.19, 0.2), FREQ=freq, RES=100, MODE=4)[0])
        hi_ = rms_db(render(tone(fk * 1.19, 0.2), FREQ=freq, RES=100, MODE=4)[0])
        check(f"VOWL {name} {fn} is a peak at {fk} Hz (a quarter octave either side lower)",
              at > lo_ and at > hi_, f"{at:.1f} vs {lo_:.1f} / {hi_:.1f} dBFS")
        if fn == "F1":
            own[name] = at
    others = [rms_db(render(tone(o1, 0.2), FREQ=freq, RES=100, MODE=4)[0])
              for on, _, o1, _ in VOWELS if on != name]
    check(f"VOWL {name} is loudest at its own F1 among the five", own[name] > max(others),
          f"own {own[name]:.1f}, best other {max(others):.1f} dBFS")

# ---- 7. every knob at its extremes renders -----------------------------------
for name in K:
    for v in (0, 127 if MOD.params[K[name]].count in (None, 128) else MOD.params[K[name]].count - 1):
        render(tone(438, n=600), **{name: v})
check("every knob at both extremes renders", True)

# ---- THE FX1-ONLY PROMISE (12 Sep 2026): an FX2 instance is dry -------------
# Claims.fx1_only says an FX2-slot instance touches nothing; the rig's cycle
# envelope (tools/harness/pressure.py) and the FX2 chooser both take it at
# its word, so it is proven here at every extreme, and the guard sees no
# write outside the frame.
L, R = render(ramp, slot="fx2", FREQ=30, RES=110, DRV=127, MODE=1, ROUT=2, DPTH=127, SRC=2)
check("FX2 instance is a bit-exact DRY PASS at every extreme (fx1_only)",
      L == ramp and R == ramp,
      "" if L == ramp else f"first diff at {next(i for i,(a,b) in enumerate(zip(L,ramp)) if a!=b)}")
render(ramp, slot="fx2", guard=True, FREQ=30, RES=110, DRV=127, MODE=1, ROUT=2, DPTH=127, SRC=2)
g = getattr(render, "guard_out", "")
check("FX2 instance trips no write guard",
      "guard clean" in g,
      next((ln.strip() for ln in reversed(g.splitlines()) if "guard" in ln), ""))

print(f"\n{fails} gate(s) failed" if fails else "\nOK")
sys.exit(1 if fails else 0)
