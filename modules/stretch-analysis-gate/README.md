# STRETCH ANALYSIS GATE

The stock sample-analysis task skips voices whose time-stretch is off.

## What it changes

Stock runs a task at `0x40098a5c` (priority 1, shared with the engine and
the sys task's UI event loop; BRAIN's CPU tab lists it as TASK 98A5C). It
walks the eight voices; for each playing FLEX, STATIC or PICKUP voice it
copies the voice record (`0x800049d8 + 168 x t`) to `44(sp)`, refreshes the
voice's entry in the table `0x80006924` (`0x4009871c`) and analyses the
sample in 512-unit chunks (`0x400985ac`: unpack up to 768 frames to SRAM,
biquad, rectify, decimate by two, envelope, onsets), looping without
sleeping while any voice is pending.

Its only readers are the voice renderer's time-stretch splice branches,
`0x40008250` (forward) and `0x40008a1a` (reverse), inside the renderer's
paths for a non-zero resolved TSTR (voice `+24`, `docs/firmware/REPITCH.md`).
Each matches the table entry against the voice (`0x4000825e`,
`0x40008a24`) and skips the correction on a mismatch. A voice with TSTR off
never reads the work.

The module is one ROM cave and one detour, at `0x40098b2c`: the task's table
check right after the copy (`movea.l (a3),a0; cmpa.l 188(sp),a0; beq.s`,
8 bytes). The copy's `+24` (`68(sp)`) zero: the task's own next-voice path
(`0x40098cc8`, where stock goes for a voice it does not analyse), with the
voice's pending bit left clear, so the task sleeps when nothing is pending.
Non-zero: the three displaced instructions, replayed; stock code from there
on.

A skipped voice keeps its table entry and analysis state as they were, as
stock does for any voice it skips. When its TSTR turns on, the next pass
refreshes the entry; until then the renderer's own match decides.

## Why

Recorder buffers looping at the project tempo with TSTR off (sound-on-sound
in particular) give the task work nobody reads: BRAIN showed TASK 98A5C at
30-73% with five to seven such loops (Bryan T's MKII, OCTABAM24 and stock
recorder sources, 24 Oct 2026), and seven aligned loops with USB 4/4 then
stopped the sequencer.

## Measured

Under the ColdFire port, 24 Oct 2026, the core + REC MATRIX image (BUILD 23)
with the cave poked in after the load, 20 s, the analyzer's chunk call
(`0x40098cac`) and the stretch readers watched, the recorder pages compared:

| project | TSTR resolved | stock chunk calls a track | with the module | recordings |
|---|---|---|---|---|
| 5 SOS loops, RLEN 16, 16 steps | 0 | 919-924 | 0 | identical (1.85 MB) |
| 7 SOS loops, RLEN 16, 16 steps | 0 | 852-853 | 0 | identical (2.58 MB) |
| 5 SOS loops, RLEN 64 | 2 | 919-924 | the same | identical |
| 7 SOS loops, RLEN 64 | 2 | 852-853 | the same | identical |

The stretch readers did not run in any of them (the takes play at the
project tempo). A debug copy of the cave logged the byte it tests: 2 on the
playing voices of the TSTR-on project.

Not measured: what it frees on a unit (BRAIN's CPU tab with five to eight
loops), and a project that audibly stretches with and without the module.
