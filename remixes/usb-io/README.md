# `usb-io` — four in, four out over USB, on the stock effects

The Octatrack as a four-in, four-out USB audio interface plus USB MIDI, on the stock effects minus SPATIALIZER. MAIN and CUE go to the host; the host's four channels come in on inputs A–D while its stream is open, and A–D are the jacks when it is closed.

## What is in it

- **USB MIDI** and **USB AUDIO MC** (markandrus/octemu; the MC variant Bryan T's): USB-MIDI mirroring DIN; MAIN L/R + CUE L/R to the host, 24-bit, every 250 µs; MAIN alone at full speed. [`modules/usb-audio-mc`](../../modules/usb-audio-mc/README.md).
- **USB AUDIO IN** (Bryan T): four 24-bit channels from the host into inputs A–D, asynchronous with implicit feedback from the MC stream. [`modules/usb-audio-in`](../../modules/usb-audio-in/README.md).
- 13 of the 14 stock FX2 effects. SPATIALIZER is on neither menu: its first words on payload A hold USB AUDIO IN's DSP inject, and a project that still selects it runs NONE.

## Status

Port only (27 Sep 2026): `make check` passes, and USB AUDIO IN's `verify_usb_in` puts the host's samples on inputs A–D bit-exact, with no underrun, over eight runs (one of them 40,000 polls). Two runs failed a check that read the stream flag from a mid-build snapshot, a flaw in the gate that is now fixed (modules/usb-audio-in/README.md). The same combination ran on Bryan T's MKII as usbin-test's `usb-io` (builds 12–15, 26 Sep 2026: USB AUDIO OUT beside a twenty-channel build forced to four channels), with the USB descriptors byte-identical to this remix's. This build has not been flashed.

## Build

```bash
make image REMIX=usb-io BUILD=1   # -> out/OCTATRACK_OCTABAM1.bin
```

[BUILDING.md](../../docs/remixes/BUILDING.md) is the walk-through from a fresh machine to a flashed unit. `make check REMIX=usb-io` runs every gate first, USB AUDIO IN's own `verify_usb_in` included.
