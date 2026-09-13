#!/usr/bin/env python3
"""MODULATION render gates -- and the FX1-ONLY PROMISE.

The station takes a per-track line from the host's bump allocator, which is
only safe in an FX1 slot: every FX2 instance buffer is a server's ground.
`Claims(fx1_only=True)` is the promise that an FX2 instance writes nothing,
and the ledger admits the module beside a server on that basis -- so the
first two gates here are what that claim rests on.

Gates:
  FX1 instance  -> MIX=0 is a bit-exact passthrough; every mode renders
  FX2 instance  -> bit-exact DRY at any setting, in every mode
  FX2 instance  -> dsp_host's -guard sees NO write outside the frame
  LFO           -> the sweep rate follows RATE (measured on the wet)
  CHOR          -> the line is really read: an impulse comes back delayed
  the LFO       -> measured on CHOR at MIX 127 (vibrato): the modulation of
                   the tone's period follows RATE, and SHPE changes the render
  (PHSR / TREM / VIB / PAN retired 13 Sep 2026)
  every knob    -> renders without dsp_host dying

    python3 tools/remix/audition.py modulation out/dry/drums_110.wav
    python3 tools/verify/verify_modulation.py
"""
import math, pathlib, struct, subprocess, sys

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parents[1])); import toolpath  # noqa: E402,F401  (every tools/ dir on sys.path)
import send_probe  # reuse its dispatch-table entry resolution
from remix import registry

MOD = registry.by_name("modulation")
SEND = registry.by_name("send")
K = MOD.knob_map()
MEM = f"out/dsp/_audition_{MOD.name}_A.mem"
HOST = "vendor/dsp56300/build/source/dsp_host/dsp_host"
FXID = MOD.menu.fx2_id
FRAMES, N = 15, 6000
SR = 44100
TMP = pathlib.Path("out/_mogate")
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
    channels (verify_hello's shape). Returns (L, R) lists."""
    src = TMP / "mo_in.raw"
    src.write_bytes(b"".join(struct.pack("<i", m) for m in samples))
    out = TMP / "mo_out.raw"
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


MODES = {"CHOR": 0, "FLNG": 1, "COMB": 2}     # PHSR/TREM/VIB/PAN retired 13 Sep 2026

# ---- 1. FX1: MIX=0 is a bit-exact passthrough in every mode ------------------
ramp = [int(round(-8388607 + 2 * 8388607 * i / (N - 1))) for i in range(N)]
ok = True
for name, m in MODES.items():
    L, R = render(ramp, MODE=m, MIX=0)
    if L != ramp or R != ramp:
        ok = False
        check(f"FX1 MIX=0 passthrough in {name}", False,
              f"first diff at {next(i for i,(a,b) in enumerate(zip(L,ramp)) if a!=b)}")
check("FX1: MIX=0 is a bit-exact passthrough in all three modes", ok)

# ---- 2. THE FX1-ONLY PROMISE: an FX2 instance is dry, whatever the knobs -----
ok = True
for name, m in MODES.items():
    L, R = render(ramp, slot="fx2", MODE=m, MIX=127, DPTH=127, FDBK=100, RATE=90)
    if L != ramp or R != ramp:
        ok = False
        check(f"FX2 instance is dry in {name}", False, "it processed the frame")
check("FX2 instance is a bit-exact DRY PASS in all three modes, at any setting",
      ok)

# ---- 3. ... and it writes nothing outside the frame --------------------------
render(ramp, slot="fx2", guard=True, MODE=0, MIX=127, DPTH=127, FDBK=100)
# dsp_host prints "guard armed: ..." on arming and "guard clean: ..." when
# nothing was written over a loaded module; a violation prints neither.
g = getattr(render, "guard_out", "")
check("FX2 instance trips no write guard (it never touches the line)",
      "guard clean" in g,
      next((ln.strip() for ln in reversed(g.splitlines()) if "guard" in ln), ""))

# ---- 4. the LFO rate follows RATE -------------------------------------------
# Measured on CHOR at MIX 127 (the wet alone = vibrato) on a tone: the LFO
# modulates the tap, so the tone's instantaneous period wobbles at the LFO
# rate. Count the wobble's cycles from the sequence of zero-crossing periods.
# (Until 13 Sep 2026 this read the LFO straight off TREM on a DC input; TREM
# is retired.)
LONG = 30000
def periods(rate, shpe=0):
    """the tone's instantaneous period, cycle by cycle, from sub-sample
    (linearly interpolated) rising zero crossings, smoothed over 4 cycles"""
    L, _ = render(tone(438, n=LONG), MODE=0, MIX=127, DPTH=127, RATE=rate, SHPE=shpe, DLY=60)
    seg = L[LONG // 4:]
    zc = [i + a / (a - b) for i, (a, b) in enumerate(zip(seg, seg[1:])) if a < 0 <= b]
    per = [b - a for a, b in zip(zc, zc[1:])]
    return [sum(per[i:i + 4]) / 4 for i in range(0, len(per) - 4)]
def wobble_cycles(per):
    if len(per) < 8:
        return 0.0
    mid = sum(per) / len(per)
    # ignore crossings inside a +-0.05-sample dead band around the mean
    st, n = 0, 0
    for v in per:
        if v > mid + 0.05 and st != 1: n += 1; st = 1
        elif v < mid - 0.05 and st != -1: n += 1; st = -1
    return n / 2
slow_p, fast_p = periods(20), periods(110)
slow_n, fast_n = wobble_cycles(slow_p), wobble_cycles(fast_p)
check("the LFO is square-law in RATE: the top of the knob wobbles the pitch many times more than the bottom",
      fast_n > slow_n * 4 and fast_n > 2,
      f"RATE 20 -> {slow_n:.1f} wobble cycles in 0.68 s, RATE 110 -> {fast_n:.1f}; "
      f"period swing {max(fast_p) - min(fast_p):.2f} samples at RATE 110")

# ---- 4b. the shapes are four, not three (3 Sep 2026: SAW fell through to TRI)
# the same vibrato at RATE 60 in each shape. A SQR steps the tap, so its
# period sequence has abrupt jumps where TRI's ramps; SIN and SAW differ from
# TRI and from each other in the sequence itself -- rendered, not inferred.
tri, sin_, sqr, saw = (periods(60, i) for i in (0, 1, 2, 3))
def biggest_step(per):
    return max(abs(a - b) for a, b in zip(per, per[1:])) if len(per) > 1 else 0.0
check("SHPE: TRI, SIN, SQR and SAW render four distinct modulations, and SQR steps where TRI glides",
      tri != sin_ and tri != saw and sin_ != saw and biggest_step(sqr) > 2 * biggest_step(tri),
      f"biggest period step: TRI {biggest_step(tri):.2f} SIN {biggest_step(sin_):.2f} "
      f"SQR {biggest_step(sqr):.2f} SAW {biggest_step(saw):.2f} samples")

# ---- 5. the line is really read: an impulse comes back delayed ---------------
imp = [0] * N
imp[100] = 6000000
L, _ = render(imp, MODE=0, MIX=127, DPTH=0, DLY=60, RATE=0)   # CHOR wet only, no sweep
late = [i for i, v in enumerate(L) if abs(v) > 100000 and i > 110]
check("CHOR at MIX 127 reads the line: the impulse comes back later", bool(late),
      f"first echo at sample {late[0] - 100} after the input" if late else "no echo")

# ---- 6. a stored MODE past 2 (an old part's PHSR/TREM/VIB/PAN) runs CHOR ----
chor, _ = render(tone(438), MODE=0, MIX=127, DPTH=90, RATE=30)
for old in (3, 4, 5, 6):
    L, _ = render(tone(438), MODE=old, MIX=127, DPTH=90, RATE=30)
    check(f"MODE {old} (retired) renders as CHOR, bit-exact", L == chor)

# ---- 7. COMB rings: feedback lengthens an impulse -----------------------------
L0, _ = render(imp, MODE=2, MIX=127, DPTH=0, DLY=20, FDBK=0, RATE=0)
L1, _ = render(imp, MODE=2, MIX=127, DPTH=0, DLY=20, FDBK=120, RATE=0)
def last_loud(x): 
    idx = [i for i, v in enumerate(x) if abs(v) > 50000]
    return idx[-1] if idx else 0
check("COMB: feedback makes the impulse ring longer", last_loud(L1) > last_loud(L0) + 200,
      f"last loud sample FDBK 0: {last_loud(L0)}, FDBK 120: {last_loud(L1)}")

# ---- 8. every knob at its extremes renders ----------------------------------
for name in K:
    for v in (0, 127 if MOD.params[K[name]].count in (None, 128) else MOD.params[K[name]].count - 1):
        render(tone(438, n=600), **{name: v})
check("every knob at both extremes renders", True)

print(f"\n{fails} gate(s) failed" if fails else "\nOK")
sys.exit(1 if fails else 0)
