# `resonator` — RESONATOR

FX1 station: **4 pitched bandpasses** (Torso S-4 RING filterbank idea, not
a modal / Rings body). Wet is the input through four constant-peak bandpass
peaks. Per-band **GN** levels sit on page 1; pitches and **SCAL** (gain
scale) live on FX SETUP. SCAL 8 is the tame default (GN 64 = 0 dB); SCAL
127 restores build-TN smash headroom. DECY narrows the bands.

Buffer-free (state in r7). `Claims(fx1_only=True)`: FX2 instances dry-pass;
the FX2 chooser hides the row. FX id **`0x1e`**.

The page descriptor is cloned from **DARK REV**.

## Knobs

| page | slot | name | range | what it does |
|---|---|---|---|---|
| 1 | 0 | GN1 | 0–127 | band 1 level; 64=unity at SCAL 8 |
| 1 | 1 | GN2 | 0–127 | band 2 |
| 1 | 2 | GN3 | 0–127 | band 3 |
| 1 | 3 | GN4 | 0–127 | band 4 |
| 1 | 4 | DECY | 0–127 | high = longer ring / less drive |
| 1 | 5 | MIX | 0–127 | dry/wet; 127 = bands only |
| 2 | 6 | PIT1 | 0–127 | band 1 centre ~40 Hz … ~4 kHz |
| 2 | 7 | PIT2 | 0–127 | band 2 centre |
| 2 | 8 | PIT3 | 0–127 | band 3 centre |
| 2 | 9 | PIT4 | 0–127 | band 4 centre |
| 2 | 10 | SCAL | 0–127 | gain scale; 8=tame, 127≈build-TN |

## Stock 1.40C and a saved Part

Slots are DARK REV's layout under these names. A Part saved with RESONATOR
and loaded on stock 1.40C shows **DARK REV** with:

| slot | RESONATOR | stock DARK REV reads |
|---|---|---|
| 0 | GN1 | TIME |
| 1 | GN2 | SHVG |
| 2 | GN3 | SHVF |
| 3 | GN4 | HP |
| 4 | DECY | LP |
| 5 | MIX | MIX |
| 6 | PIT1 | PRE |
| 7 | PIT2 | BAL |
| 8 | PIT3 | MONO |
| 9 | PIT4 | (blank on stock) |
| 10 | SCAL | (blank on stock) |
| 11 | (blank) | MIXF |

Saving that bank on stock writes those DARK REV values back; keep a
separate project copy if you need to return to stock without rewriting
the Part.

## Measured

- Render gates in `tools/verify/verify_resonator.py` (incl. SCAL 8
  max-knob rail fraction < 5%, no-runaway on SCAL 127, two FX1
  instances).
- **SCAL 127 hard-clips** at ordinary input levels (`dsp_host`, 220 Hz
  tone, 3 s, one instance). Samples at the 24-bit rail:

  | case | peak | at rail |
  |---|---|---|
  | SCAL 127, GN1–4 / DECY / MIX 127, input 0.25 | 1.00 FS | 93.8% |
  | SCAL 127, other knobs default, input 0.25 | 1.00 FS | 88.7% |
  | SCAL 127, GN 64, MIX 127, DECY 127, input 0.1 | 1.00 FS | 83% |
  | SCAL 8, all other knobs max, input 0.25 | 1.00 FS | 1.5% |
  | defaults, input 0.25 | 0.30 FS | 0% |

  Late/early energy stays ~1.0 (no runaway). Prefer SCAL near 8 unless
  you want the smash.
- On hardware: Ilia's MKII, tip of PR #806 as **`RESON RR`** / BUILD RR,
  19 Oct 2026 — page-1 GN1–4, DECY low and high, MIX; page-2 PIT1–4;
  SCAL 8 and 127; FX2 dry-pass; two FX1 instances.

## Gates

`tools/verify/verify_resonator.py` (manifest `Gate`).

## Sources

- Torso S-4 RING — behaviour target (filterbank, not modal reverb).
- JOS two-zero constant-peak bandpass / Spectrum VOWL form (MIT).
