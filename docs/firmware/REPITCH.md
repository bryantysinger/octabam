# Repitch development

Status: specification and offline reference only. No firmware hook, selectable
mode or Repitch image yet. Target hardware: user's MKII.

## Behavior

Follow project tempo by changing sample speed, without grain timestretch:
`speed = project_BPM / sample_BPM`. At neutral pitch/rate a four-beat loop
remains four beats long. A 120 BPM / 440 Hz loop at 90 BPM becomes 330 Hz
and lasts 4/3 as long. Pitch offset: `12 * log2(speed)` semitones.

Initial target: Flex loops with correct source-tempo metadata and neutral
PTCH/RATE. Intended UI: additional Repitch choice alongside existing TSTR
modes. Static streaming, recorder buffers, slices, reverse, clock changes,
pitch/rate modulation and persistent storage need separate verification.
Independent pitch changes also alter duration in this mode.

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

Still trace: sample BPM field; TSTR selector and grain-bypass branch; DSP rate
format; ColdFire source consumption; numeric limits. A DSP-only rate change
could desynchronize the input ring. Verify serialization and formatter bounds
before adding a selectable mode. Do not install guessed hooks.

## Tests

Run `python3 tools/verify/verify_repitch_reference.py` for offline unity,
duration, measured tone pitch, stereo, periodic boundary and tempo validation.
These tests use a generated 440 Hz loop, requiring no project backup.
They do NOT exercise any firmware or emulator. The reference uses periodic
linear interpolation, no antialias filter and no live speed changes.

Next: execute a Flex voice under the emulator with a synthetic or unit-created
project and compare source consumption, pitch, duration and wraps across
60/90/120/180/240 BPM; then tempo changes, multiple tracks and unchanged stock
modes. There is no synthetic project generator verified for this task yet.
The existing full-check Octakit assembler failure needs separate diagnosis;
Linux tool aliases alone do not prove its cause.
