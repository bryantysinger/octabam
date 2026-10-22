# `void` — VOID

Replaces **COMB FILTER** (FX2 id `0x13`, `replaces="COMB FILTER"`). In any remix
that carries VOID, COMB is off the FX chooser; a Part saved with stock COMB
opens without that effect (re-pick VOID or stamp defaults). Code sits in
harvested **PLATE REV** words.

Grit: track input blended with white / pink / brown noise,
amplitude-modulated by an audio-rate LFO, then a mild HP/LP body and a soft
clip. **FDBK** recirculates the post-clip sample into the drive (one-sample
loop). Always wet — there is no dry/wet MIX.

r7 `$40..$4f` stays reserved for a longer FEED delay later.

## Knobs

| page | slot | name | range | what it does |
|---|---|---|---|---|
| 1 | 0 | BAL | 0–127 | input↔noise; **0 = full input (default)**, 127 = full noise |
| 1 | 1 | RATE | 0–127 | LFO rate, expo 2 Hz … 200 Hz |
| 1 | 2 | SHPE | SIN / SQR / SAW | LFO shape |
| 1 | 3 | DPTH | 0–127 | AM depth; 0 = source alone |
| 1 | 4 | DRV | 0–127 | soft-clip after AM+body+FDBK; 0 = bypass |
| 1 | 5 | FDBK | 0–127 | one-sample feedback into DRV; 0 = off |
| 2 | 6 | COLR | 0–127 | body low-pass ~30 Hz..16 kHz; 127 = open — **turn down to darken** |
| 2 | 7 | HPF | 0–127 | high-pass before COLR ~20 Hz..8 kHz; **0 = bypass, turn up to thin** |
| 2 | 8 | NTYP | WHT / PINK / BRWN | noise colour (as BAL rises) |

Noise peaks around −6 dB at BAL=127. High FDBK + DRV screams (AC feedback —
a raw one-sample loop was railing to DC / silence past ~FDBK 50 with drive).

SETUP top row: COLR · HPF · NTYP.

## Storage and stock firmware

The page descriptor is cloned from **DARK REV** (`donor_desc=0x400d58b8`).
VOID keeps COMB's id (`0x13`) but not COMB's knob layout — page bytes from a
COMB Part will not match VOID's names.

If the same page bytes are loaded under DARK REV, they read as DARK's knobs:

| our slot | our name | stock DARK |
|---|---|---|
| 0 | BAL | TIME |
| 1 | RATE | SHVG |
| 2 | SHPE (0–2) | SHVF |
| 3 | DPTH | HP |
| 4 | DRV | LP |
| 5 | FDBK | MIX |
| 6 | COLR | PRE |
| 7 | HPF | BAL |
| 8 | NTYP (0–2) | MONO |
| 9–10 | (blank) | (blank) |
| 11 | (blank) | MIXF |

Saving on stock with DARK selected writes DARK's names into those slots; the
bytes are the same width. Keep a separate project copy, or re-select effects
and save, before going back to stock.

## Measured

- `verify_void.py`: passthrough; AM / FDBK vs `void_ref.py`; NTYP pink/brown
  diverge from white; COLR closed vs open; FDBK+DRV not DC-silent; max-knob
  true 3 s with rail-hit budget; two FX2 instances each have energy and stay
  off the rail.
- Hardware **VOID V9** (21 Oct 2026, tip `dd89e2e2`+): BRAIN `VOID V9.RMX` —
  same `void.asm` as V8, COLR 30 Hz..16 kHz / HPF 20 Hz..8 kHz tables. V8 did
  **not** have these tables (still 200 Hz / 2 kHz). See test-remix README for
  the full knob report.
- Earlier: **V7** handoff (`y0` mpy); **V8** signed `y1` mpy, old coef tables.

## Sources

- Carrier: WarpFold-style parabola (LOFI2 RING family).
- Pink: Paul Kellet economy; brown: one-pole leaky integrator.
