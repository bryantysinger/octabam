# `shatter` — SHATTER

A per-track crush insert: drive into a wavefolder, hard or soft clip,
combined bit-depth and sample-rate crush, then a feedback loop with a tone
shelf. MODE CHAOS flips feedback polarity from a free-running ramp so the
loop self-modulates into hash and dropouts. MIX 0 is bit-exact dry.

Sits beside CHARACTER (channel-strip dirt) and LOFI2 (modulator + SRR/BRR):
this one is self-modulating destruction.

## Knobs

| page | slot | name | range | what it does |
|---|---|---|---|---|
| 1 | 0 | DRV | 0–127 | pre-gain (~×9 / +19 dB at 127) on dry only; 0 = unity |
| 1 | 1 | FOLD | 0–127 | wavefolder; 0 = unity (skip); 1…127 only increases fold drive |
| 1 | 2 | CLIP | 0–127 | clip amount (0 open, 127 brick) |
| 1 | 3 | CRSH | 0–127 | bit + sample-rate crush |
| 1 | 4 | FDBK | 0–127 | feedback around the crush path |
| 1 | 5 | MIX | 0–127 | dry/wet; 0 = exact passthrough |
| 2 | 6 | MODE | HARD / SOFT / CHAOS | clip flavour; CHAOS flips FDBK polarity |
| 2 | 7 | TONE | 0–127 | feedback shelf |
| 2 | 8 | RATE | 0–127 | CHAOS flip rate |

**DRV 127 clips at ordinary input levels** (dsp_host: 0.25 FS tone → ~35% of
samples at the 24-bit rail). Keep DRV down, or follow with CLIP, when the
source is already hot.

Page-2 MODE/TONE/RATE are easiest to hear with CLIP open and FDBK up
(CLIP 100 bricks the path so HARD≈SOFT and CHAOS is easy to miss).

## Storage and stock firmware

The page descriptor is cloned from **DARK REV**. A Part saved with SHATTER
keeps FX id `0x0a` and the nine page bytes. Stock 1.40C has no effect on
that id (it aliases to NONE in a stock chooser). If the same page bytes are
loaded under DARK REV, they read as DARK's knobs:

| our slot | our name | stock DARK |
|---|---|---|
| 0–5 | DRV…MIX | TIME, SHVG, SHVF, HP, LP, MIX |
| 6 | MODE (0–2) | PRE |
| 7 | TONE | BAL |
| 8 | RATE | MONO |

Keep a separate project copy, or re-select effects and save, before going
back to stock.

## Measured

Local render gates (`verify_shatter`). DRV is dry-only (~×9 at 127);
feedback is not driven. LFO-dirty page words are masked before use.
DRV 127 at 0.25 FS hits the rail (~35% of samples); the gate asserts a
rail-fraction band on that case (and on max-knob / two-instance).
Page 2 reads MODE/TONE/RATE from `$c`/`$d` (PARAM_PAGES section 6); an
earlier `$6/$7/$8` read left those knobs dead on the unit — gated now.

**Instances per core** (two-instance-gate knobs: DRV 100, FOLD 90, CLIP 40,
CRSH 40, FDBK 40, MIX 127, MODE HARD, TONE 64, RATE 64):

| source | one instance | four on one core |
|---|---|---|
| `dsp_host -meter` | 186 instructions/sample | 743 instructions/sample |
| `cycle_count.py` (static) | 213 cycles/sample | 852 cycles/sample |

Four FX2 slots per core; 852 ≪ 3120 usable (`cycle_count` USABLE). All four
slots fit at those settings. Same order at `Module.dear` (~187 /sample).

## On the unit

Ilia's MKII, 21 Oct 2026, remix `shatter` **BUILD S6** (`SHATTER S6.RMX`,
tip DSP including `v*(1+8*FOLD)` and page-2 `$c`/`$d` reads): every
page-1/page-2 knob exercised (DRV, FOLD, CLIP, CRSH, FDBK, MIX, MODE,
TONE, RATE). MODE/TONE/RATE confirmed with CLIP open and FDBK up.

Earlier report image remix `glitch` BUILD G4 from `c1ea1c53` (19 Oct;
SHATTER+STUTTR, old FOLD path) is superseded for this tip.

No build tag on the panel.

## Open

- CHAOS voicing: RATE curve and polarity-flip energy
- Whether CRSH should split into separate BRR / SRR knobs

## Gates

`tools/verify/verify_shatter.py` (manifest `Gate`): MIX 0 bit-exact;
DRV+FOLD both signs; FDBK raises energy; CHAOS non-silent; HARD vs SOFT /
TONE / RATE page-2 diffs; max-knob rail fraction + no runaway; DRV 127
rail-fraction band; two instances.
