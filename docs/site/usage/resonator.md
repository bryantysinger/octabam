Four pitched bandpasses on the input (Torso S-4 RING–style filter bank).
Not a reverb or modal body: wet tracks the dry through four peaks.

## Access

FX1 only: select the track, press FX1, and pick RESONATOR. The FX2 chooser
does not list it (id 0x1e); an FX2 instance is a dry pass.

![FX1 SETUP with RESONATOR: PIT1–4 and SCAL.](../../img/resonator/setup.png)

*FX1 SETUP with RESONATOR: PIT1–4 and SCAL.*

## Operation

- GN1–GN4 set each band’s relative level (64 = unity when SCAL is 8).
- PIT1–PIT4 set each band centre (~40 Hz to ~4 kHz).
- SCAL on FX SETUP is the overall gain scale: 8 = tame, 127 ≈ the hot
  build-TN makeup (~×16 at GN 64). SCAL 127 hard-clips on ordinary
  input levels (most samples at the rail); stay near 8 unless you want
  that smash.
- DECY high = narrower peaks / more bite (still short — not a reverb tail).
- MIX 127 = bands only; MIX 0 = exact passthrough.

## Parameters

![RESONATOR main page: GN1–4, DECY, MIX.](../../img/resonator/main.png)

*RESONATOR main page: GN1–4, DECY, MIX.*

| Knob | Range | Default | What it does |
|---|---|---|---|
| GN1 | 0..127 | 64 | band 1 level |
| GN2 | 0..127 | 64 | band 2 level |
| GN3 | 0..127 | 64 | band 3 level |
| GN4 | 0..127 | 64 | band 4 level |
| DECY | 0..127 | 127 | resonance / bandwidth |
| MIX | 0..127 | 127 | dry/wet; 127 = bands only |
| PIT1 | 0..127 | 32 | band 1 centre |
| PIT2 | 0..127 | 48 | band 2 centre |
| PIT3 | 0..127 | 64 | band 3 centre |
| PIT4 | 0..127 | 80 | band 4 centre |
| SCAL | 0..127 | 8 | gain scale; 8=tame, 127≈build-TN |
