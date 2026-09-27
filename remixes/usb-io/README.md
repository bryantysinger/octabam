# `usb-io` — four in, four out over USB, on the stock effects

The Octatrack as a four-in, four-out USB audio interface plus USB MIDI, on the stock effects minus SPATIALIZER. MAIN and CUE go to the host; the host's four channels come in on inputs A–D while its stream is open, and A–D are the jacks when it is closed.

## What is in it

- **USB MIDI** and **USB AUDIO MC** (markandrus/octemu; the MC variant Bryan T's): USB-MIDI mirroring DIN; MAIN L/R + CUE L/R to the host, 24-bit, every 250 µs; MAIN alone at full speed. [`modules/usb-audio-mc`](../../modules/usb-audio-mc/README.md).
- **USB AUDIO IN** (Bryan T): four 24-bit channels from the host into inputs A–D, asynchronous with implicit feedback from the MC stream. [`modules/usb-audio-in`](../../modules/usb-audio-in/README.md).
- 13 of the 14 stock FX2 effects. SPATIALIZER is on neither menu: its first words on payload A hold USB AUDIO IN's DSP inject, and a project that still selects it runs NONE.

## Status

On hardware: build 16 on Bryan T's MKII (27 Sep 2026). macOS lists it as 4 in / 4 out; MAIN and CUE reach the Mac, the host's audio arrives on A–D, and the jacks return when the host stops; about 5 million host packets with no bad packet, underrun or overrun; DISK MODE works and the stream comes back after it. The round trip through the unit's two rings measured about 31 ms (modules/usb-audio-in/README.md, *Latency*). Under the port, `make check` and `make accept` pass. Before this port, the same combination ran as usbin-test's `usb-io` (builds 12–15, 26 Sep 2026), with byte-identical USB descriptors.

## Build

```bash
make image REMIX=usb-io BUILD=1   # -> out/OCTATRACK_OCTABAM1.bin
```

[BUILDING.md](../../docs/remixes/BUILDING.md) is the walk-through from a fresh machine to a flashed unit. `make check REMIX=usb-io` runs every gate first, USB AUDIO IN's own `verify_usb_in` included.
