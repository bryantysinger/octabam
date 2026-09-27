# `usb-mc` — USB AUDIO MC on the stock effects

The stock chooser plus USB MIDI and USB AUDIO MC, for testing the four-channel (MAIN + CUE) stream on a unit that runs stock projects: no rig stations, no chooser changes, no project stamping.

## What is in it

- **USB MIDI** and **USB AUDIO MC** (markandrus/octemu; the MC variant Bryan T's): USB-MIDI mirroring DIN; four 24-bit channels, MAIN L/R + CUE L/R, at the same 250 us cadence as USB AUDIO EXTENDED/FULL (not USB AUDIO MASTER's 1 ms); full speed carries MAIN alone. [`modules/usb-audio-mc`](../../modules/usb-audio-mc/README.md).
- the 14 stock FX2 effects.

## Status

Port only (`verify_usb`, 27 Sep 2026): four channels in 192-byte packets every 250 us, each carrying only its own source (MAIN L, MAIN R, CUE L, CUE R); full speed sends correctly sized two-channel packets, whose content the gate does not check (as for EXTENDED and FULL). Not yet on a unit. The MAIN+CUE-only high-speed stream itself ran on hardware as usbin-test's AUD_IN4 (Bryan T's MKII, 26 Sep 2026), as a slice of the twenty-channel producer rather than this standalone one.

The same stream ran on hardware beside USB AUDIO IN in `usb-io` (build 16, 27 Sep 2026); this remix itself has not been flashed. Pairs with USB AUDIO IN (the host -> A-D stream): together they reproduce usbin-test's original 4-in/4-out combination as two independent modules instead of one AUD_IN4 flag.

## Build

```bash
make image REMIX=usb-mc BUILD=1   # -> out/OCTATRACK_OCTABAM1.bin
```

[BUILDING.md](../../docs/remixes/BUILDING.md) is the walk-through from a fresh machine to a flashed unit. `make check REMIX=usb-mc` runs every gate first.
