# Borrowed voicings: what the stations can take from JSFXClones and audiojs/filter

13 Sep 2026. Sam's question: can published algorithms make the stations
"right out of the box" the way Mutable's Clouds did for GRAIN? Two reads,
both MIT: [JClones/JSFXClones](https://github.com/JClones/JSFXClones) (JSFX,
clones of console/tape/tube processors and limiters) for CHARACTER, and
[audiojs/filter](https://github.com/audiojs/filter) (JS, ZDF ladders and
SVFs, a formant bank, resonators, tilt) for SPECTRUM. What is borrowed is
the curve or the law, re-derived under the gates; the code never runs here.
**Every word and cycle figure below is an estimate from reading**, marked so,
until the stage is built and priced.

## The rules that shape a port (the 56300 side)

- No per-sample division, log, exp, tan or tanh: each becomes a P-table
  (33 pairs interpolated, as Character's tables are) or moves to the
  per-block path, which has one real division.
- A sample-loop callee may contain no control transfer; forward skips in the
  loop body are priced as the worst path (`CYCLES_FORWARD_BRANCHES`).
- Lookahead needs delay memory an FX1 station has not got: limiters and
  maximizers are out.
- 2x oversampling doubles the cycle price. Nothing chosen below needs it.
- A stepped select cannot sit on page 1 (the schema refuses it): a
  page-1 control is a knob.

## CHARACTER from JSFXClones

Reference: today's saturator ≈ 170 words both channels, the compressor
≈ 150, 458 cycles/sample worst (before the TapeHead stage).

| stage | source | the law | port | cost (est) |
|---|---|---|---|---|
| **TAPE** | TapeHead | Chamberlin SVF at 2.1 / 3.7 / 5 kHz; `ss(v) = 1.5v − 0.5v³` clipped ±1 on the LP and BP bands, the HP band passed at −1.157; drive 0.8x..8x = `0.8·10^((D−1)/9)`; trim 0.7 | done 13 Sep: MODEFORK, TONE (page-1 slot 5, plain knob) sweeps the split 2.1→5 kHz, `k2` linear in TONE (0.5 % from the sine); error vs the float reference ≤ 7e-3 (2e-2 on noise at DRV 127, the drive table's interpolation) | −60 words |
| **TUBE** | DaTube | `x *= drive+0.5`; `y = x + (d/2)((1−x) − (1−x)^P)` for x>0, `x + d((1+x)^P − (1+x))` for x<0, P = ln10+1; 3 Hz DC remover | one table `T(u) = u − u^P`, sign selects d/2 vs d | +20 words |
| **INFL** (SAT's third slot; FUZZ dropped) | OInflator | `x *= 0.5`; `gr = clamp(2c·|x| + (1−c))`, `y = (1 − |gr·x|)(gr·x)·2e + (1−e)x`; ×2 | no table, no division; Effect on DRV | +50 words |
| **GLUE** | AC1 | level = |x| smoothed 0.5 ms / 500 ms; `gr = (Lv²/2 − 1)² + Lv·a`, `a = 0.75 − (Comp−1)·0.075`, clamp ≤ 1 | polynomial gain per sample, no table | −40 words |
| **COMP** | LMC1 | feedback console comp: sidechain HP 340 Hz → LP 4 kHz → ×gr → square → 2.5 / 25 ms smoother → √; hard knee, `gr = (L/thr)^−3.077` (≈4:1), −40 dB floor | the power per block: one division + a 33-entry table of r^−1.538 | +60 words |
| TRNS | ours | on trial (Sam) | | |

Blockers: TubeDriver (`t/(t+bias)`, a division per sample); the full SatBuss
(13 one-poles and a feedback mesh, ≈ +130 cycles); a reduced SatBuss
(the √2 squarer + the rational soft clip as a table + an 8 Hz DC block,
≈ +40 words) keeps its harmonic signature without the bloom, if ever wanted.
Net for TAPE + TUBE + INFL + GLUE: ≈ −55 words, ≈ +30 cycles/sample against
today's Character; + COMP ≈ +5 words.

## SPECTRUM from audiojs/filter

Reference: today's SVF core ≈ 13 words/channel, `f` capped at 0.977 (a
~7.2 kHz cutoff ceiling if `f = 2 sin(π fc/fs)` — inferred, not measured on
the unit); 322 cycles/sample, 861 words.

| candidate | the law | port | cost (est) | gives |
|---|---|---|---|---|
| **Oberheim SEM ZDF SVF** (linear) | per block `g = tan(π fc/fs)`, `R = 1 − res`, `d = 1/(1 + 2Rg + g²)`; per sample `hp = (x − (2R+g)s0 − s1)·d`, `bp = g·hp + s0`, `s0 = bp + g·hp`, `lp = g·bp + s1`, `s1 = lp + g·bp`; notch = hp + lp | replaces the SVF core one for one, same taps, MODE / mix / FM unchanged (FM as an offset on `g` with `d` frozen per block) | +8 words, +6 cycles | no cutoff ceiling, stable at any RES, resonance tracks fc, self-oscillation without the clamp |
| … with the state tanh | `s0 = tanh(s0)`, `s1 = tanh(s1)` | two lookups per channel + one 33-pair table | +120 words, +70 cycles | the SEM warmth: a bounded, warm resonance instead of a limiter clamp |
| **Formant bank** for VOWL | three parallel constant-peak resonators `y = b0 x + b2 x2 − a1 y1 − a2 y2`, `R = e^(−π bw/fs)`, `a1 = −2R cos w0`, `a2 = R²`, `b0 = (1−R²)/2`; /a/ = 730/1090/2440 Hz, bw 90/110/170, gains 1/0.5/0.3 | replaces the two-peak trick; 5 vowels × 3 formants × (a1, a2, b0) = 45 words of table with the existing FREQ morph; RES scales the bandwidths | +80 words, +40 cycles | named vowels with real F1/F2/F3; DRV/FM/ROUT keep meaning in VOWL |
| per-sample `f` ramp | `f += (fA_new − fA_old)/16` per sample | | +3 words, +2 cycles | removes the block-rate zipper on a fast sweep (measure it first: a CC 34 sweep, soloed, look for the ~2.8 kHz comb) |
| 2-shelf TILT on the blank slot 4 | two one-pole shelves at 250 Hz and 2.5 kHz, ± slope | | +20 words, +12 cycles | a tone knob; only if BASE/WDTH do not already cover it |
| Moog ladder as a MODE | ZDF 4-pole, `G = g/(1+g)`, `u = (x − k·S)·d`, `u = tanh(u·drive)`, four trapezoidal stages | +150 words, +70..90 cycles | 24 dB/oct, the Moog resonance, true self-oscillation | **blocked** at four Spectrums per core (+300 cycles against 194 headroom) unless it replaces the SVF or a ladder-mode Spectrum counts as heavy |
| diode ladder (303) | four state tanh + two tridiagonal solves per sample | ≈ +200 cycles | | **blocked** |
| 8-stage tilt | | +50 cycles | | blocked at four per core |
| Korg35, lone resonator, RBJ core | | | | low value; skip |

Net for the linear SEM + the formant bank + the ramp: ≈ +90 words,
+50 cycles/sample per Spectrum — four per core is +200, over the pricer's
194 headroom on the worst core, so the set waits on the pricer's
bsr-in-fork attribution fix and a re-price; the linear SEM alone is
affordable now.

## Order of work

Character first (TAPE done, TUBE + INFL in progress, then GLUE, COMP), one
flash, the live Character round. Then Spectrum: the linear SEM core and the
`f` ramp; the formant bank and anything heavier after the re-price.
