# BusDelay

A multi-mode delay: CLEAN, GRAIN (a pitched granular cloud over the delay
lines: Nimbus's grain readers, four per line, one continuous pitch) and
REVERSE, with tape wow (MDEP / MRAT) and a freeze hold in every mode. Hosted
on payload B (core 1), which serves tracks 1–4. Stage 1 of the one aux bus:
its output goes on to BusVerb and to the return.

TIME is a free dial with a sticky snap: near a division it snaps, holds that
division through tempo changes, and lets go when the knob moves. The tempo
is stock's record word (tempo24 at `r6+$13`, halfword 31 of every track's
record); the MIDI-clock period is derived per block on the DSP (24-step
`div`, `y:$090d`). The held MIDI note arrives from the
[`tempo-sync`](../tempo-sync/) note cave at `r6+$1` bits 8-15; the panel
label comes from its formatter cave.

## Knobs

| | CLEAN | GRAIN | REVERSE |
|---|---|---|---|
| page 1: SEND · TIME · FDBK · TONE · PING · WET | the same everywhere | | |
| MODE (p6) | CLEAN | GRAIN | REVRS |
| MDEP (p7) | wow depth | SCAT: how far apart the grains read | wow depth |
| MRAT (p8) | wow rate, 64 = 1× | DENS: density, level-flat | wow rate |
| SIZE (p9) | unused | grain length 46 / 93 / 23 ms, XTRM 186 ms | segment; XTRM = 371 ms |
| PTCH (p10) | no effect | ±2 oct, 64 = unison; a held MIDI note overrides | no effect |
| FRZE (p11) | hold | hold (the grains keep grazing) | hold |

Each mode's `ModeView` re-defaults the knobs and renames MDEP/MRAT in GRAIN.
PING 0 and MDEP 0 by default: an aux delay sits still; the bounce and the
wow are the knobs'. In REVERSE the two 16K lines are one 32K mono ring
(XTRM = 16,384 samples = 371 ms, the mode's default), PING is forced off and
the output is mono to both channels.

## Local rendering

`dsp_host` renders payload B only under `rig_render.py` (both cores); the
DEV hatch (`make render-delay`) places the delay out of region in payload A.
`DFRZAT=n` engages FREEZE after n blocks.

## Measured

- CLEAN and REVERSE bit-identical across the `verify_delay` cases (defaults,
  PING 0/127, TIME 0/127, FDBK+TONE, split, WET 0, wow, the unknown-mode
  fallback); `verify-bus` 21/21.
- GRAIN DC gate (0.25 FS DC, full density, unison): p-p 0 across scatter
  0/64/127 and every size (four windows a quarter period apart sum to
  exactly 2).
- GRAIN pitch (438 Hz tone, 93 ms grains, TIME 127): PTCH 64 → 438.7 Hz;
  96 → 869.4 (876 expected); 32 → 223.4 (219); 48 → 309.5 (310); 127 → 1709
  (1714). MIDI note 96 → 869.4, 91 → 654.1, 72 → 223.4. Below about −1.5
  octaves the finder reads 10–25 % low (note 60 → 94 for 110): finder or
  engine, unverified. 186 ms grains at TIME 100 clamp PTCH 127 to 2.5×.
- GRAIN density law (0.5 FS tone, 93 ms): −14.6 / −11.2 / −10.7 / −11.3 /
  −12.0 dBFS at DENS 0/32/64/96/127; GRAIN's peaks sit level with CLEAN's
  (RMS ~4 dB under).
- PING at FDBK 60: 0 mono (L/R correlation 1.000), 32 / 64 near-mono (0.998
  / 0.965), 96 / 127 the bounce (0.73 / 0.01); 127 leans +4.4 dB left (L
  gets repeats 1, 3, 5: L/R = 1/feedback).
- REVERSE at 371 ms: a 50 ms burst comes back reversed ~300 ms later; the
  sine is continuous at every size.
- Cost: 2,151 words; worst path 1,757 cycles (GRAIN, rolled).

On Sam's unit in every rig flash. Heard: REVERSE 371 ms over 93 ("the long
one is better"); GRAIN DENS 32 → 127 on the loop "sounds pretty good".

## Open

- REVERSE's segment ceiling is 371 ms (the whole 32K ring).
- Pitch accuracy below −1.5 octaves: finder or engine.
- The delay return is ~4 dB quieter than the reverb at equal send.
