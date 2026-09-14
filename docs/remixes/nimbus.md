# `nimbus` — Nimbus

The granular insert alone.

## What is in it

- **Nimbus** — 743 ms granular texture, 4 grains, freeze. Knobs POS SIZE DENS MIX / FRZE. One instance per core.

## Status

Verified by local render. Never flashed. Cannot share an image with a bus server or with the seven stock effects that allocate a buffer.

## Build

```bash
make image REMIX=nimbus BUILD=1     # -> out/OCTATRACK_OCTABAM1.bin
```

[BUILDING.md](BUILDING.md) is the walk-through from a fresh machine to a flashed unit. `make check REMIX=nimbus` runs every gate first.
