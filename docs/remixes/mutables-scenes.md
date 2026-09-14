# `mutables-scenes` — Five inserts + the MIDI SCENES family

The `mutables` card with MIDI SCENES, the LO-FI fix and CC PAGE 2.

## What is in it

- **WarpFold** — wavefolder + ring mod (FOLD / RING / BOTH). Knobs DRV FREQ TONE MIX / MODE.
- **Ripple** — driven state-variable filter, LP/BP/HP, singing resonance. Knobs FREQ RES DRV MIX / MODE.
- **Rungs** — 8-mode modal resonator (STRING / BELL / GLASS). Knobs FREQ STRC DAMP MIX / MODE.
- **Streamz** — vactrol lowpass gate (LPG / VCF / VCA). Knobs SENS FALL COLR MIX / MODE.
- **BodeShift** — Bode frequency shifter (UP / DOWN / WIDE) with feedback. Knobs FREQ FINE FDBK MIX / MODE.
- **MIDI SCENES** (bkkbrls-del, [midisc](https://github.com/bkkbrls-del/midisc) 1.40MIDISC8) — per-scene parameter locks driven over MIDI: a second lock table the panel never had; scene hold, XF morph, part save/reload and the scene clear/copy/paste rows read it when a MIDI event is driving. The panel path is untouched. Thirteen units in DRAM, 38 detours, 4 pokes inside the OS.
- **LOFI AMF FIX** (Bryan T, [octa-bt-pt](https://github.com/bryantysinger/octa-bt-pt)) — stock LO-FI's AMF knob jumps the pitch backwards at some settings because its coefficient multiply is `mpysu` (signed × unsigned) where both operands are magnitudes; two DSP words become `mpyuu`.
- **CC PAGE 2** (octabam) — MIDI CC 62–67 reach the FX2 effect's page-2 knobs (slots 6–11) and CC 68–73 the FX1 effect's; stock reaches only page 1 over MIDI. One ColdFire cave. Confirmed on hardware 13 Sep 2026.

## Status

Builds and passes every gate. Not flashed.

## Build

```bash
make image REMIX=mutables-scenes BUILD=1     # -> out/OCTATRACK_OCTABAM1.bin
```

[BUILDING.md](BUILDING.md) is the walk-through from a fresh machine to a flashed unit. `make check REMIX=mutables-scenes` runs every gate first.
