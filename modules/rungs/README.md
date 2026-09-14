# Rungs

A Rings-flavoured modal resonator insert: the track's audio excites a bank of
eight two-pole resonators tuned to a partial series. Per-track insert: no bus
role, both payloads, any track. In the `mutables` remix.

## Knobs

| slot | name | what |
|---|---|---|
| p0 | FREQ | fundamental ~55 Hz–1.25 kHz, squared taper |
| p1 | STRC | stretches the partial series sharp, more per higher mode |
| p2 | DAMP | ring time T60 ~0.1–9 s |
| p3 | MIX  | dry/wet; 0 = exact passthrough |
| p7 | MODE | STRING (harmonic) / BELL / GLASS (stretched) |

Mode frequencies are computed per block from the knobs; cos from a half-angle
polynomial, ~0.2 % tuning error at the extremes (measured).

## Status

Assembles, disassembly-audited, rendered locally: MIX=0 bit-exact, mode ring
frequencies measured against the ratio tables, decay time tracks DAMP. Never
flashed.

## Open

- DAMP is spent linearly on the coefficient, so most of the useful decay
  range sits in the last steps (Streamz's FALL uses a cubic taper instead).
- FREQ could track the held MIDI note the tempo-sync cave publishes.
