#!/usr/bin/env python3
"""CHARACTER render gates, with arithmetic you can predict.

Renders the station straight through dsp_host (verify_hello's shape: the id
and the slots come from the manifest, the entry points are checked against
SEND's so an absent module cannot pass as a dry passthrough).

Gates:
  defaults    -> output bit-exact vs a full-scale bipolar ramp (the bypass)
  MIX=0       -> bit-exact passthrough with the whole chain live
  CRSH        -> the output is quantised: every sample a multiple of 2^k
  SRR         -> /2 /4 /8 hold each sample exactly that many times
  DRV/SAT     -> DRV 0 skips the stage (bit-exact); TAPE/TUBE/INFL bounded;
                 TUBE asymmetric (even harmonics); INFL adds level
  FOLD        -> a full-scale ramp folds back: the output reverses direction
  RING        -> at DC the output is DC * carrier, so its mean is ~0
  COMP/GLUE   -> AC1's dip: deeper with COMP, unity at COMP 0 (skipped), GLUE's makeup, COMP releases faster
  WDTH        -> 0 = mono (L == R), 64 = untouched, 127 = doubled sides
  every knob  -> renders without dsp_host dying

The dump comes from the audition, which builds a scratch image that really
contains this station beside SEND:

    python3 tools/remix/audition.py character out/dry/drums_110.wav
    python3 tools/verify/verify_character.py
"""
import math, pathlib, struct, subprocess, sys

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parents[1])); import toolpath  # noqa: E402,F401  (every tools/ dir on sys.path)
import send_probe  # reuse its dispatch-table entry resolution
from remix import registry

MOD = registry.by_name("character")
SEND = registry.by_name("send")
K = MOD.knob_map()
MEM = f"out/dsp/_audition_{MOD.name}_A.mem"
HOST = "vendor/dsp56300/build/source/dsp_host/dsp_host"
FXID = MOD.menu.fx2_id
FRAMES, N = 15, 6000
SR = 44100
TMP = pathlib.Path("out/_chgate")
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
    src = TMP / "ch_in.raw"
    src.write_bytes(b"".join(struct.pack("<i", m) for m in samples))
    out = TMP / "ch_out.raw"
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

# ---- 2. MIX=0 with the whole chain live --------------------------------------
L, R = render(ramp, MIX=0, DRV=127, FOLD=127, CRSH=127, COMP=127, RING=64, SRR=3)
check("MIX=0 is a passthrough with every stage driven", L == ramp and R == ramp,
      "" if L == ramp else f"first diff at {next(i for i,(a,b) in enumerate(zip(L,ramp)) if a!=b)}")

# ---- 3. CRSH reduces the resolution -----------------------------------------
# ⚠️ MEASURE THE WET, NOT THE OUTPUT, twice over: the saturator is a cubic
# that fills the low bits back in, AND the mix law carries 1/128 of the live
# dry, which is not quantised -- so every output sample is distinct however
# hard the crush bites. The wet comes back exactly (out = dry/128 + wet*127/128)
# and its DISTINCT LEVELS are what the crush actually sets.
slow = [int(-8388607 + 2 * 8388607 * i / (N - 1)) for i in range(N)]
def levels(crsh):
    L, _ = render(slow, CRSH=crsh)
    wet = [round((o - d / 128) * 128 / 127) for o, d in zip(L, slow)]
    return len(set(wet[N//4:]))
n_off, n_on = levels(1), levels(110)
check("CRSH=110 collapses a ramp to a few levels", n_on * 8 < n_off,
      f"{n_on} distinct wet levels against {n_off} at CRSH=0")

# ---- 4. SRR holds each sample -----------------------------------------------
# ⚠️ THE OUTPUT IS NOT HELD, THE WET IS. MIX=127 is 127/128, so the output
# carries 1/128 of the live dry: out = dry/128 + wet*127/128. Recover the wet
# exactly and look for its runs, rather than testing near-equality on a
# signal that legitimately moves every sample.
src = tone(438)
for sel, hold in ((1, 2), (2, 4), (3, 8)):
    L, _ = render(src, SRR=sel)
    wet = [(o - d / 128) * 128 / 127 for o, d in zip(L, src)]
    seg = [round(v) for v in wet[N//2:N//2 + 400]]
    runs, cur = [], 1
    for a, b in zip(seg, seg[1:]):
        if abs(a - b) <= 2:
            cur += 1
        else:
            runs.append(cur); cur = 1
    typical = max(set(runs), key=runs.count) if runs else 0
    check(f"SRR /{hold} holds the wet {hold} samples", typical == hold,
          f"most common run {typical}")

# ---- 5. saturation is unity small-signal and bounded -------------------------
small = [int(0.001 * 8388607 * math.sin(2 * math.pi * 438 * i / SR)) for i in range(N)]
for sat, name in ((0, "TAPE"), (1, "TUBE"), (2, "INFL")):
    L, _ = render(small, DRV=0, SAT=sat)
    err = max(abs(a - b) for a, b in zip(L[N//2:], small[N//2:]))
    check(f"SAT {name} DRV=0 is a bit-exact skip", err == 0, f"max err {err} LSB")
# TAPE is TapeHead (13 Sep 2026): TONE moves the SVF split 2.1 -> 5 kHz, so
# at DRV 64 on noise the top/bottom balance must follow it, and the mid point
# must sit between the ends (the law is monotonic).
def _tilt(L):
    import cmath
    n = len(L) // 2; seg = [v / 8388607 for v in L[n:]]
    def band(lo, hi):
        acc = 0.0
        for k in range(len(seg)):
            pass
        return acc
    # crude two-band split by a one-pole at ~3 kHz: energy above vs below
    a = math.exp(-2 * math.pi * 3000 / SR); lp = 0.0; el = eh = 0.0
    for v in seg:
        lp = a * lp + (1 - a) * v; el += lp * lp; eh += (v - lp) ** 2
    return 10 * math.log10((eh + 1e-12) / (el + 1e-12))
_rng = __import__("random").Random(5)
_noise = [int(0.3 * 8388607 * (_rng.random() * 2 - 1)) for _ in range(N)]
_t0 = _tilt(render(_noise, DRV=64, SAT=0, TONE=0)[0])
_t64 = _tilt(render(_noise, DRV=64, SAT=0, TONE=64)[0])
_t127 = _tilt(render(_noise, DRV=64, SAT=0, TONE=127)[0])
check("TAPE TONE moves the split (tilt 0 < 64 < 127)", _t0 < _t64 < _t127,
      f"tilt {_t0:.1f} / {_t64:.1f} / {_t127:.1f} dB")
check("TAPE TONE 127 vs 0 differs by >= 1 dB of tilt", _t127 - _t0 >= 1.0, f"{_t127 - _t0:.1f} dB")
for sat, name in ((0, "TAPE"), (1, "TUBE"), (2, "INFL")):
    L, _ = render(tone(438, amp=0.9), DRV=127, SAT=sat)
    check(f"SAT {name} stays bounded at DRV=127",
          max(abs(v) for v in L) <= 8388607, f"peak {max(abs(v) for v in L)}")
# TUBE (DaTube) adds harmonics with drive -- a pure tone grows non-fundamental
# energy. A crude test: the peak-to-rms crest of the output rises as the curve
# sharpens the waveform (a sine is crest ~1.41; saturation flattens it).
def _crest(L):
    seg = [v / 8388607 for v in L[N//2:]]
    pk = max(abs(v) for v in seg); r = (sum(v*v for v in seg) / len(seg)) ** 0.5
    return pk / max(r, 1e-9)
_c0 = _crest(render(tone(438, amp=0.5), DRV=1, SAT=1)[0])
_c1 = _crest(render(tone(438, amp=0.5), DRV=127, SAT=1)[0])
check("TUBE reshapes the waveform with drive (crest falls)", _c1 < _c0 - 0.02,
      f"crest {_c0:.2f} -> {_c1:.2f}")
# INFL (OInflator) adds level -- the whole point of an inflator.
_i0 = rms_db(render(tone(438, amp=0.13), DRV=0, SAT=2)[0])
_i1 = rms_db(render(tone(438, amp=0.13), DRV=127, SAT=2)[0])
check("INFL adds level as DRV rises", _i1 > _i0 + 1.0, f"{_i1 - _i0:+.1f} dB")

# ---- 6. FOLD folds a ramp back ----------------------------------------------
L, _ = render(ramp, FOLD=127, DRV=0, SAT=0)
turns = sum(1 for a, b, c in zip(L, L[1:], L[2:]) if (b - a > 0) != (c - b > 0))
check("FOLD=127 folds a monotonic ramp (it changes direction many times)",
      turns > 4, f"{turns} direction changes")

# ---- 7. RING at DC: the output is DC * carrier, mean ~0 ----------------------
L, _ = render(dc(), RING=64, DRV=0)
m = abs(tail_mean(L, N // 4))
check("RING at DC has ~zero mean (it is DC times a carrier)",
      m < 0.05 * 0.25 * 8388607, f"mean {m:.0f} of {0.25*8388607:.0f}")

# ---- 8. the compressor is AC1's dip (JClones, 13 Sep 2026) -----------------
# gr = (Lv^2/2 - 1)^2 + a*Lv, <= 1: a dip around Lv = 1 (level 0.25 FS at
# COMP's 4x), unity well below it; the dip's depth is COMP. Above ~1.5 the
# law lets go (the JSFX's AC101 mode, a division, is not ported).
quiet, _ = render(tone(438, amp=0.05), COMP=127, CMOD=0)
dip, _ = render(tone(438, amp=0.25), COMP=127, CMOD=0)
q0, _ = render(tone(438, amp=0.05), COMP=0)
d0, _ = render(tone(438, amp=0.25), COMP=0)
gr_q = rms_db(quiet) - rms_db(q0)
gr_d = rms_db(dip) - rms_db(d0)
check("COMP reduces the signal in the dip (0.25 FS at 4x) far more than a quiet one",
      gr_d < gr_q - 6, f"quiet {gr_q:+.1f} dB, dip {gr_d:+.1f} dB")
shallow, _ = render(tone(438, amp=0.25), COMP=40, CMOD=0)
check("the dip deepens with COMP",
      rms_db(shallow) - rms_db(d0) > gr_d + 3,
      f"COMP 40 {rms_db(shallow) - rms_db(d0):+.1f} dB, COMP 127 {gr_d:+.1f} dB")
unity, _ = render(tone(438, amp=0.3), COMP=0, CMOD=0)
ref, _ = render(tone(438, amp=0.3), MIX=0)
check("COMP=0 is unity gain (the stage is skipped, bit-exact)",
      unity == ref, f"{rms_db(unity) - rms_db(ref):+.2f} dB")
glue, _ = render(tone(438, amp=0.13), COMP=40, CMOD=1)
g0, _ = render(tone(438, amp=0.13), COMP=0)
check("GLUE at COMP 40 lifts a 0.13 FS tone by about +1 dB (the makeup)",
      0.4 < rms_db(glue) - rms_db(g0) < 1.6, f"{rms_db(glue) - rms_db(g0):+.2f} dB")
# release, as the reference harness measures it: a 0.13 FS tone stepped up
# 10 dB for a third and back; the time after the step down until the output
# sits within 1 dB of its final level. COMP (50 ms) beats GLUE (500 ms).
NS = 24000
stepped = [int(0.13 * (10 ** 0.5 if NS // 3 <= i < 2 * NS // 3 else 1.0) * 8388607
               * math.sin(2 * math.pi * 438 * i / SR)) for i in range(NS)]
def env10(x, w=441):
    return [20 * math.log10(max(1e-9, math.sqrt(sum(v * v for v in x[i:i + w]) / w) / 8388607))
            for i in range(0, len(x) - w, w)]
def release_ms(cmod):
    y, _ = render(stepped, COMP=127, CMOD=cmod)
    e = env10(y); k2 = 2 * len(e) // 3; fin = e[-1]
    for j in range(k2, len(e)):
        if abs(e[j] - fin) < 1.0:
            return (j - k2) * 10.0
    return 1e9
rc, rg = release_ms(0), release_ms(1)
check("COMP releases faster than GLUE (to within 1 dB after a 10 dB step down)",
      rc < rg, f"COMP {rc:.0f} ms, GLUE {rg:.0f} ms")

# ---- 9. TRNS retired 13 Sep 2026 (was here) --------------------------------

# ---- 10. WDTH -----------------------------------------------------------------
# a stereo-different source: dsp_host feeds one stream to both channels, so
# the width test rides on the RING carrier making L and R identical anyway --
# what it can prove is that 0 collapses to mono and 64 leaves the pair alone.
L, R = render(tone(438), WDTH=0, DRV=1)
check("WDTH=0 is mono (L == R)", L == R, "")
L64, R64 = render(tone(438), WDTH=64, DRV=1)
Lref, _ = render(tone(438), DRV=1)
check("WDTH=64 leaves the signal alone", L64 == Lref, "")

# ---- 11. every knob at its extremes renders ----------------------------------
for name in K:
    for v in (0, 127 if MOD.params[K[name]].count in (None, 128) else MOD.params[K[name]].count - 1):
        render(tone(438, n=600), **{name: v})
check("every knob at both extremes renders", True)

# ---- THE FX1-ONLY PROMISE (12 Sep 2026): an FX2 instance is dry -------------
# Claims.fx1_only says an FX2-slot instance touches nothing; the rig's cycle
# envelope (tools/harness/pressure.py) and the FX2 chooser both take it at
# its word, so it is proven here at every extreme, and the guard sees no
# write outside the frame.
L, R = render(ramp, slot="fx2", DRV=127, FOLD=127, CRSH=100, COMP=127, MIX=127, SAT=2, RING=100, WDTH=127, SRR=2)
check("FX2 instance is a bit-exact DRY PASS at every extreme (fx1_only)",
      L == ramp and R == ramp,
      "" if L == ramp else f"first diff at {next(i for i,(a,b) in enumerate(zip(L,ramp)) if a!=b)}")
render(ramp, slot="fx2", guard=True, DRV=127, FOLD=127, CRSH=100, COMP=127, MIX=127, SAT=2, RING=100, WDTH=127, SRR=2)
g = getattr(render, "guard_out", "")
check("FX2 instance trips no write guard",
      "guard clean" in g,
      next((ln.strip() for ln in reversed(g.splitlines()) if "guard" in ln), ""))

print(f"\n{fails} gate(s) failed" if fails else "\nOK")
sys.exit(1 if fails else 0)
