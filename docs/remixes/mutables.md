# `mutables` — Five inserts

WarpFold, Ripple, Rungs, Streamz, BodeShift on the FX2 chooser. No bus.

## What is in it

- **WarpFold** — wavefolder + ring mod (FOLD / RING / BOTH). Knobs DRV FREQ TONE MIX / MODE.
- **Ripple** — driven state-variable filter, LP/BP/HP, singing resonance. Knobs FREQ RES DRV MIX / MODE.
- **Rungs** — 8-mode modal resonator (STRING / BELL / GLASS). Knobs FREQ STRC DAMP MIX / MODE.
- **Streamz** — vactrol lowpass gate (LPG / VCF / VCA). Knobs SENS FALL COLR MIX / MODE.
- **BodeShift** — Bode frequency shifter (UP / DOWN / WIDE) with feedback. Knobs FREQ FINE FDBK MIX / MODE.

## Status

Verified by local render (bit-identity and DC gates). Never flashed.

## Build

```bash
make image REMIX=mutables BUILD=1     # -> out/OCTATRACK_OCTABAM1.bin
```

[BUILDING.md](BUILDING.md) is the walk-through from a fresh machine to a flashed unit. `make check REMIX=mutables` runs every gate first.
