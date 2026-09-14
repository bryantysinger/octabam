# HELLO WORLD

A linear volume knob, the reference minimal insert: one page-1 knob, 27
words of DSP, no state. The worked example `modules/_template` points at,
kept buildable as the DSP pipeline's canary. Contributed by Bryan T.

## Parameters

| slot | name | what it does |
|---|---|---|
| 0 | GAIN | linear level, out = in × GAIN/128; 127 = exact passthrough, 0 = silence. Default 127. |

The 126→127 step is 0.984→1.0 (~0.14 dB): the price of a bit-exact top.

## Measured

- On the author's unit (2 Sep 2026, OS 1.40C base): GAIN=64 measures −6 dB
  against GAIN=127; GAIN=127 is level-identical to SEND on the same source;
  sequencer and project load normal. One unreproduced anomaly: the first
  flash froze the sequencer ~2 steps after play; a reflash of the
  byte-identical image ran clean.
- `tools/verify/verify_hello.py` (dsp_host, payload A, entries resolved from
  the built image's dispatch tables, a full-scale bipolar ramp): GAIN=127
  bit-exact; GAIN=0 exact silence; GAIN 32/64/96/126 every sample exactly
  `(in × GAIN<<16) >> 23`, 0 LSB error, negative half included (so the
  `mpy` encodes signed); L and R identical.
- Disassembled out of the built image: the compare encodes `cmp x0,a` (not
  `max a,b`) and both multiplies `mpy x0,y1,a` (not `mpysu`).

## Running the gates

```bash
make check REMIX=hello
python3 tools/remix/audition.py hello out/dry/drums_110.wav GAIN=64
python3 tools/verify/verify_hello.py            # expects ALL GATES PASSED, 0 LSB
```

The audition builds the scratch image the gates measure. `verify_hello.py`
derives the fx2 id and the GAIN slot from the manifest and refuses to run if
they resolve to SEND's entry points: an id an image does not implement
aliases to the fallback and renders a plausible dry passthrough, which the
GAIN=127 gate cannot distinguish from unity.

## The 4-character abbr rule

The descriptor's abbr field is 5 bytes, NUL-terminated: four characters. A
5-character abbr drew correctly and behaved under manual knob use, and threw
a line-F exception (VEC:0B, faulting PC `0x48454C4C` = "HELL") the moment a
parameter was LFO-modulated. Measured: all 30 stock page descriptors carry
≤4 characters with byte 5 zero. Inferred: a PC made of the field's ASCII is
a smashed return address, so something copies the abbr into a fixed 5-byte
destination; the copy is not located. `schema.MenuEntry` refuses an abbr
over 4 and a fullname over 12, and `build_bus.py` re-checks the string it
writes, tag included.
