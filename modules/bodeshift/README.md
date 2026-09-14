# BodeShift

A Warps-flavoured Bode frequency shifter: every partial moves by the same
number of hertz. A ring modulator produces both sidebands; this cancels one
with a Hilbert pair of allpass chains. Per-track insert, no buffer. In the
`mutables` remix.

## Knobs

| slot | name | what |
|---|---|---|
| p0 | FREQ | shift 0–1000 Hz, squared taper |
| p1 | FINE | 0–20 Hz added linearly |
| p2 | FDBK | shifted output back into the input; partials spiral up or down |
| p3 | MIX  | dry/wet; 0 = exact passthrough |
| p7 | MODE | UP / DOWN / WIDE (up on L, down on R) |

## Status

Assembles (391 words), disassembly-audited, rendered locally and measured
against a float model:

- MIX=0 bit-exact passthrough; wanted sideband at unity gain.
- Sideband suppression on the DSP: 41.5 dB at 440 Hz, 29.6 dB at 1 kHz,
  18.7 dB at 5 kHz (float model 40.8 / 29.2 / 18.6).
- Shift frequency: 0.00 Hz error at FREQ 30 / 60 / 90 / 127; FINE alone
  measures 20.0 Hz.
- WIDE: the left channel carries the upper sideband at −44 dB with the lower
  at −85; the right channel is the mirror.
- Feedback stable at maximum: 0.95 FS in at FDBK 127 holds a 1.000 FS peak
  for three seconds. The loop settles at 0.5/(1−fdbk), fdbk < 0.5.

Never flashed.

## Open

- The residual opposite sideband rises with frequency (~19 dB down at
  5 kHz): the cost of an 8-pole Hilbert pair.
- The shifted signal is mono (the analytic pair is computed on the mono sum);
  WIDE gets its stereo from the two directions. True stereo would double the
  32 words of allpass state.
