# The ColdFire's time, by task, on a unit

Where the ColdFire's time goes with FLEX, STATIC and sound-on-sound recorder
tracks playing, measured on Bryan T's MKII on 26 Oct 2026 (BUILD 29, the
`task-meter` remix: BRAIN, USB, LOAD METER, RECORDER LOOP FIX, LOFI AMF FIX
over stock). The question was how much the sample analyzer, TASK 98A5C
(`0x40098a5c`, KERNEL.md), costs; the answer moved the attention to the frame
interrupt.

## 1. The instrument

- **The task ledger.** BRAIN's scheduler detour (`brain_sched`,
  `modules/brain/hooks.s`) charges the DMA timer 3 counts (132 MHz) since the
  last scheduler entry to the task that was running, into `brain_ts`: 12 slots
  of {TCB, running total}. USB serves it as vendor request `0xc0/0x57`
  wValue 4 (96 bytes, `modules/usb/usbaudio.s`); `tools/hw/task_meter.py`
  polls it, takes the deltas modulo 2^32 and turns them into shares. On the
  unit a 5 s poll read 5.10 s of timer counts.
- **The frame interrupt's share** comes from LOAD METER's `lm_stats`
  (block 0). The interrupt's time lands on whichever task it interrupted, so it
  is reported as FRAME IRQ and taken off the tasks in proportion to their
  shares, as BRAIN's CPU tab does (`cpu_update`, brain.c). That proportional
  split assumes the interrupt arrives independently of the task switches
  (inferred). The CSVs keep the raw shares beside the corrected ones.
- **The conditions** come from `tools/hw/analyzer_sweep.py`: one generated
  project, every condition a pattern, stepped over USB MIDI (STOP twice, a
  program change, START, 3 s to settle, 10 s measured). FLEX and STATIC: eight
  test samples (noise hits and a tone, one tone per track) in three sets: 4 s
  loop off, 1 s loop on (wraps twice in the 2 s bar), 4 s loop on; TSTR off in
  every slot, 120 BPM, LEN 16. SOS: track t a FLEX machine on its own recorder
  buffer, PLAY + REC1 + REC2 + REC3 on step 1, INAB A B, INCD C D, SRC3 the
  track itself, RLEN 16, LOOP off, TSTR off on the buffers. 1, 2, 4 or 8
  tracks, and BASE (nothing playing). `--usb-in` streams a 997 Hz sine at
  -20 dBFS into all four USB IN channels and checks the IN packets move.
- **Repeatability.** Two runs of the 24-bit SOS conditions (the second labelled
  `sos1b`, run with 24-bit recording still on, as far as is known) agreed within
  0.1-0.7 points at 1, 4 and 8 tracks and BASE, 2.4 at 2 tracks; the FLEX loop
  variants, which should cost the same, agreed within 0.4.

## 2. Results ✅ (one MKII, one run each unless said)

Shares of the ColdFire, corrected as above. USB IN was ON from the card's
settings in every run (`usb_counters.py --in` answered, its state-7 visits
running at the frame rate) but idle unless the row says streaming.

FLEX and STATIC (the loop setting changed nothing: LONG OFF, SHORT ON and LONG
ON agree within 0.4 points for FLEX; the table shows LONG OFF):

| tracks | FLEX: FRAME IRQ | 98A5C | IDLE | STATIC: FRAME IRQ | 98A5C | 91D18 | IDLE |
|---|---|---|---|---|---|---|---|
| 0 | 26.0 | 0.0 | 71.8 | 26.1 | 0.0 | 0.0 | 71.8 |
| 1 | 29.1 | 1.4 | 67.0 | 29.0 | 1.5 | 0.8 | 66.1 |
| 2 | 31.2 | 2.7 | 63.5 | 31.2 | 3.2 | 1.4 | 61.6 |
| 4 | 34.9 | 5.4 | 57.0 | 35.3 | 6.5 | 2.6 | 52.8 |
| 8 | 47.5 | 9.9 | 40.2 | 51.2 | 11.3 | 4.7 | 30.3 |

SOS recorder loops:

| tracks | 16-bit: FRAME IRQ | 98A5C | IDLE | 24-bit: FRAME IRQ | IDLE | 16-bit, USB IN streaming: FRAME IRQ | 98A5C | IDLE |
|---|---|---|---|---|---|---|---|---|
| 0 | 26.2 | 0.0 | 71.7 | 26.3 | 71.6 | 31.3 | 0.0 | 65.3 |
| 1 | 33.6 | 1.4 | 62.0 | 33.9 | 61.6 | 45.8 | 1.6 | 49.2 |
| 2 | 37.8 | 2.7 | 56.1 | 43.5 | 50.4 | 60.8 | 2.6 | 33.4 |
| 4 | 60.6 | 4.2 | 32.3 | 63.4 | 29.2 | 74.7 | 4.5 | 17.6 |
| 8 | 78.9 | 8.1 | 9.3 | 80.6 | 7.0 | 90.9 | 4.9 | 0.0 |

SYS, MIDI, KEYS and UI hold about 2.5 together throughout; STORAGE reads 0 in
every row, STATIC included.

## 3. What they say

- **The analyzer costs about 1.0-1.4 points a playing track,** FLEX, STATIC or
  a recorder buffer, linear in the count, whatever the loop setting. Its real
  cost is small; the STRETCH ANALYSIS GATE frees about that much with TSTR off.
- **The frame interrupt is the budget.** It holds 26% with nothing playing,
  and the recorder loops are what fill it: 78.9% at 8 SOS loops against 47.5%
  at 8 FLEX tracks playing samples. Without USB traffic it rises slowly to 2
  loops and jumps between 2 and 4 (37.8 to 60.6), as FLEX does between 4 and 8;
  why is open.
- **A streaming USB input and the recorders compound.** Streaming USB IN alone
  adds 5.1 points to the frame interrupt (BASE); with recorder loops running it
  adds 12-23 points at every count, and 8 loops reach 90.9% FRAME IRQ and 0.0%
  IDLE: no time left for the engine, the UI or the analyzer (squeezed to 4.9
  from 8.1). That is the unit's stall with seven aligned loops and USB IN (24
  Oct 2026). What in the recorder path pays for USB IN is not traced. 🟡
- **24-bit recording adds 0-6 points** of frame interrupt (about 2 at 8 loops;
  16 vs 24 bit, same conditions); the sample width is not what drives the climb.
- **TASK 91D18 runs only for STATIC voices,** 0.6 points a track with 4 s files
  and about half that with 1 s loops, and nothing for FLEX: very probably the
  STATIC streamer. Inferred from its load alone; its code is not read. 🟡

## 4. Corrections

- ❌ "TASK 98A5C takes 30-73% with five to seven SOS loops" (BRAIN's CPU tab,
  24 Oct 2026). The raw ledger charges 98A5C 38.5% at 8 SOS loops because the
  frame interrupt, at 79%, mostly lands on it; corrected it is 8.1%. BRAIN only
  takes the interrupt off the tasks when LOAD METER is in the image
  (`load_now[0]`); without it the CPU tab shows raw shares. The gate's measured
  gain on that build (IDLE 51-87%) is overstated the same way: with the
  analyzer gone, the interrupt time it absorbed lands on IDLE.
- ❌ "Only looping FLEX/STATIC samples wake the analyzer" (port, 26 Oct 2026).
  The fixture had no `markers.work` records (STORAGE.md section 4: such a slot
  falls back to 64 frames); with trimmed samples the port and the unit agree
  the loop setting does not matter.

## 5. Open

- What makes the recorder path's frame-interrupt cost grow with an active USB
  input (USB IN's state-7 transfer and the recorder's input reads share the
  frame; `modules/usb/usbaudio_in.s`, RECORDER.md section 2).
- The jump between 2 and 4 SOS loops (and between 4 and 8 FLEX tracks): track
  count, or which tracks (tracks 5-8 are core A)?
- The gate before/after on the same conditions, 8 SOS loops with USB IN
  streaming especially: whether it lifts IDLE off 0%.

## 6. Reproduce

```
make image REMIX=task-meter BUILD=N
python3 tools/hw/analyzer_sweep.py proj EMPTY_PROJECT out/az/ANALYZER   # copy it to the card, load it
python3 tools/hw/task_meter.py --for 5                                   # FRAME IRQ must show
python3 tools/hw/analyzer_sweep.py run out/az/ANALYZER LABEL --reps 1 [--only REC] [--usb-in Octatrack] --midi "Elektron Octatrack DPS-1"
python3 tools/hw/analyzer_sweep.py report out/hw/analyzer/LABEL.csv
```
