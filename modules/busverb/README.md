# BusVerb

An eight-line FDN reverb with ROOM/PLATE/BIG modes, modulated taps, a
shimmer, a gate and mid/side width. Hosted on payload A (core 0), which
serves tracks 5–8 (measured; test it on track 5). Stage 2 of the one aux bus.

Structure, parameters and memory layout: [`docs/effects/REVERB.md`](../../docs/effects/REVERB.md).
Voicing: [`docs/effects/VOICING.md`](../../docs/effects/VOICING.md).

## Measured

- Wet levels at defaults, AUX 100: ROOM −16.9, PLATE −19.1, BIG −19.0 dBFS.
- RT60 (a 50 ms burst, −3..−33 dB slope) at TIME 0 / 32 / 64 / 96 / 127:
  ROOM 0.87 / 1.0 / 1.5 / 2.8 / 3.9 s; PLATE 0.9 → 4.4 s; BIG 1.6 → 11.7 s.
  The tank law is `$1e = a − k_mode·(d_min + d_span·(1−t)²)` (k ROOM 0.5 /
  PLATE 0.4 / BIG 0.25; d > 0 always, so the norm-stability proof holds). The
  output-branch bloom pair's g follows TIME (0.40 → 0.86).
- The short-room floor is the input diffusers: at TIME 0, DIFF 0 → 0.50 s,
  40 → 0.64, 80 → 0.87, 127 → 1.49 s. At DIFF 127 the four diffusion
  allpasses at g 0.77 read as a metallic sheen; capping the span at ~0.70
  removes it.

## Open

- Coupling the diffuser g to TIME (~13 words) waits for payload A words.
- A SIZE turn once killed the reverb (R44) and has not been reproduced. If it
  recurs, the diagnostic is whether tracks 5–8 all died.
