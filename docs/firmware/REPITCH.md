# Repitch development

Status: first selectable firmware implementation builds and passes synthetic
emulator contracts; not hardware-tested. Target hardware: user's MKII.

## Behavior

Follow project tempo by changing sample speed, without grain timestretch:
`speed = project_BPM / sample_BPM`. At neutral pitch/rate a four-beat loop
remains four beats long. A 120 BPM / 440 Hz loop at 90 BPM becomes 330 Hz
and lasts 4/3 as long. Pitch offset: `12 * log2(speed)` semitones.

Initial target: Flex loops with correct source-tempo metadata and neutral
PTCH/RATE. The UI adds `REPITCH` to the existing TSTR selector. Static
streaming, recorder buffers, slices, reverse, clock changes,
pitch/rate modulation and persistent storage need separate verification.
Independent pitch changes also alter duration in this mode.

The stock mapping is measured directly from 1.40C's descriptor and formatter
table:

| raw | label | machines |
|---:|---|---|
| 0 | OFF | STATIC, FLEX |
| 1 | AUTO | STATIC, FLEX, PICKUP |
| 2 | NORM | STATIC, FLEX, PICKUP |
| 3 | BEAT | STATIC, FLEX, PICKUP |
| 4 | REPITCH | new value |

STATIC/FLEX therefore grow from four to five values. PICKUP starts at one
(OFF is deliberately absent) and grows from three to four. Existing raw
values and saved projects remain unchanged.

## Evidence and unknowns

EXTERNAL.md section 3 places grains on ColdFire and interpolation on the DSP;
this is adopted research, not a new hardware measurement. ARCHITECTURE.md's
diagram still describes DSP timestretch and conflicts with that research.

Inspected locally with objdump `-m m68k:cfv4e` on stock 1.40C:

- Binding at `0x4000f450` selects Static/Flex settings, stride `0x448`;
  `0x4000f4e0` stores the settings pointer at voice-state +8. Static base
  `0x100d5b30`, Flex base `0x100b14f0`.
- Frame writer prologue is `0x40004bd4`; documented `0x40004bd2` starts
  on a zero word. It reads latched tempo `0x8000181c` and publishes its
  low word at `0x40004d6a`.
- Position arithmetic near `0x40004c44` selects 2880 or frame tempo based
  on record byte +43. This is NOT yet a verified sample-rate hook.

Measured: sample BPM is settings `+0x114`; the TSTR raw value reaches voice
state byte `+24`; the stock rate block treats raw zero as dry and every nonzero
value (including the proposed 4) as granular. `tools/harness/repitch_probe.cpp`
locks those contracts to the user's 1.40C image and runs under CTest.

`modules/repitch/repitch.s` implements raw 4 at three coordinated points: the
TSTR formatter, the grain/dry decisions, and the playback increment shared by
ColdFire source consumption and the DSP voice command. The increment uses an
exact quotient/remainder calculation of
`increment * project_bpm24 / sample_bpm24`; missing tempo metadata leaves the
stock increment unchanged. The remixer asserts every displaced byte and grows
the three descriptor counts without renumbering stock values.

This is not yet hardware-ready. The emulator proves these isolated contracts,
not complete transport/audio behavior or the physical display width.

## Tests

Run `python3 tools/verify/verify_repitch_reference.py` for offline unity,
duration, measured tone pitch, stereo, periodic boundary and tempo validation.
These tests use a generated 440 Hz loop, requiring no project backup.
The reference uses periodic
linear interpolation, no antialias filter and no live speed changes.

CTest runs both stock and patched-image contracts. The patched test executes
all five formatter values, both dry/granular gates, unchanged stock modes and
exact shared increments at 60/90/120/180/240 BPM against a 120 BPM source.
All nine emulator tests and the five offline reference tests pass.

Next: execute a complete Flex voice and compare source consumption, pitch,
duration and wraps; then cover live tempo changes, multiple tracks, saved
project round-trips and the physical MKII screen. There is no synthetic project
generator verified for this task yet. The repository's complete check still
stops on its pre-existing Octakit `runtime.S:438` assembler error while building
other remixes; the REPITCH build and focused gates complete before that point.
