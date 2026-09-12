# BusVerb

An eight-line FDN reverb with ROOM/PLATE/BIG modes, modulated taps, a
shimmer, a gate and mid/side width. Hosted on payload A (core 0), which
serves **tracks 5–8** — measured, and inverted from what every doc assumed
before it was measured. Test it on track 5.

Full structure, parameters and memory layout: [`docs/effects/REVERB.md`](../../docs/effects/REVERB.md).
Voicing decisions: [`docs/effects/VOICING.md`](../../docs/effects/VOICING.md).

**v7 (4 Sep 2026): MODE is page-2 slot 6 and SHMR slot 7** — swapped so
MODE sits on a slot the panel's page-2 knob editor writes, which a main-menu
bus screen needs (`docs/firmware/MAINMENU.md` §9c-ii). Locally bit-identical in every
mode. A part saved before v7 loads its old bytes crossed (ROOM + a whisper of
shimmer): re-select the effect.

`reverb_lforoll.asm` is a parked alternate engine that frees 51 words and
fails `verify_roll` on the one case that drives the allpass hard. It is kept
because the bisect narrowed it; see `PLAN.md`.

## Open

- ~~Per-mode gain structure: the modes sit 7–9 dB apart~~ — measured 12 Sep
  2026 on the loop at the unit's level (AUX 100): ROOM −16.9, PLATE −19.1,
  BIG −19.0 dBFS wet at defaults, within 2 dB; the note predated the re-laws.
  The default MODE is PLATE now (was BIG) and DIFF 80 (was 64; R59's
  bracket).
- ~~The decay dial had a floor~~ **RESOLVED 13 Sep 2026** — it was the
  energy-bloom pair (R13): two allpasses on the *output* branch at a fixed
  g = 0.867 on 41 / 29 ms lines, a 2.0 s ring nothing upstream could
  shorten. Found by excision (tank gains zeroed, then the in-loop allpass g
  zeroed: the output still fell at −33 dB/s; the delay on the same burst was
  one echo then silence). The bloom's g now follows TIME (0.40 → 0.86), and
  the tank law is `$1e = a − k_mode·(d_min + d_span·(1−t)²)` — the distance
  below loop-neutral is what the decay rate is proportional to, and a
  squared taper on it spreads RT60 across the dial (k ROOM 0.5 / PLATE 0.4 /
  BIG 0.25; d > 0 always, so the norm-stability proof holds by construction).
  Measured RT60 (a 50 ms burst, −3..−33 dB slope): ROOM 0.87 / 1.0 / 1.5 /
  2.8 / 3.9 s at TIME 0 / 32 / 64 / 96 / 127, PLATE 0.9 → 4.4, BIG 1.6 → 11.7.
  What is left under a short room is the input diffusers: at TIME 0, DIFF 0 →
  0.50 s, 40 → 0.64, 80 → 0.87, 127 → 1.49 — DIFF sets the short-room floor.
  Coupling the diffuser g to TIME (~13 words) waits for payload A to have
  them (FREE 8). The bus reference was re-stamped on this build (only the
  reverb layouts differ; every delay-only layout stays bit-identical).
- A SIZE turn once killed the reverb on R44 and has not been reproduced. If
  it recurs, the one diagnostic that matters is whether tracks 5–8 *all* died.
