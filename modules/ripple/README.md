# Ripple

A Ripples-flavoured resonant filter insert: a Chamberlin state-variable
filter with a drive stage in front, LP/BP/HP select, resonance to Q≈30. Per-
track insert: no bus role, both payloads, any track, several at once. In the
`mutables` remix.

## Knobs

| slot | name | what |
|---|---|---|
| p0 | FREQ | cutoff ~24 Hz–7.2 kHz, squared taper (the SVF's stable region) |
| p1 | RES  | resonance; 127 ≈ Q 30, short of self-oscillation |
| p2 | DRV  | input gain 1–4×, clipped at the rail |
| p3 | MIX  | dry/wet; 0 = exact passthrough |
| p7 | MODE | LP / BP / HP |

## Status

Assembles, disassembly-audited (every `mpy` signed), rendered through
`dsp_host`: MIX=0 bit-exact, LP/HP slopes and the BP/resonant peak measured
against prediction. Never flashed.
