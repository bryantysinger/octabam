#!/usr/bin/env python3
"""LOFI2's render gate: levels, AMPH, GAIN and the MODE duck, through dsp_host.

    python3 tools/verify/verify_lofi2.py

Renders the module straight through dsp_host on payload A of a scratch
image that carries it (tools/remix/audition.py's insert dump; the user's
out/mainos_bus.bin is saved and restored around the build). The input is a
mono 440 Hz sine at 0.125 FS fed to both channels, low enough that GAIN at
its top (x3.96) cannot reach the store's limiter. Levels are read from
0.25 s on, after the start-up fade-in, and against MIX 0 through the same
path, so the harness's own gains cancel.

  ring level      RING, MIX 127, GAIN 0: -2.80 dB re MIX 0 (the parabolic
                  carrier's RMS, sqrt(8/15) = -2.73 dB, and MIX 127 = 127/128,
                  -0.07 dB). Measured on the unit's tree under rig_render,
                  both cores, 10 Oct 2026.
  GAIN            2^(k/64): +6.02 dB at 64, +11.95 dB at 127, re GAIN 0
                  (the quadratic for 2^f is within 0.023 dB).
  SHIFT level     SHIFT UP, MIX 127: the wanted sideband at unity, so about
                  -0.07 dB re MIX 0 (MIX 127 again).
  AMPH            RING with both channels fed the same signal: AMPH 64 (0 deg)
                  gives L == R bit for bit; +45 deg (96) and -45 deg (32)
                  leave L alone and move R.
  fade-in         init starts the wet fully ducked: over the first 32 samples
                  the wet (output less the MIX 0 render) is under 20% of its
                  steady RMS, and from 400 samples (9 ms) on it is within
                  0.5 dB of steady.
  MODE duck       RING -> UP at block 600, by -paramfile: the largest
                  second difference across the switch is no larger than
                  1.25x the larger of the two steady states' (a hard switch
                  steps by ~0.25 FS here, hundreds of times the steady d2),
                  and the output passes through the dry on the way: some
                  16-sample window where it is within 1% FS of the MIX 0
                  render (the steady wet differs from it by ~12% FS).

  SRR rate        the hold's droop on a 2 kHz tone, sinc(pi f / f_r), against
                  stock LO-FI's at SRR 16/32/64/96/127 (each re its own SRR 0),
                  within 0.15 dB. Stock is rendered from the user's own image
                  (audition's pristine dump); under this harness it matched
                  the unit at 64 and 127 (8,018 and 3,564 Hz, 10 Oct 2026).
                  A rate off by 2x misses by several dB.
  SRR turn        verify_knob_clicks's instrument: SRR turned 20 -> 110 one
                  value every two blocks, the block-locked step under
                  -70 dBFS.
  BRR step        a slow ramp through BRR 16..127 on stock and LOFI2: the
                  spacing of the output's plateaus (runs of one value, 24+
                  samples, so any filter has settled) over the DC gain (the
                  output's regression on the ramp), as bits: LOFI2's within
                  0.05 bit of stock's. A tone's residual would also read
                  each effect's own filters (LOFI2's shelf, stock's FIR
                  after the hold), which differ; plateaus do not.
                  The ramp stays inside +-0.45 FS: stock LO-FI clips its
                  input near 0.5 FS once BRR is up, which would bend the
                  DC gain (measured with +-0.8 FS: 0.24-0.34 bit off at
                  80-127, as a clip at 0.5 predicts, 0.837 at +-0.77).
  BRR gain        the tone's level at BRR 64 against BRR 0: within 0.05 dB
                  (the step's mantissa and its reciprocal are an exact pair).
  BRR turn        as SRR's: under -70 dBFS.

Not covered: payload B (tracks 1-4) -- dsp_host renders one payload here;
`rig_render` covers both, and the October port's A/B found T1 == T5.
"""
import math, pathlib, struct, subprocess, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1])); import toolpath  # noqa: E402,F401  (every tools/ dir on sys.path)
from remix import audition, registry  # noqa: E402
import send_probe  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[2]
MOD = registry.by_name("lofi2")
SEND = registry.by_name("send")
K = MOD.knob_map()
HOST = ROOT / "vendor/dsp56300/build/source/dsp_host/dsp_host"
FRAMES = 16
SR = 44100
TMP = ROOT / "out/_lofi2gate"
TMP.mkdir(parents=True, exist_ok=True)

MEM = audition._ensure_insert_mem(MOD)
INIT, PROC = send_probe.entry_points(MEM, MOD.menu.fx2_id)
if (INIT, PROC) == send_probe.entry_points(MEM, SEND.menu.fx2_id):
    sys.exit(f"fx id 0x{MOD.menu.fx2_id:02x} resolves to SEND's entry points -- "
             f"LOFI2 is NOT in {MEM}")
print(f"entries from dispatch tables: init=P:0x{INIT:04x} proc=P:0x{PROC:04x}")

DEFAULTS = [(p.default or 0) for p in MOD.params]
SETTLE = SR // 4                          # levels are read after this many samples


def params(**kw):
    v = list(DEFAULTS)
    for name, val in kw.items():
        v[K[name]] = val
    return v


def sine(seconds, amp=0.125, f=440.0):
    n = int(SR * seconds) // FRAMES * FRAMES
    return [int(round(amp * math.sin(2 * math.pi * f * i / SR) * (1 << 23))) for i in range(n)]


def render(samples, schedule=None, raw=None, mem=None, ep=None, sched=None, **kw):
    """Mono Q23 ints in, fed to both channels; (L, R) ints out. `schedule`
    is [(block, {knob: value}), ...] on top of kw, by -paramfile. `raw` (a
    12-value list), `mem`/`ep` and `sched` (dsp_host -sched) render another
    effect -- stock LO-FI -- through the same path."""
    n = len(samples)
    src, out = TMP / "in.raw", TMP / "out.raw"
    src.write_bytes(b"".join(struct.pack("<i", s) for s in samples))
    m, (i0, p0) = (mem or MEM), (ep or (INIT, PROC))
    cmd = [str(HOST), "-mem", str(m), "-init", f"{i0:x}", "-proc", f"{p0:x}",
           "-inst", "1", "-r7", "1", "-alloc", "0", "-inmask", "1", "-audio", "0",
           "-frames", str(FRAMES), "-blocks", str(n // FRAMES),
           "-in", str(src), "-out", str(out),
           "-params", ",".join(str(x) for x in (raw if raw is not None else params(**kw)))]
    if sched:
        cmd += ["-sched", sched]
    if schedule:
        pf = TMP / "sched.txt"
        rows = []
        cur = dict(kw)
        for block, change in schedule:
            cur.update(change)
            rows.append(",".join(str(x) for x in [block] + params(**cur)))
        pf.write_text("\n".join(rows) + "\n")
        cmd += ["-paramfile", str(pf)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"dsp_host failed for {kw}:\n{r.stdout}\n{r.stderr}")
    raw = out.read_bytes()
    w = struct.unpack(f"<{len(raw) // 4}i", raw)
    return list(w[0::2])[:n], list(w[1::2])[:n]


def rms(x, a=SETTLE, b=None):
    seg = x[a:b]
    return math.sqrt(sum(v * v for v in seg) / len(seg))


def db(a, b):
    return 20 * math.log10(a / b)


def d2max(x, a, b):
    return max(abs(x[i + 1] - 2 * x[i] + x[i - 1]) for i in range(max(a, 1), min(b, len(x) - 1)))


FAILS = []


def check(label, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {label}" + (f"  {detail}" if detail else ""))
    if not ok:
        FAILS.append(label)


SIG = sine(1.0)
dryL, dryR = render(SIG, MODE=0, MIX=0)
base = rms(dryL)

# ---- levels ----------------------------------------------------------------
ring0, _ = render(SIG, MODE=0, MIX=127, RANGE=1, FREQ=64, FDBK=0)
lv = db(rms(ring0), base)
check("ring level, GAIN 0: -2.80 dB re MIX 0", abs(lv + 2.80) <= 0.05, f"{lv:+.2f} dB")

for k, want in ((64, 6.02), (127, 11.95)):
    rk, _ = render(SIG, MODE=0, MIX=127, RANGE=1, FREQ=64, FDBK=k)
    g = db(rms(rk), rms(ring0))
    check(f"GAIN {k}: {want:+.2f} dB re GAIN 0", abs(g - want) <= 0.10, f"{g:+.2f} dB")

shL, _ = render(SIG, MODE=2, MIX=127, RANGE=1, FREQ=30, FDBK=0)
sl = db(rms(shL), base)
check("SHIFT UP level: about -0.07 dB re MIX 0", abs(sl + 0.07) <= 0.10, f"{sl:+.2f} dB")

# ---- AMPH --------------------------------------------------------------------
c0L, c0R = render(SIG, MODE=0, MIX=127, RANGE=0, FREQ=64, AMPH=64)
check("AMPH 0 deg (64): L == R bit for bit", c0L == c0R)
pL, pR = render(SIG, MODE=0, MIX=127, RANGE=0, FREQ=64, AMPH=96)
mL, mR = render(SIG, MODE=0, MIX=127, RANGE=0, FREQ=64, AMPH=32)
check("AMPH +45 / -45 deg: L untouched", pL == c0L and mL == c0L)
check("AMPH +45 / -45 deg: R moved, differently", pR != c0R and mR != c0R and pR != mR)

# ---- fade-in -----------------------------------------------------------------
wet = [a - b for a, b in zip(ring0, dryL)]
w_steady = rms(wet)
w_head = rms(wet, 0, 32)
w_after = rms(wet, 400, SETTLE)
check("fade-in: the first 32 samples carry < 20% of the steady wet",
      w_head < 0.2 * w_steady, f"{w_head / w_steady:.3f} of steady")
check("fade-in: the wet is back within 0.5 dB by 9 ms",
      abs(db(w_after, w_steady)) <= 0.5, f"{db(w_after, w_steady):+.2f} dB")

# ---- MODE duck ---------------------------------------------------------------
SW = 600                                   # the switch block
LONG = sine(1.6)
dlL, _ = render(LONG, MODE=0, MIX=0)
swL, swR = render(LONG, schedule=[(0, {}), (SW, {"MODE": 2})],
                  MODE=0, MIX=127, RANGE=1, FREQ=64)
s0, s1 = SW * FRAMES, (SW + 40) * FRAMES
steady = max(d2max(swL, 300 * FRAMES, 550 * FRAMES), d2max(swL, 800 * FRAMES, 1000 * FRAMES))
across = d2max(swL, s0 - 4 * FRAMES, s1)
check("MODE RING -> UP: no step larger than the steady states'", across <= 1.25 * steady,
      f"switch {across} vs steady {steady} (d2, LSB)")
lim = (1 << 23) // 100
quiet = min(max(abs(swL[j] - dlL[j]) for j in range(i, i + 16)) for i in range(s0, s1 - 16))
check("MODE RING -> UP: passes through the dry", quiet <= lim,
      f"closest 16-sample window {quiet} LSB (limit {lim})")

# ---- SRR: the rate against stock's, and a turn ------------------------------
def fit_amp(y, f, a, b):
    w = 2 * math.pi * f / SR
    sc = ss = cc = ys = yc = 0.0
    for i in range(a, b):
        s_, c_ = math.sin(w * i), math.cos(w * i)
        ss += s_ * s_; cc += c_ * c_; sc += s_ * c_; ys += y[i] * s_; yc += y[i] * c_
    det = ss * cc - sc * sc
    return math.hypot((ys * cc - yc * sc) / det, (yc * ss - ys * sc) / det)


SMEM = audition._ensure_stock_mem()
SEP = send_probe.entry_points(SMEM, 0x1c)            # stock LO-FI
tone2k = sine(0.5, amp=0.3, f=2000.0)
def droop(lofi2, k):
    if lofi2:
        y0, _ = render(tone2k, SRR=0)
        y1, _ = render(tone2k, SRR=k)
    else:
        z = [0] * 12
        y0, _ = render(tone2k, raw=z, mem=SMEM, ep=SEP)
        y1, _ = render(tone2k, raw=z[:3] + [k] + z[4:], mem=SMEM, ep=SEP)
    a, b = SR // 8, len(tone2k) - 64
    return db(fit_amp(y1, 2000.0, a, b), fit_amp(y0, 2000.0, a, b))
for k in (16, 32, 64, 96, 127):
    ds, dl = droop(False, k), droop(True, k)
    check(f"SRR {k}: the hold's droop at 2 kHz matches stock's", abs(ds - dl) <= 0.15,
          f"stock {ds:+.2f} dB, LOFI2 {dl:+.2f} dB")


def step_db(x, b0, b1):
    """verify_knob_clicks.step_db on Q23 ints."""
    e = [0.0] * FRAMES
    for n in range(b0 * FRAMES, b1 * FRAMES):
        a_, b_, c_, d_ = (v / 8388607.0 for v in x[n - 2:n + 2])
        if max(abs(a_), abs(b_), abs(c_), abs(d_)) >= 0.9999:
            continue
        v = d_ - 3 * c_ + 3 * b_ - a_
        e[n % FRAMES] += v * v
    import statistics
    med = statistics.median(e)
    spread = 1.4826 * statistics.median(abs(v - med) for v in e)
    excess = max(e) - med - 3 * spread
    return max(-140.0, 10 * math.log10(max(excess, 1e-30) / (6 * (b1 - b0))))


T0, T1 = 400, 400 + 2 * 90
toneT = sine((T1 + 100) * FRAMES / SR, amp=0.3, f=438.75)
slot = K["SRR"]
turn, _ = render(toneT, sched=",".join(f"{T0 + 2 * i}:0:{slot}={20 + 1 + i}" for i in range(90)), SRR=20)
held, _ = render(toneT, SRR=20)
tl, hl = step_db(turn, T0, T1), step_db(held, T0, T1)
check("SRR turn 20 -> 110: block-locked step under -70 dBFS", tl < -70.0,
      f"turn {tl:.1f} dBFS, held {hl:.1f}")

# ---- BRR: noise against stock's, unity gain, a turn ---------------------------
def fit_res(y, f, a, b):
    w = 2 * math.pi * f / SR
    sc = ss = cc = ys = yc = 0.0
    for i in range(a, b):
        s_, c_ = math.sin(w * i), math.cos(w * i)
        ss += s_ * s_; cc += c_ * c_; sc += s_ * c_; ys += y[i] * s_; yc += y[i] * c_
    det = ss * cc - sc * sc
    A, B = (ys * cc - yc * sc) / det, (yc * ss - ys * sc) / det
    res = sum((y[i] - A * math.sin(w * i) - B * math.cos(w * i)) ** 2 for i in range(a, b))
    return math.hypot(A, B), math.sqrt(res / (b - a))


def brr_bits(y, x):
    """The quantiser's step in input units, as bits: plateau spacing / DC gain."""
    a = 2048
    n = len(x) - a
    mx, my = sum(x[a:]) / n, sum(y[a:]) / n
    slope = (sum((u - mx) * (v - my) for u, v in zip(x[a:], y[a:]))
             / sum((u - mx) ** 2 for u in x[a:]))
    vals, run = [], 1
    for u, v in zip(y[a:], y[a + 1:]):
        if u == v:
            run += 1
        else:
            if run >= 24:
                vals.append(u)
            run = 1
    d = sorted(abs(v - u) for u, v in zip(vals, vals[1:]) if v != u)
    return (math.log2(d[len(d) // 2] / slope), len(vals)) if len(d) >= 2 else (None, len(vals))


NR = 32768
MOD_BRR_E = MOD.dsp.ptable[129:258]          # BRR_E, after SRR_INC
for k in (16, 32, 48, 64, 80, 96, 112, 127):
    span = min(0.9 * 8388607, 200 * 2 ** (MOD_BRR_E[k] / (1 << 17) + 1))
    ramp = [int(-span / 2 + span * i / NR) for i in range(NR)]
    z = [0] * 12
    bs, ps = brr_bits(render(ramp, raw=z[:4] + [k] + z[5:], mem=SMEM, ep=SEP)[0], ramp)
    bl, pl = brr_bits(render(ramp, BRR=k)[0], ramp)
    ok = bs is not None and bl is not None and abs(bs - bl) <= 0.05
    check(f"BRR {k}: the step matches stock's", ok,
          f"stock {bs if bs is None else round(bs, 3)} bits ({ps} plateaus), "
          f"LOFI2 {bl if bl is None else round(bl, 3)} bits ({pl})")

tone440 = sine(0.5, amp=0.3, f=440.0)
a0, b0 = SR // 8, len(tone440) - 64
g0, _ = fit_res(render(tone440, BRR=0)[0], 440.0, a0, b0)
g64, _ = fit_res(render(tone440, BRR=64)[0], 440.0, a0, b0)
check("BRR 64: unity gain against BRR 0", abs(db(g64, g0)) <= 0.05, f"{db(g64, g0):+.3f} dB")

slot = K["BRR"]
turn, _ = render(toneT, sched=",".join(f"{T0 + 2 * i}:0:{slot}={20 + 1 + i}" for i in range(90)), BRR=20)
held, _ = render(toneT, BRR=20)
tl, hl = step_db(turn, T0, T1), step_db(held, T0, T1)
check("BRR turn 20 -> 110: block-locked step under -70 dBFS", tl < -70.0,
      f"turn {tl:.1f} dBFS, held {hl:.1f}")

print()
if FAILS:
    print(f"{len(FAILS)} FAILED")
    sys.exit(1)
print("all LOFI2 gates pass")
