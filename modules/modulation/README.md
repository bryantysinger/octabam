# MODULATION

A modulation pedal on stock CHORUS's id 0x12, FX1 only. Every mode is a
transcription of a published, permissively licensed source; the survey,
licences and laws are in `docs/effects/PORTS.md`.

| page 1 | RATE · DPTH · FDBK · MIX · TONE · WDTH |
|---|---|
| page 2 | DLY · MODE (JUNO DIM ENS FLNG COMB PHSR) |

| mode | source | licence | what it is |
|---|---|---|---|
| JUNO | jpcima `HeraChorus.dsp` + pendragon-andyh's Juno-60 measurements | ISC | two BBD lines on one triangle LFO, R inverted; I 0.513 Hz / II 0.863 Hz over 1.5..5.4 ms; I+II 9.75 Hz mono; dry 0.83 + wet 1.0 |
| DIM | Roland SDD-320 service notes + measurements | laws | antiphase lines, the other side's wet through a highpass, a bass lift on the dry; 0.25 / 0.5 Hz, 5..12 ms. The amounts (0.25 same-side, −1 cross, 0.5 lift, 200 Hz one-poles) are unpublished: **ours** |
| ENS | jpcima `string-machine` (the Solina) | BSL-1.0 | three taps on one mono line, two three-phase LFOs (0.6 + 6 Hz, equal depth), 5 ± 1 ms; L = t1 + t2 − t3, R = t1 − t2 − t3 |
| FLNG | Dattorro, *Effect Design Part 2* (JAES 1997), Table 6 | paper | blend 0.7071 of the dry read from a FIXED tap at the sweep's centre, feedforward −0.7071 of the swept tap (through-zero: the sweep crosses the dry and nulls), feedback −0.7071 |
| PHSR | ChowPhaser (Schulte Compact Phasing A) | BSD-3 | two RC allpasses (15 nF) with feedback, then 2/4/6/8 allpasses (25 nF) on one coefficient from the LDR's law (`R = 100k (light/0.1)^-0.75`, light = 20.1 − 20·lfo); the coefficient decoded per block from two 33-word tables and ramped per sample; the feedback closes through one sample; no tanh |
| COMB | Mutable Instruments Rings `string.h/.cc` | MIT | a Hermite-read loop tuned by DLY, a 3-tap FIR damping filter (brightness = TONE), the per-pass gain from a DECAY TIME (rt60 = 0.07 s · 2^(8·lf), lf = d(2−d)) so every pitch rings for the same time; no IIR damping (the MIC_W build's omission), no dispersion. FDBK's sign is the polarity: **ours** |

Every mode outputs the wet only and MIX blends, so MIX 0 is an exact
passthrough and MIX 127 the wet outright.

## The knobs

| knob | law | in the modes |
|---|---|---|
| RATE | (k/128)² · 0x780 + 0x10 per sample in 2^23rds of a cycle: 0.08..10 Hz; 26 = 0.5 Hz | the LFO everywhere; ENS's fast LFO is 10× |
| DPTH | 480 · k/128 samples either side of DLY, clamped inside the line (≤ DLY − 8, ≤ 1015 − DLY) | the sweep; in PHSR the LFO's reach into the LDR's law (0..1) |
| FDBK | bipolar, (k − 64)/64 | feedback from the swept tap into the line; the phaser's regen (clamped ±0.95); COMB's decay time (size) and polarity (sign) |
| MIX | k/128, 127 = 1.0 | |
| TONE | one-pole 0.25 + 0.75 · k/128, 127 = 1.0 (exact bypass); 0 = 2 kHz | the BBD proxy in AND out of every line (the Juno's ~10 kHz filters at 80); COMB's FIR brightness; inert in PHSR |
| WDTH | the right channel's LFO lag, (k/128)/2 of a cycle: 0 mono, 64 quadrature, 127 antiphase | the Juno's and the Dimension's are antiphase; inert in ENS (three fixed phases) and COMB |
| DLY | 8 + 992 · k/128 samples (0.2..23 ms), capped 1000 | the centre; MANL in FLNG; the pitch in COMB (a 33-word table, 1000..8 samples exponential = 44 Hz..5.5 kHz); STGS in PHSR (2/4/6/8 by quarters) |

Each mode's ModeView re-defaults the knobs to its source's numbers (the
Juno's I, the Dimension's mode 1, the Solina, Dattorro's flanger,
ChowPhaser's, Rings at a mid pitch).

## Structure

Four sample loops, one chosen per block (the pricer takes the worst): LINE
(JUNO, DIM and FLNG share it — the three differ only in five per-block
mix weights `bl bd ff kc kb`), ENS, PHSR, COMB. Straight-line callees:
`mo_tap` (the linear read, blending toward the older sample), `mo_herm`
(the 4-point Hermite read, scaled 1/16 inside), `mo_apst` (one allpass
stage), `mo_para` (the parabola sine), `mo_lfo`, `mo_tab` (the table
read), `momixs`. The PHSR chain runs at half scale for headroom (an
allpass cascade peaks above its input).

PHSR is the last MODE position so that dropping it would move no other
mode's stored byte; whether it stays is undecided (476 cycles).

Two lines of 1,024 words from the FX1 slot's allocator buffer; an FX2
instance reads its base at init and runs as a dry pass (`Claims(fx1_only)`,
proven by the gates). A change of MODE clears every state slot.

## Measured

- **1,199 words**, core A FREE 536 in the rig; **476 cycles/sample** worst
  (PHSR 476; LINE 401, ENS 440, COMB 306) — under Character's 639, so the
  worst core is unchanged at 3,831.
- `tools/verify/verify_modulation.py`, **24 gates, all PASS**: MIX 0
  bit-exact in every mode; an FX2 instance a bit-exact dry pass with the
  guard clean; every mode against `modulation_ref.py` on a stereo signal
  (max error ≤ 1e-4 where the law is linear; COMB's ring recirculates its
  rounding, 5.5e-4 against a 3e-3 bar); the Juno's sweep 1.56..5.10 ms and
  0.5 Hz; the through-zero null −138 dB; the phaser unity at FDBK 64; the
  comb's period at three pitches.

- The LFO's increment is an integer count of 2^-23 cycles (the mpy keeps
  the integer part); the reference models that (a float increment drifts
  2.5 % at RATE 14).
- MIX 127 and TONE 127 are pinned to 1.0 so the through-zero null and the
  flanger's blend are exact (the knob word alone is 127/128).

## Open

- Unheard on the unit; unflashed. Kits for the ear in `out/ab/mod2_pad`
  and `out/ab/mod2_loop` (`tools/harness/abkit.py`, the six modes at their
  defaults, level-matched). Active-RMS level against JUNO's (MIX 70) before
  matching: DIM +6 / +10 dB (pad / loop), ENS +5 / +7, FLNG +5 / +10, COMB
  +23 / +6 (a 1 s ring resonates a sustained pad's harmonics by up to
  1/(1 − g) ≈ +37 dB), PHSR −0.5 / +5.
- DIM's amounts are ours; the Juno's own asymmetry (R 1.51..5.40 ms vs L
  1.54..5.15) and the I+II shape ("sine-like") are not modelled.
- The tap read is linear (Dattorro's allpass or Airwindows' 3-point + air
  are the alternatives, `docs/effects/PORTS.md`).
- Stored parts: TONE moved from slot 8 to 4 and WID from 10 to 5; SHPE and
  STGS are gone. `stamp-defaults` before play.
