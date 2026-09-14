# WarpFold

A Warps-flavoured ring modulator / wavefolder. Per-track insert: no bus role,
no shared-window buffers, both payloads, any track, several at once; all
state in the instance's r7 block. In the `mutables` remix.

## Knobs

| slot | name | what |
|---|---|---|
| p0 | DRV  | fold drive, 1–7.9×; 0 = the folder is an identity |
| p1 | FREQ | ring carrier ~5 Hz–2.95 kHz, squared taper |
| p2 | TONE | one-pole lowpass on the wet; 127 ≈ transparent |
| p3 | MIX  | dry/wet; 0 = exact passthrough |
| p7 | MODE | FOLD / RING / BOTH (fold, then ring the folded signal) |

## Status

Assembles in both payloads, disassembly-audited (every `mpy` signed, no
label-prefix hazards), rendered through `dsp_host`: MIX=0 null, DRV=0 FOLD
null, RING sideband placement and fold harmonics measured. Never flashed.

## Open

- Voicing by ear (fold curve steepness, carrier shape) once heard on hardware.
- Warps' crossfade / analog drive model are not implemented.
