# REC MATRIX: quantized switching (planning note)

Planning, 26 Oct 2026; stock's timing traced 29 Oct 2026 (section "How
stock places a quantized recorder event"). Nothing of MTRX's side is built.

## Goal

A MTRX selection change that commits on the sequencer's beat grid: on a
trig, or a fraction of one (1/2, 1/4), landing on the same sample a stock
recorder trig on that step would. Finer than stock's QREC/QPL ladder, whose
smallest unit is one step (`0x400d80e0`: 1 2 3 4 6 8 12 16 …).

Considered and set aside: committing at each recorder's own loop wrap
(LOOP). It suits free-length loops but is per recorder, can wait a whole
loop, and is not tied to the sequencer. Beat-grid is the direction.

## How a switch is timed now

`rmx_select` reads the mask on every write-path call, so an edit takes
effect at the first call after the UI task writes it, and the 64-sample
ramp starts there. The switch lands when the key press clears the panel
scan and the UI task, rounded to a call boundary: unquantized, with jitter
set by UI latency. Not measured.

## What stock gives us (from the docs)

- The sequencer tick is its own interrupt, vector `0x60`, `0x400a1e0c`
  (`KERNEL.md`, `MIDI_SCENES.md` section 5), not the frame ISR.
- Audio-track actions are staged by `FUN_40005178` (`0x800018be/de`) and
  moved to the immediate mailbox `0x46c7e9fa` by the per-tick comparator
  `0x4000b308` when their quantise class fires (`RECORDER.md` section 1,
  `ARCHITECTURE.md`).
- The per-frame dispatcher `0x4000d2a0` calls each recorder's write path
  twice a frame, `(0, n)` and `(n, 16)`, with the arm handler between
  (`RECORDER.md` section 2). n is the event's sample offset within the
  frame: ✅ traced 29 Oct, next section.
- Recorder lengths are in 44.1 kHz samples; one 16th is `661500 / BPM`
  samples; `tempo24 = BPM × 24` (`RECORDER.md`).

## How stock places a quantized recorder event (traced 29 Oct 2026)

Read from `section_3_MAIN_OS.bin` (SHA-256 `164f3122…af0a84e`) with
`objdump -m m68k:cfv4e`; the in-frame values were watched under the port
(`ot_emu --watch-mem`, stock image, empty project, PLAY pressed).

- **Position.** `0x46104cf4` is the transport position in units of
  1/tempo24 sample: it advances `[0x80001814] << 4` (tempo24 × 16) per
  frame (`0x4000a99e`). `0x46104cf0` is the end of the current frame,
  the same plus one frame (`0x4000aeb4`).
- **The tick.** The frame code counts `0x46107570` down by tempo24 × 16
  per frame; when it reaches zero or below it saves the overshoot in
  `0x46107574`, parks the counter at `0x7fffffff` and forces the sequencer
  tick (INTFRCH bit 0, `0x4000a9e4` / `0x4000ae00`). The tick handler
  reloads the counter and adds the overshoot back (`0x400a4ef2..0x400a4f06`),
  so ticks do not drift. Reload values: 2,646,000 (one 24 PPQN clock in
  these units) and 661,500 (96 PPQN). 🟡 Which one runs when (internal
  versus external clock, `0x80001860` and bit 0 of `0x80000028`) is not
  traced.
- **The event table.** The sequencer handler writes upcoming event
  positions, one tick ahead, into 62 longs at `0x80001904`
  (`0x400a2e18`: the tick's position `0x4610757c`, plus a term read from
  `0x46c7a830` indexed by slot, plus a multiple of 2,646,000; 🟡 what the
  `0x46c7a830` term is, micro-timing or otherwise, is not traced). 🟡 The layout looks like 8
  tracks × 7 slots plus 6 globals (entries 58 and 59 are globals,
  `0x4009bba8`, `0x4009c380`); inferred from the indexing.
- **Per frame, to samples.** `0x4000aee0` turns every entry into a byte at
  `0x800017d6 + i`: `(entry − frame end) × [0x80001820]` by EMAC
  (`0x80001820` = −2³¹ / tempo24, so this is the distance in whole
  samples) + 16, negatives clamped to 0. The byte is the event's sample
  index counted from the start of this frame: 0..15 lands in this frame
  (0 also covers "already past"), 16 or more is still ahead. It is a
  byte, so far-future values wrap; stock only reads it when the tick
  fires. Under the port, entry 59 (`0x80001811`) counted `0x59 0x49 0x39
  0x29 0x19` and then landed at sample 9.
- **Into the mailbox.** When a staged action's quantise class fires, the
  comparator ORs entry 59's byte into it as it moves the action to the
  immediate mailbox (`0x4000b37a`: `[0x80001811] | staged`). Entry 58
  (`0x80001810`) goes the same way into `0x46104d14` (`0x4000b2a2`).
- **Into the write.** The frame ISR copies each track's mailbox word into
  `0x46104d26 + 2 × track` (`0x4000ca7a`); the dispatcher splits that
  recorder's write at the word's low nibble, runs the event between the
  two halves when `word & 0xd0`, then keeps only the nibble (`0x4000d378`).

So a stock quantized recorder start lands on an exact sample inside the
frame, and the audio side keeps sequencer position finer than a tick
(1/tempo24 sample). Unknowns 1 and 2 below are answered by this.

## Sketch

- An edit with QUANT set writes a pending mask and its target grid point,
  not the live mask. The pending trig blinks (orange, flashing) until it
  commits.
- The target is a position in stock's units (`0x46104cf4`'s), so 1/2 and
  1/4 trig are only different spacings: one 16th is 15,876,000 units at
  any tempo (661500 / BPM samples × tempo24).
- Each frame, MTRX converts the target to a sample index with
  `0x4000aee0`'s formula against `0x46104cf0` and `0x80001820`, keeping
  the full value rather than a wrapping byte. MTRX keeps its own target
  instead of borrowing one of stock's 62 entries, which belong to the
  sequencer.
- At commit, `rmx_select` splits its own segment at the commit sample: mix
  to that sample with the old targets, switch, mix the rest. It owns its
  block fill, so it does not need stock's `(0, n)` split to line up.
- Every recorder with a pending change commits on the same sample.
- Sequencer stopped: no grid, so QUANT behaves as immediate.

## Open design questions

1. **Which grid.** The recorder's own track scale (2x, 3/4x, 1/2x …) or the
   pattern's master length. "The next trig" differs between them on a
   scaled track.
2. **Where the ramp sits.** Starting at the beat (like a stock trig start)
   or centered on it. Centering starts 32 samples early and must cope with
   a tempo change between prediction and beat.
3. **Which divisions.** For example IMM, 1/4, 1/2, 1, 2, 4, 8, 16 trigs,
   perhaps bar or pattern. One setting per project, or per recorder.

## Unknowns to trace (under the port)

1. ✅ Answered 29 Oct: the comparator fires on the tick, but the action
   carries a sample position. The audio side keeps position in
   1/tempo24-sample units, so a quarter trig need not round to a tick.
2. ✅ Answered 29 Oct: n is entry 59's in-frame byte, ORed in at
   `0x4000b37a`; a stock recorder trig starts mid-frame.
3. Baseline: the key-to-switch latency of an unquantized edit today.
4. How a scaled track (2x, 3/4x, 1/2x …) and the pattern's master length
   show up in these positions, for open question 1.
5. Whether a tempo change between the target being set and the commit
   needs handling: the target is in position units, so it should stay on
   the beat, but the conversion uses the frame's tempo.

## Other ideas from the same session (not pursued yet)

- **Per-Part matrices.** SRC3 is per Part, the matrix per project; per-Part
  masks would make a Part switch a routing scene, crossfaded by the ramp.
- **MIDI with one CC.** The track's MIDI channel picks the recorder; the
  CC value carries the operation (for example 0–15 toggle, 16–31 set,
  32–47 clear source n, plus clear row). State echoed back for controller
  LEDs. Full-mask recall later, by SysEx or NRPN.
- **Editor shortcuts.** FUNC + trig to solo a source, clear row, copy and
  paste rows, a one-press chain preset (Tn samples Tn−1); dim rows not on
  MTRX in the current Part; blink rows that are recording.
- **Take-start offset.** The README's Open list notes stock starts a
  track-sourced take one frame earlier than MTRX. Whether that shifts a
  loop's phase on playback, and so accumulates over a chain, is untested.
- **Cost.** Recorders gather shared sources separately. Meter 7 and 8 dense
  MTRX recorders against stock SRC3 with LOAD METER before optimizing.
