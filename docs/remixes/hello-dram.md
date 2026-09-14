# `hello-dram` — Hello DRAM

One DRAM unit. The ColdFire pipeline's canary and the worked example for a ColdFire module.

## What is in it

- **HELLO DRAM** — one DRAM unit with no hooks. The reference ColdFire module; proves the loader ran.

## Status

Boots under the port; the window reads back equal to the linked image. Not flashed.

## Build

```bash
make image REMIX=hello-dram BUILD=1     # -> out/OCTATRACK_OCTABAM1.bin
```

[BUILDING.md](BUILDING.md) is the walk-through from a fresh machine to a flashed unit. `make check REMIX=hello-dram` runs every gate first.
