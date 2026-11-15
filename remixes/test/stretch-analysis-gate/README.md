# `stretch-analysis-gate` -- STRETCH ANALYSIS GATE

One ColdFire module by Bryan Tysinger and the stock effects.

## What is in it

- **STRETCH ANALYSIS GATE** -- [`modules/stretch-analysis-gate/README.md`](../../../modules/stretch-analysis-gate/README.md).
- the 14 stock FX2 effects, listed so the chooser is stock's.

## Status

Checked under the port (24 Oct 2026): TSTR-off voices take no analysis calls, and five and seven sound-on-sound loops record byte for byte the same as without it. The module ran on Bryan T's MKII in test builds with other modules. This remix as a whole has not been flashed.

## Build

```bash
make image REMIX=stretch-analysis-gate BUILD=1
```

[BUILDING.md](../../../docs/guide/BUILDING.md) is the walk-through from a fresh machine to a flashed unit. `make check REMIX=stretch-analysis-gate` runs every gate first.
