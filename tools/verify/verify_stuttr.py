#!/usr/bin/env python3
"""STUTTR render gates (chance-engage redesign).

  MIX=0       -> bit-exact passthrough
  CHNC=0      -> stays dry (wet residual ~0) with MIX 127
  CHNC=127    -> engages: wet residual while HOLD
  SIZE        -> spike repeats at ~(kn+1)^2/2 sample gaps
  HALF        -> loop gaps ~2x FWD
  REV=127     -> non-silent (and differs from REV=0 on a spike)
  HOLD short  -> returns toward dry after reload
  every knob  -> renders without dsp_host dying
  max-knob    -> rail count ~0 for each MODE over ~3 s
  two-inst    -> energy + peak per instance
  LFSR        -> CHNC mid neither dry nor always-on; MODE RND varies
"""
import math
import pathlib, struct, subprocess, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import toolpath  # noqa: E402,F401
import send_probe
from remix import registry

MOD = registry.by_name("stuttr")
SEND = registry.by_name("send")
K = MOD.knob_map()
MEM = f"out/dsp/_audition_{MOD.name}_A.mem"
HOST = "vendor/dsp56300/build/source/dsp_host/dsp_host"
FXID = MOD.menu.fx2_id
FRAMES = 15
FS = 44100
RAIL = 1 << 23
TMP = pathlib.Path("out/_stgate")
TMP.mkdir(parents=True, exist_ok=True)
CLEAR = 0x80 * FRAMES

pathlib.Path(MEM).unlink(missing_ok=True)
subprocess.run([sys.executable, "tools/remix/audition.py", MOD.name, "out/dry/drums_110.wav"],
               capture_output=True)
if not pathlib.Path(MEM).exists():
    sys.exit(f"no {MEM} -- audition failed for {MOD.name}")
init, proc = send_probe.entry_points(MEM, FXID)
if (init, proc) == send_probe.entry_points(MEM, SEND.menu.fx2_id):
    sys.exit(f"fx id 0x{FXID:02x} is SEND -- STUTTR not in dump")
print(f"entries: init=P:0x{init:04x} proc=P:0x{proc:04x}")

DEFAULTS = [(p.default or 0) for p in MOD.params]
# Panel default SYNC=8 spaces RATE ticks; gates need FREE for CHNC mid / SIZE.
DEFAULTS[K["SYNC"]] = 0



def params(**kw):
    v = list(DEFAULTS)
    for name, val in kw.items():
        v[K[name]] = val
    return v


def render(samples, inst=1, **kw):
    n = len(samples) - len(samples) % FRAMES
    src, out = TMP / "in.raw", TMP / "out.raw"
    src.write_bytes(b"".join(struct.pack("<i", m) for m in samples[:n]))
    # FX2 slots: r7 = 2+3*k (same layout as other FX2 insert gates)
    r7 = ",".join(str(2 + 3 * k) for k in range(inst))
    alloc = ",".join("1" for _ in range(inst))
    pcsv = ",".join(str(x) for x in params(**kw))
    cmd = [HOST, "-mem", MEM,
           "-init", ",".join(f"{init:x}" for _ in range(inst)),
           "-proc", ",".join(f"{proc:x}" for _ in range(inst)),
           "-inst", str(inst), "-r7", r7, "-alloc", alloc,
           "-audioidx", ",".join(str(k) for k in range(inst)),
           "-inmask", str((1 << inst) - 1),
           "-frames", str(FRAMES), "-blocks", str(n // FRAMES),
           "-in", str(src), "-out", str(out)]
    for _ in range(inst):
        cmd += ["-params", pcsv]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"dsp_host failed for {kw}:\n{r.stdout}\n{r.stderr}")
    outs = []
    for k in range(inst):
        p = out if k == 0 else pathlib.Path(f"{out}.i{k}")
        w = struct.unpack(f"<{len(p.read_bytes()) // 4}i", p.read_bytes())
        outs.append((list(w[0::2])[:n], list(w[1::2])[:n]))
        if k:
            p.unlink(missing_ok=True)
    return outs[0] if inst == 1 else outs


def peak_gaps(xs, thr=(1 << 17)):
    peaks = [i for i, x in enumerate(xs) if abs(x) > thr]
    sep = []
    for p in peaks:
        if not sep or p - sep[-1] >= 2:
            sep.append(p)
    gaps = [sep[i + 1] - sep[i] for i in range(len(sep) - 1)]
    return sep, gaps


FAILS = []


def check(label, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {label}" + (f"  {detail}" if detail else ""))
    if not ok:
        FAILS.append(label)


def size_words(kn):
    w = (kn + 1) ** 2
    if w < 8:
        w = 8
    return w & ~1


def size_frames(kn):
    return size_words(kn) // 2


def hold_samples(kn, size_kn):
    h = (kn + 1) ** 2 * 16
    g = size_frames(size_kn)
    return max(h, g)


N = 4800
ramp = [((i % 200) - 100) * (1 << 16) for i in range(N)]
tone = [int(0.3 * (1 << 23) * math.sin(2 * math.pi * 440 * i / 44100))
        for i in range(N)]

print("STUTTR gates")
L, R = render(ramp, MIX=0, SIZE=80, RATE=100, CHNC=127, HOLD=40, MODE=0)
check("MIX=0 bit-exact", L == ramp and R == ramp,
      f"max|d|={max(abs(a - b) for a, b in zip(L, ramp))}")

E_dry = sum(x * x for x in render(tone, MIX=0)[0])
Lmiss, _ = render(tone, MIX=127, SIZE=40, RATE=120, CHNC=0, HOLD=80, MODE=0, REV=0)
res_miss = sum((a - b) * (a - b) for a, b in zip(Lmiss, tone[:len(Lmiss)]))
check("CHNC=0 stays dry", res_miss < E_dry // 1000 + 1,
      f"res={res_miss} Edry={E_dry}")

Lhit, _ = render(tone + tone, MIX=127, SIZE=40, RATE=120, CHNC=127, HOLD=100,
                 MODE=0, REV=0)
res_hit = sum((a - b) * (a - b) for a, b in zip(Lhit[CLEAR:], (tone + tone)[CLEAR:len(Lhit)]))
check("CHNC=127 engages", res_hit > E_dry // 4,
      f"res={res_hit}")

Nspike = CLEAR + 12000


def spike_in(kn):
    s = [0] * Nspike
    s[CLEAR + size_frames(kn) - 2] = 1 << 22
    return s


engage = dict(CHNC=127, HOLD=127, RATE=0, REV=0, MIX=127, MODE=0)

for kn in (0, 8, 16):
    expect = size_frames(kn)
    Lw, _ = render(spike_in(kn), SIZE=kn, **engage)
    peaks, gaps = peak_gaps(Lw)
    good = [g for g in gaps if abs(g - expect) <= 2]
    check(f"SIZE={kn} loop gap~{expect}",
          len(peaks) >= 3 and len(good) >= 2,
          f"peaks={len(peaks)} gaps={gaps[:6]} matched={len(good)}")

g8 = peak_gaps(render(spike_in(8), SIZE=8, **engage)[0])[1]
g32 = peak_gaps(render(spike_in(32), SIZE=32, **engage)[0])[1]
med = lambda gs: sorted(gs)[len(gs) // 2] if gs else 0
check("SIZE mid dial still lengthens", med(g8) < med(g32) and med(g8) > 0,
      f"med8={med(g8)} med32={med(g32)}")

# HALF: same spike, gaps ~2x FWD
Lf, _ = render(spike_in(8), SIZE=8, CHNC=127, HOLD=127, RATE=0, REV=0, MIX=127, MODE=0)
Lh, _ = render(spike_in(8), SIZE=8, CHNC=127, HOLD=127, RATE=0, REV=0, MIX=127, MODE=1)
gf, gh = peak_gaps(Lf)[1], peak_gaps(Lh)[1]
check("HALF gaps ~2x FWD",
      med(gf) > 0 and med(gh) >= med(gf) * 2 - 2,
      f"medFWD={med(gf)} medHALF={med(gh)}")

Lrev0, _ = render(spike_in(16), SIZE=16, CHNC=127, HOLD=127, RATE=0, REV=0, MIX=127, MODE=0)
Lrev1, _ = render(spike_in(16), SIZE=16, CHNC=127, HOLD=127, RATE=0, REV=127, MIX=127, MODE=0)
check("REV=127 changes vs 0", Lrev0 != Lrev1,
      f"identical={Lrev0 == Lrev1}")
check("REV=127 non-silent", max(abs(x) for x in Lrev1) > (1 << 16),
      f"peak={max(abs(x) for x in Lrev1)}")

# Short HOLD: first-fill grab, brief hold, ~64-sample release fade, then dry
Nhold = CLEAR + 4000
tone_h = [int(0.25 * (1 << 23) * math.sin(2 * math.pi * 220 * i / 44100))
          for i in range(Nhold)]
# SIZE=0 -> 8 words / 4 frames; HOLD=1 -> reload (2)^2<<4 = 64 samples
# Engage fade ~64; release starts after HOLD and needs another ~64.
Lshort, _ = render(tone_h, SIZE=0, RATE=0, CHNC=127, HOLD=1, MIX=127, MODE=0, REV=0)
grab0 = CLEAR + size_frames(0)
mid_lo = grab0 + 40
mid_hi = grab0 + 56
tail_lo = grab0 + 64 + 128  # past release fade
mid_res = sum((a - b) * (a - b)
              for a, b in zip(Lshort[mid_lo:mid_hi], tone_h[mid_lo:mid_hi]))
tail_res = sum((a - b) * (a - b)
               for a, b in zip(Lshort[tail_lo:tail_lo + 200],
                               tone_h[tail_lo:tail_lo + 200]))
check("HOLD short returns toward dry",
      mid_res > 1000 and tail_res < mid_res // 4,
      f"mid_res={mid_res} tail_res={tail_res}")

for name in K:
    render(ramp[:FRAMES * 8], **{name: 64 if name not in ("MODE", "SYNC") else 1})
check("every named knob renders", True)
assert "CHNC" in K and "HOLD" in K and "REV" in K, f"knobs={sorted(K)}"
assert "JITR" not in K and "DECY" not in K and "FDBK" not in K, f"knobs={sorted(K)}"


def _rail_count(L, R):
    return sum(1 for x in L if abs(x) >= RAIL) + sum(1 for x in R if abs(x) >= RAIL)


def _energy(xs):
    return sum(x * x for x in xs)


# Max-knob / each MODE: ~3 s at 0.5 FS — rail samples must stay ~0 (Sam's
# dsp_host check on 4699a119: peak 0.50 FS, 0 rail hits).
N_LONG = int(3.0 * FS)
N_LONG -= N_LONG % FRAMES
drive = [int(0.5 * (1 << 23) * math.sin(2 * math.pi * 440 * i / FS))
         for i in range(N_LONG)]
max_kw = dict(SIZE=127, RATE=127, CHNC=127, HOLD=127, REV=127, MIX=127, SYNC=3)
for mode in range(4):
    Lm, Rm = render(drive, MODE=mode, **max_kw)
    rails = _rail_count(Lm, Rm)
    pk = max(max(abs(x) for x in Lm), max(abs(x) for x in Rm))
    check(f"max-knob MODE={mode} rails={rails} (==0)", rails == 0,
          f"peak={pk}")

# Two FX2 instances: each has energy and a non-trivial peak.
pair = render(tone + tone, inst=2, MIX=127, SIZE=40, RATE=120, CHNC=127,
              HOLD=100, MODE=0, REV=0)
for i, (Li, Ri) in enumerate(pair):
    e = _energy(Li[CLEAR:])
    pk = max(abs(x) for x in Li[CLEAR:])
    check(f"two-instance[{i}] energy ({e}) > dry/4", e > E_dry // 4)
    check(f"two-instance[{i}] peak ({pk}) > 1<<16", pk > (1 << 16))

# LFSR ($34): stuck-low (0) → REV mid always reverses (= REV 127); stuck-high
# (0x7f) → REV mid always forward (= REV 0). Working mid differs from both.
# Same idea for CHNC: low mid sits strictly between dry and always-on.
N_lfsr = CLEAR + 20000
tone_l = [int(0.3 * (1 << 23) * math.sin(2 * math.pi * 330 * i / FS))
          for i in range(N_lfsr)]
kw_base = dict(MIX=127, SIZE=40, RATE=120, HOLD=80, MODE=0, REV=0)
L0, _ = render(tone_l, CHNC=0, **kw_base)
L8, _ = render(tone_l, CHNC=8, **kw_base)
L127, _ = render(tone_l, CHNC=127, **kw_base)
e0 = _energy([a - b for a, b in zip(L0[CLEAR:], tone_l[CLEAR:])])
e8 = _energy([a - b for a, b in zip(L8[CLEAR:], tone_l[CLEAR:])])
e127 = _energy([a - b for a, b in zip(L127[CLEAR:], tone_l[CLEAR:])])
check("CHNC=8 residual between dry and always",
      e0 < e8 < e127 and e8 > e0 + 1000,
      f"e0={e0} e8={e8} e127={e127}")

Lrev0, _ = render(spike_in(16), SIZE=16, CHNC=127, HOLD=127, RATE=0, REV=0,
                  MIX=127, MODE=0)
Lrev64, _ = render(spike_in(16), SIZE=16, CHNC=127, HOLD=127, RATE=0, REV=64,
                   MIX=127, MODE=0)
Lrev127, _ = render(spike_in(16), SIZE=16, CHNC=127, HOLD=127, RATE=0, REV=127,
                    MIX=127, MODE=0)
check("REV=64 LFSR neither always-fwd nor always-rev",
      Lrev64 != Lrev0 and Lrev64 != Lrev127,
      f"eq0={Lrev64 == Lrev0} eq127={Lrev64 == Lrev127}")

# Grab-start walk at CHNC=127: short HOLD + RATE ticks on a tone — residual
# onsets should land at many absolute times (write head advances between grabs).
N_grab = CLEAR + 24000
tone_g = [int(0.25 * (1 << 23) * math.sin(2 * math.pi * 220 * i / FS))
          for i in range(N_grab)]
Lg, _ = render(tone_g, SIZE=8, RATE=110, CHNC=127, HOLD=8, MIX=127, MODE=0, REV=0)
thr = 1 << 18
res = [abs(a - b) for a, b in zip(Lg, tone_g)]
onsets = [i for i in range(CLEAR + 1, len(res))
          if res[i] > thr and res[i - 1] <= thr]
check(f"CHNC=127 grab onsets spread ({len(onsets)} onsets)",
      len(onsets) >= 8 and len(set(onsets)) == len(onsets),
      f"onsets={onsets[:12]}")

Lrnd, _ = render(spike_in(8), SIZE=8, CHNC=127, HOLD=127, RATE=0, REV=0,
                 MIX=127, MODE=3)
gaps_rnd = peak_gaps(Lrnd)[1]
cluster = set()
for g in gaps_rnd:
    if g <= 0:
        continue
    if abs(g - med(gaps_rnd)) <= 2:
        cluster.add("mid")
    elif g < med(gaps_rnd) - 2:
        cluster.add("short")
    else:
        cluster.add("long")
check("MODE=RND varies gap clusters",
      len(gaps_rnd) >= 4 and len(cluster) >= 2,
      f"gaps={gaps_rnd[:8]} clusters={cluster}")

if FAILS:
    sys.exit(f"verify_stuttr: {len(FAILS)} FAILED: {', '.join(FAILS)}")
print("verify_stuttr: OK")
