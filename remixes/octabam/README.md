# octabam

A remix of Octatrack OS 1.40C, built from your own copy of it, that adds the
core modules (below) to all 14 stock effects and adds SPECTRUM, CHARACTER,
MODULATION, TRANSIENT and GATE VERB. It has no bus and no SEND. See
[Where it has run](#where-it-has-run).

## The effects

All 14 stock effects stay in the menus. SPECTRUM, CHARACTER, MODULATION and
TRANSIENT are on FX1 and FX2; GATE VERB is on FX2. Their DSP code runs from the
shared P window (`P:0x30000..0x3ffff`) beside the stock effects, one copy
each for both cores, on free effect ids.

| effect | FX1 | FX2 | id | what it is | module |
|---|---|---|---|---|---|
| SPECTRUM | ✓ | ✓ | 0x0f | filter: Moog ladder, SEM, Capacitor2, formants | [`spectrum`](../../modules/spectrum/README.md) |
| CHARACTER | ✓ | ✓ | 0x17 | fold, saturation, tilt, compressor, width | [`character`](../../modules/character/README.md) |
| MODULATION | ✓ | ✓ | 0x0e | Juno, Dimension, flanger, phaser, comb | [`modulation`](../../modules/modulation/README.md) |
| TRANSIENT | ✓ | ✓ | 0x0a | transient shaper (Ignorato) | [`transient`](../../modules/transient/README.md) |
| GATE VERB | | ✓ | 0x1a | gated plate reverb (the reverb stage of Mutable Instruments Clouds plus a gate) | [`gateverb`](../../modules/gateverb/README.md) |

The stations have their `SLOTS` build setting at `FX1+FX2`. CHARACTER's KEY = T1
needs a BusDelay host, so here it keys on the track's own input. A MODE
turned on the panel re-defaults the knobs around it
([`mode-defaults`](../../modules/mode-defaults/README.md)).

## The core modules

The same set is in [`octabam-bus`](../octabam-bus/README.md), with LOFI AMF FIX
(the stock LO-FI's AMF control).

| group | module | what it does |
|---|---|---|
| platform | [BRAIN](../../modules/brain/README.md) | card-wide settings, defaults and templates, remix switch, TOOLS (MIDI monitor, LOAD) |
| | [STORE](../../modules/store/README.md) | the save, load, copy and Part sites KITS and PLOCKS P2 share |
| | [LOAD METER](../../modules/load-meter/README.md) | the frame interrupt's and each DSP core's busy time, for BRAIN's LOAD view; its DSP half runs from the window |
| sequencing | [KITS](../../modules/kits/README.md) | 255 Kits per project; each pattern plays its Kit |
| | [MIDI SCENES](../../modules/midi-scenes/README.md) | scene locks for MIDI tracks |
| | [SCENES P2](../../modules/scenes-p2/README.md), [PLOCKS P2](../../modules/plocks-p2/README.md) | scene locks and parameter locks on FX page 2 |
| | [CC MAP](../../modules/cc-map/README.md), [CC FEEDBACK](../../modules/cc-feedback/README.md) | CC onto page 2; knob changes out as CC |
| | [DIRECT_JUMP_KYOTI](../../modules/direct-jump-kyoti/README.md), [RELOAD_FROM_PROJECT](../../modules/reload-from-project/README.md) | clock-locked direct jump; reload one track from the card |
| | [SCALE QUANTIZER](../../modules/quantizer/README.md), [TUNER](../../modules/tuner/README.md) | scale quantizing on PTCH; a tuner window (UP + TEMPO) |
| USB | [USB](../../modules/usb/README.md) | MIDI both ways; tracks, MAIN and CUE to a computer (TRACKS PRE, MAIN, CUE, MIDI on by default; settings in BRAIN) |
| recorder and fixes | [RECORDER LOOP FIX](../../modules/recorder-loop-fix/README.md), [RLEN PLEN](../../modules/rlen-plen/README.md) | the loop click; RLEN value PLEN |
| | [BATCH_BUGFIXES](../../modules/batch-bugfixes/README.md), [ERASE_EMPTY_TRIGLESS_LOCKS](../../modules/erase-empty-trigless-locks/README.md), [QUANTIZE_LIVE_REC_TOGGLE](../../modules/quantize-live-rec-toggle/README.md), [REC_TRIG_MUTE](../../modules/rec-trig-mute/README.md), [MUTE_MODES](../../modules/mute-modes/README.md) | Zac-Kyoti's fixes and mute modes (MUTE_MODES runs from DRAM) |
| | [ATA WRITE GUARD](../../modules/ata-write-guard/README.md) | keeps the first PIO card write and its bookkeeping atomic against the completion interrupt |

## Where it has run

Port gates only: `make check REMIX=octabam`. The window's wait-state cost and the
effects running from the window have not been measured on a unit.

## How to flash

[BUILDING.md](../../docs/guide/BUILDING.md) has every step, from what to
install to the way back to stock. For this remix:

1. **Build.** Pick a build number; it becomes the OS version the unit shows.

   ```bash
   make image REMIX=octabam BUILD=91     # -> out/OCTATRACK_OCTABAM91.bin
   ```

2. **Back up the card.** KITS writes `kits.work` into each project it loads.
3. **Old projects.** For a project made before this remix, on the card:

   ```bash
   python3 tools/hw/ot_project.py stamp-defaults "<card>/<set>/<project>" octabam
   ```

4. **Flash from the card** ([BUILDING.md section 5](../../docs/guide/BUILDING.md#5-flash-from-the-card)),
   then power-cycle once more. SYSTEM STATUS → OS VERSION reads `OCTABAM91`.
5. **Back to stock:** [BUILDING.md section 8](../../docs/guide/BUILDING.md#8-back-to-stock-or-another-remix).

If the unit misbehaves, [FAILURE_MODES.md](../../docs/contributing/FAILURE_MODES.md)
is the register of what has gone wrong and why.
