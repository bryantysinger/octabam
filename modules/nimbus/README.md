# Nimbus

A Clouds-flavoured granular texture insert with a real buffer: the track's
audio records continuously into a 32,768-word mono line (743 ms) and four
unity-rate grains read it back, two per channel at a half-period offset so
each channel's triangle windows sum to constant power.

## Knobs

| slot | name | what |
|---|---|---|
| p0 | POS  | how far back the grains reach, 23–370 ms behind the write head |
| p1 | SIZE | grain length 23 / 46 / 93 / 186 ms |
| p2 | DENS | per-grain random scatter, up to ~92 ms, latched at each grain's own wrap |
| p3 | MIX  | dry/wet; 0 = exact passthrough |
| p7 | FRZE | RUN / HOLD (stops the write head) |

## One Nimbus per core

The buffer is the fixed core-private FX2-instance region `Y:0x4000–0xBFFF`,
not per-instance. Two Nimbus instances on one core would share one buffer,
and it cannot coexist with BusVerb, whose tank lives in that region, or with
the seven stock effects that allocate a buffer. Hence its own remix.

## Measured

Assembles (500 words), disassembly-audited, rendered locally
(`tools/verify/verify_nimbus.py`):

- MIX=0 bit-exact passthrough; warm-up (3,840 samples) is pure dry.
- DC in comes back flat to −180 dB: the grain pair sums to constant power.
  The read geometry carries a `+ phase` term (a fixed tap behind the moving
  head); without it the window sum rippled 3.2 dB p-p at DC.
- A 438 Hz tone at MIX 127, FRZE 0, DENS 127 reads back at 441 Hz, 2f/f
  −42 dB.
- POS: echo at +1,303 samples at POS=0, +16,603 at POS=127; DENS decorrelates
  the channels; peak 0.400 FS across the DENS sweep.
- Freeze (`NFRZAT=n`, DEV-only): with the input cut to silence after the
  freeze the output sustains on buffer content alone (−15.5 dB at +1 s,
  −16.2 dB at +3 s). Freeze late enough that POSbase + grain length of
  material has been recorded, or the cloud freezes the warm-up's silence.

Never flashed.

## Open

- Grain density is fixed at four; Clouds' texture/diffusion stage and
  pitch-shifted grains are not implemented.
