# Repitch development

Status: first selectable firmware implementation builds, passes synthetic
contracts, and passes complete ColdFire + dual-DSP Flex playback at three
tempos; not hardware-tested. Target hardware: user's MKII.

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

The complete emulator now also proves project load, transport, Flex sample
playback, and audible ratio changes through both firmware cores. It still does
not prove physical display width or behavior unique to the MKII hardware.

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

A private project template was copied to ignored `out/` storage and configured
with one looping Flex voice: a 44.1 kHz stereo, four-beat, 120 BPM / 440 Hz
sample, source BPM metadata 2880, TSTR raw 4, and one trig on A01. The patched
1.40C image loaded it from an emulated CompactFlash card and ran the real
sequencer plus both DSP cores. A zero-crossing measurement over the final
27,000 output frames gave:

| project BPM | expected | measured |
|---:|---:|---:|
| 90 | 330 Hz | 329.36 Hz |
| 120 | 440 Hz | 440.10 Hz |
| 180 | 660 Hz | 662.31 Hz |

The four active DSP output slots agreed for each run, and the main output was
non-silent. The fixture, card images, patched image, and captured WAVs remain
ignored and are not redistributable test assets.

Next: measure a marked loop across its wrap boundary, then cover live tempo
changes, multiple tracks, saved-project round-trips and the physical MKII
screen. The repository's complete check still stops on its pre-existing
Octakit `runtime.S:438` assembler error while building other remixes; the
REPITCH build and focused gates complete before that point.
