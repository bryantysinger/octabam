# Streamz

A Streams-flavoured lowpass gate: the track's level drives an envelope
follower, and the envelope opens a filter and an amplifier together (the
Buchla vactrol behaviour). Per-track insert, no buffer. In the `mutables`
remix.

## Knobs

| slot | name | what |
|---|---|---|
| p0 | SENS | follower drive; 64 is unity (a full-scale peak opens it fully) |
| p1 | FALL | release, T60 20 ms–700 ms, cubic taper on the decay rate |
| p2 | COLR | how open the filter stays when the gate is shut; 0 is a true gate |
| p3 | MIX  | dry/wet; 0 = exact passthrough |
| p7 | MODE | LPG (filter+amp) / VCF (filter only) / VCA (amp only) |

Attack is fixed and fast: the rectified input is the attack.

## Status

Assembles (255 words), disassembly-audited, rendered locally:

- MIX=0 bit-exact passthrough.
- T60 at FALL 0 / 32 / 64 / 96 / 127: measured 26 / 52 / 139 / 479 / 731 ms
  against a design of 20 / 46 / 134 / 458 / 700 ms.
- The vactrol coupling: identical noise at two levels comes out with spectral
  centroids of 9,880 Hz (loud) and 2,620 Hz (quiet).

Never flashed.
