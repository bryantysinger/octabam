# `ok-ms` — Octakit + MIDI SCENES

The two community mods on the stock effects. No octabam effects, no CC PAGE 2, no LO-FI fix.

## What is in it

- **MIDI SCENES** (bkkbrls-del, [midisc](https://github.com/bkkbrls-del/midisc) 1.40MIDISC8) — per-scene parameter locks driven over MIDI: a second lock table the panel never had; scene hold, XF morph, part save/reload and the scene clear/copy/paste rows read it when a MIDI event is driving. MIDI → CONTROL ticks CC48/CC55/CC56 switch it (default ON). The panel path is untouched. Thirteen units in DRAM, 38 detours, 4 pokes inside the OS.
- **OCTAKIT** (Em, [ems-octakit](https://github.com/emuyia/ems-octakit) ot-26914) — 256 Kits per Project in place of 64 bank-tied Parts. MKII: PART opens LOAD KIT, FUNC+PART opens SAVE KIT; MKI: FUNC+MIDI opens LOAD KIT, FUNC+BANK opens SAVE KIT. FUNC+CUE reloads the assigned Kit; Kits have 7-character names; the LOAD/SAVE KIT menus copy/paste/clear/undo; PTN+FUNC+RIGHT duplicates a Pattern and its Kit. Costs 3.6 % of the flex pool (18.4 s at 16-bit). Old projects migrate their Parts into the first 64 Kit slots on load. A 154,718-byte runtime in DRAM, carried by octabam's loader.
- the 14 stock FX2 effects, listed so the chooser is stock's.

## Status

**On hardware.** Built 14 Sep 2026 as `OKMS1` and confirmed working the same day by midisc's author on his own unit (his projects; boot, load, play, his mod). The first image from this pipeline to run on silicon.

## Build

```bash
make image REMIX=ok-ms BUILD=1     # -> out/OCTATRACK_OCTABAM1.bin
```

[BUILDING.md](BUILDING.md) is the walk-through from a fresh machine to a flashed unit. `make check REMIX=ok-ms` runs every gate first.

## Before you flash

- **Octakit migrates Parts into Kits on project load.** Back up projects first; going back to stock can lose Kit data.
