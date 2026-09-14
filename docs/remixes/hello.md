# `hello` — Hello World

One gain insert. The DSP pipeline's canary and the worked example for a DSP module.

## What is in it

- **HELLO WORLD** — one GAIN knob, out = in × GAIN/128. The reference DSP module.

## Status

Builds; nulls at GAIN=127 under `verify_hello`. Not flashed.

## Build

```bash
make image REMIX=hello BUILD=1     # -> out/OCTATRACK_OCTABAM1.bin
```

[BUILDING.md](BUILDING.md) is the walk-through from a fresh machine to a flashed unit. `make check REMIX=hello` runs every gate first.
