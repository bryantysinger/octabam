# `bamsep26` — The rig

BusVerb + BusDelay on one aux bus (pedals on the send: the send passes both, each WET adds), three stations on FX1, the stock delay, tempo sync, CC→page 2. The image on Sam's unit.

## What is in it

- **BusVerb** — an eight-line FDN reverb (ROOM / PLATE / BIG, shimmer, gate, mid/side width) that serves all eight tracks over a cross-core bus. Hosted on one of tracks 5–8.
- **BusDelay** — a multi-mode delay (CLEAN / pitched GRAIN cloud / REVERSE, tape wow, freeze) serving all eight tracks. Hosted on one of tracks 1–4. TIME reads as a tempo division (TEMPO SYNC); up to 739 ms (1/4 and 1/2T at 121 BPM) since the 32K lines, 15 Sep 2026, unflashed.
- **Send** — the FX2 effect every other track runs: one SEND knob into the bus. The fallback for any unassigned track.
- **DELAY** (stock) — the stock Echo Freeze delay row, unchanged; it runs on the ColdFire and costs the DSP nothing.
- **Spectrum** (FX1, on FILTER's id) — a filter pedal: SEM LP/BP/HP, Airwindows Capacitor2, formants, the Moog ladder; ENV and LFO onto the cutoff; width. Knobs FREQ RES ENV LDP LSP WDTH / TAME MODE.
- **Character** (FX1, on LO-FI's id) — crush, fold/ring, saturation, compressor, width; the bus return (RET) on track 8. Knobs DRV FOLD TXTR COMP RET TONE / MIX SAT WDTH.
- **Modulation** (FX1, on CHORUS's id) — chorus / flanger / comb. Knobs RATE DPTH FDBK MIX / DLY MODE TONE SHPE WID.
- **TEMPO SYNC** (octabam) — two ColdFire caves: the held MIDI note reaches BusDelay, and BusDelay's TIME draws as a division (1/8, 1/4 …) instead of milliseconds; the tempo itself comes from stock's record word. On the unit since 24 Aug 2026; the note-only cave since image 24 (15 Sep 2026).
- **CC PAGE 2** (octabam) — MIDI CC 62–67 reach the FX2 effect's page-2 knobs (slots 6–11) and CC 68–73 the FX1 effect's; stock reaches only page 1 over MIDI. One ColdFire cave. Confirmed on hardware 13 Sep 2026.
- **MODE DEFAULTS** (octabam) — turning a MODE on the panel re-defaults the knobs around it to that mode's view (BusDelay's three modes, Modulation's six, Spectrum's VOWL/LADR), on FX1 and FX2; SEND is never touched. Two detours in the page-2 editors. Measured under the port (`verify_modedefaults`); confirmed on the unit, image 26 (15 Sep 2026). A MODE set over CC 62/68 is not re-defaulted.

FX2 chooser: BusVerb, BusDelay, Send, DELAY. FX1 chooser: NONE, Spectrum, Character, Modulation. The stations are FX1-only and default to a bit-exact passthrough, so a saved part that chose FILTER, LO-FI or CHORUS still plays.

## Status

On Sam's MKII (image 96, 13 Sep 2026; images 25-27, 15 Sep 2026: the WET pedal chain, MODE DEFAULTS, only MODE/SAT naming themselves). The one-aux bus claims all pass on hardware (flash 7); the sends into the delay with the note-only tempo cave, image 24. Every other stock effect is harvested: 13 effects; a saved part naming one plays silence.

## Build

```bash
make image REMIX=bamsep26 BUILD=1     # -> out/OCTATRACK_OCTABAM1.bin
```

[BUILDING.md](BUILDING.md) is the walk-through from a fresh machine to a flashed unit. `make check REMIX=bamsep26` runs every gate first.

## Before you flash

- After flashing, stamp every project you will play before pressing play: `python3 tools/hw/ot_project.py stamp-defaults <project> bamsep26`. A part saved under another layout feeds the stations its old bytes and the sequencer stalls.
- Judge BusVerb on track 5 (payload A serves tracks 5–8), BusDelay on track 1.
- First flash with the 32K lines: a stored TIME byte now means twice the time (64 + knob·256 samples). `python3 tools/hw/ot_project.py stamp-slot <project> busdelay 1 20` on every project you will play, or re-set TIME on the delay host per part.
