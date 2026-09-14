# `mutables-mods` — Five inserts + every mod

The `mutables` card with MIDI SCENES, Octakit, the LO-FI fix and CC PAGE 2 (bridged).

## What is in it

- **WarpFold** — wavefolder + ring mod (FOLD / RING / BOTH). Knobs DRV FREQ TONE MIX / MODE.
- **Ripple** — driven state-variable filter, LP/BP/HP, singing resonance. Knobs FREQ RES DRV MIX / MODE.
- **Rungs** — 8-mode modal resonator (STRING / BELL / GLASS). Knobs FREQ STRC DAMP MIX / MODE.
- **Streamz** — vactrol lowpass gate (LPG / VCF / VCA). Knobs SENS FALL COLR MIX / MODE.
- **BodeShift** — Bode frequency shifter (UP / DOWN / WIDE) with feedback. Knobs FREQ FINE FDBK MIX / MODE.
- **MIDI SCENES** (bkkbrls-del, [midisc](https://github.com/bkkbrls-del/midisc) 1.40MIDISC8) — per-scene parameter locks driven over MIDI: a second lock table the panel never had; scene hold, XF morph, part save/reload and the scene clear/copy/paste rows read it when a MIDI event is driving. The panel path is untouched. Thirteen units in DRAM, 38 detours, 4 pokes inside the OS.
- **OCTAKIT** (Em, [ems-octakit](https://github.com/emuyia/ems-octakit) ot-26914) — 256 Kits per Project in place of 64 bank-tied Parts. MKII: PART opens LOAD KIT, FUNC+PART opens SAVE KIT; MKI: FUNC+MIDI opens LOAD KIT, FUNC+BANK opens SAVE KIT. FUNC+CUE reloads the assigned Kit; Kits have 7-character names; the LOAD/SAVE KIT menus copy/paste/clear/undo; PTN+FUNC+RIGHT duplicates a Pattern and its Kit. Costs 3.6 % of the flex pool (18.4 s at 16-bit). Old projects migrate their Parts into the first 64 Kit slots on load. A 154,718-byte runtime in DRAM, carried by octabam's loader.
- **LOFI AMF FIX** (Bryan T, [octa-bt-pt](https://github.com/bryantysinger/octa-bt-pt)) — stock LO-FI's AMF knob jumps the pitch backwards at some settings because its coefficient multiply is `mpysu` (signed × unsigned) where both operands are magnitudes; two DSP words become `mpyuu`.
- **CC PAGE 2** (octabam) — MIDI CC 62–67 reach the FX2 effect's page-2 knobs (slots 6–11) and CC 68–73 the FX1 effect's; stock reaches only page 1 over MIDI. One ColdFire cave. Confirmed on hardware 13 Sep 2026.
- **SCENES KITS** (octabam) — the bridge that lets CC PAGE 2 and Octakit share the MIDI CC dispatch entry: CCs 62–67 ours, then hers, then stock's. Nothing of its own to use.
- **KITS RELOAD** (octabam) — the bridge that lets MIDI SCENES' Part Reload run beside Octakit's kit reload: her reload validates its caller's return address, his stub substituted it (OKMS1 trapped on the first Part Reload); the stock call stays and his post-reload restore runs from the return sites.

## Status

Builds and passes every gate. Not flashed.

## Build

```bash
make image REMIX=mutables-mods BUILD=1     # -> out/OCTATRACK_OCTABAM1.bin
```

[BUILDING.md](BUILDING.md) is the walk-through from a fresh machine to a flashed unit. `make check REMIX=mutables-mods` runs every gate first.

## Before you flash

- **Octakit migrates Parts into Kits on project load.** Back up projects first; going back to stock can lose Kit data.
