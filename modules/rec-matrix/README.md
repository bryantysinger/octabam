# `rec-matrix` — REC MATRIX

A recorder SRC3 value, **MTRX**, that records a sum of sources chosen per
recorder: any of the inputs A, B, C, D, the pairs AB and CD, tracks T1–T8,
MAIN and CUE, mixed at unity and stored with the project.

Stock lets a recorder take INAB, INCD and one SRC3 source. With MTRX in
SRC3, the SRC3 slot carries a mix of as many of the 16 sources as you like,
chosen on a full-screen matrix of all eight recorders and edited on the trig
keys. Changing the selection mid-take fades sources in and out instead of
clicking. Needs BRAIN in the image (the matrix is kept in the project's
`brain.work`).

## Using it

1. Set a track's recorder to MTRX: hold **FUNC** and press **REC AB**
   (RECORDING SETUP 1), and turn **SRC3** past CUE to **MTRX**.
2. Open the matrix: from any page, hold **CUE** and press **MIX**. (On
   RECORDING SETUP 1 with SRC3 on MTRX, pushing **knob E**, SRC3's knob,
   opens it too.) The matrix opens over whatever track is active, on MTRX
   or not: one row per recorder, one column per source, a filled 3×3 box
   where a source is selected and a centred dot where it isn't. The active
   track's row is marked by its number at the left and a pointer at the
   right; the title reads REC BUF *n*.
3. The trigs toggle the active row's sources, and their LEDs show its
   selection in orange, a colour stock's trigs do not use, so the mode is
   plain at a glance:

   | trig | 1–8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 |
   |---|---|---|---|---|---|---|---|---|---|
   | source | T1–T8 | AB | CD | A | B | C | D | MAIN | CUE |

   Columns on the screen follow the same order: the tracks, then the
   stereo inputs, then the mono inputs, then MAIN and CUE.
4. The **track keys** move to another recorder's row, and **UP** and
   **DOWN** step through the rows: UP toward T1, DOWN toward T8, stopping
   at the ends. The track keys light the active track either way.
5. **LEFT** and **RIGHT** set QUANT, when a change takes over while the
   sequencer plays: OFF (at once), 1/2 TRIG, 1 TRIG, 2, 3 or 4 TRIGS,
   stopping at the ends. The first press shows the setting in a toast over
   the matrix without changing it; while the toast is up (0.8 s, stock's
   length, renewed by each press) LEFT and RIGHT step it. The toast's box
   keeps one size for every setting. One setting for all recorders, kept
   in the project with the matrix (BRAIN > SETTINGS shows it as QUANT).
6. **SRC**, **AMP**, **LFO**, **FX1** or **FX2** closes the matrix and
   RECORDING SETUP and goes to that page. (Stock leaves RECORDING SETUP
   open over a page key; the matrix covers the whole screen, so the page
   change would be hidden.)
7. **CUE + MIX**, **NO** or **knob E** closes the matrix and returns to the
   page it was opened from (RECORDING SETUP 1, if it was opened there).

- Every edit is saved to the project's `brain.work` at once, as an edit in
  BRAIN > SETTINGS is. The matrix also shows there, as REC1–REC8 (one
  number per recorder; see "Storage").
- MTRX on a track whose row is empty records silence.
- With GRID RECORDING on, the trigs place recorder trigs as on stock until
  the matrix is open; inside it they edit the matrix.
- A Part saved with MTRX loads on stock 1.40C as SRC3 CUE.

### Mixing

Stock's own rules, so a source sounds in MTRX as it does in INAB, INCD or
SRC3:

- Every source enters at unity; the sum saturates once, at 24 bits.
- **AB** records A left and B right; **A** or **B** alone records that input
  on both sides; **A and B** together (without AB) fold to mono, 0.5 each,
  on both sides. The same for CD.
- A pair and its inputs exclude each other: selecting AB clears A and B,
  selecting A or B clears AB. The newest press wins.
- T1–T8 are the tracks' read-back (post FX2, pre fader), the same tap as
  stock SRC3 T1–T8; MAIN and CUE are stock's MAIN and CUE.

### Ramps

A selection changed during a take ramps each source and side linearly over
64 samples (1.5 ms), so toggling sources while recording does not click.
The pair rules ramp too: A alone to AB keeps A on the left and crossfades
the right side from A to B. A take starts at the current selection, with no
ramp, however the selection changed between takes.

### Timing

QUANT decides when a change to a recorder's selection takes over while the
sequencer plays. OFF: at once. 1/2: on the next half-trig boundary of the
master grid (the pattern's scale). 1 to 4: on the 1st to 4th trig boundary
after the change, counted from the change, so 3 lands three boundaries on
wherever that falls in the bar. The 64-sample ramp ends on that boundary's
sample: it starts 63 samples before, so the new selection is at full level
on the boundary and an attack there is recorded whole. Further edits before it go with it. The
matrix and its LEDs show the new selection at once; the take follows at the
boundary. With the sequencer stopped, and at the start of a take, the
selection applies at once whatever QUANT says. The default is OFF, as
before QUANT. (`QUANT.md` has the design and what is still open.)

## How it works

Two DRAM units (`rmx.s`, the mixer; `editor.s`, the matrix editor), six
detours, three repointed key-layer entries and three pokes. The manifest's docstring
and `Detour` entries list the addresses.

- **The mix.** The recorder write path `0x400068e4(track, page, start,
  end)` picks the SRC3 source at `0x400075de`: 0–7 the read-back block,
  8–9 MAIN and CUE, then joins at `0x40007648` with the SRC3 pointer in
  d5. For runtime SRC3 10 the detour fills one segment of a per-recorder
  block (`rmx_buf`, 8 × 16 stereo samples) with the sum and hands stock
  that block as the pointer, so stock's SRC3 gain and FIN/FOUT ramps,
  INAB/INCD, the old-content path, the saturating sum and the pack all run
  unchanged. The inputs come from the input ring (`0x80005660 +
  page×0x100`: CD at +0, AB at +0x80), the tracks from the read-back block
  (`0x80003190 + [0x800000e4]×0x400 + k×0x80`), MAIN and CUE from
  `0x80005e60`. The sum runs in 24-bit integers (each long's top 24 bits).
- **The ramps.** Each recorder keeps 18 Q15 gains (`rmx_gains`): A, B, C,
  D each to L and to R, then T1–T8, MAIN and CUE. Each call steps them
  toward the selection's targets (`rmx_pair_tab` for the pairs) by 1/64 a
  sample; a gain at unity and staying there skips the multiply. The write
  path runs only while a recorder records, so a selection changed between
  takes would otherwise ramp at the next take's start: a detour in the
  write path's prologue (`0x400068f0`) counts calls (16 a frame, every
  recorder, recording or not), and a recorder unmixed for more than 48 of
  them starts at its targets.
- **The settled path.** Outside a ramp every gain sits on its target (0,
  unity or the A+B fold's half), so a source's share is `s >> 8`, `s >> 9`
  or nothing. `rmx_set` keeps, per recorder, the mask its gains settled on
  (-1 while a ramp runs); while the mask matches, the mix skips the
  per-path gain loop and runs one pass per selected source over the
  segment: the first pass stores (no clear), the last adds and saturates
  (no separate pass). A change runs the general per-path loop until every
  gain reaches its target, then settles again; a new take snaps and starts
  settled. Both paths give the same samples and gains to the bit.
- **The value.** SRC3 is stored as 0 –, 1–8 T1–T8, 9 MAIN, 10 CUE; MTRX is
  stored as 11 and reaches the select as 10. The descriptor's SRC3 count
  goes 11 → 12, and the Part validator's SRC3 maximum (`0x40002cb2`,
  `0x40002cb8`, which rewrites anything larger on every bank load) 10 → 11.
  RECORDING SETUP 1 draws MTRX through its own formatter (`0x4002fc00`).
- **The editor.** Knob E's press field in RECORDING SETUP's key layers
  (MKII `0x400ba4d4`, MKI `0x400ba60c`, entry 9) points at `rmx_knob_e`,
  which opens a 128 × 64 window over the setup window and adds a key layer
  of its own: the 16 trigs, NO, knob E and the five page keys, and null
  handlers for the six knob turns. A page key closes the matrix and the
  setup, then selects its page through the key's own stock handler
  (`0x4005578c`, edge 1); the record's other handler (`0x400322f0`) is
  not called, since with edge 3 it opens the page's SETUP (port). The setup's redraw (`0x4002f2f8`) draws the matrix while it is
  open; the trig-LED refresh (`0x40043fdc`) shows the active row; the
  setup's close (`0x4002ee88`) closes the matrix first.
- **CUE + MIX.** CUE's held key layer (`0x400bf2a0`, shared by the MKI's
  and the MKII's key tables) has no MIX record in stock: with CUE held, MIX
  opens the MIXER as alone. Its key list (`0x400bf122`) is repointed to a
  copy, made from the stock image at build time, with a MIX record after
  stock's. The handler opens RECORDING SETUP 1 through stock's FUNC + REC1
  handler (`0x4002ff84`, which also turns an open SETUP 2 to SETUP 1),
  then the matrix; if it opened the setup, closing the matrix closes it
  too, through the setup's own close.

### Storage

One BRAIN Number per recorder, REC1–REC8, PROJECT scope, store
`octabam.rec-matrix`, applied live. Each is a 16-bit mask: bit 0 A, 1 B,
2 C, 3 D, 4 AB, 5 CD, 6–13 T1–T8, 14 MAIN, 15 CUE. BRAIN's Numbers are
signed, so a row with CUE selected reads negative in BRAIN > SETTINGS.

### Memory

DRAM, in the octabam payload: `rmx_buf` 1,024 B, `rmx_gains` 576 B, the
call counter and per-recorder stamps 36 B, the settled masks, ramp flag and
pass list 132 B, plus the two units' code and tables.

## Measured

Quantized switching, under the port, 29 Oct 2026 (empty project at 120
BPM, SRC3 = MTRX on T1, a take running, REC1 changed mid-take):

- **On the step.** The target was the transport start + 6 steps exactly
  (95,256,000 position units), and the split fell on sample 3 of the frame
  holding it, the sample stock's own arithmetic gives for that position.
- **In the take.** Numbered input (each input sample carries its index):
  the take is silent up to the commit, then A and B ramp in, gain 1/64 on
  the first sample and unity 63 samples later, bit for bit.
- **Stopped.** A change made with the sequencer stopped switched 21 samples
  after the key reached the firmware (the editor wrote it 6 samples after
  the key; the mixer took it in the next frame). A change left waiting
  when STOP was pressed switched in the next frame.
- **The ramp ends on the boundary** (29 Oct, QUANT 1, a change at trig
  8.2): the commit fell 63 samples before trig 9's sample, so the ramp
  (unity on its 64th sample, as measured above) reaches unity on it.
- **The divisions** (29 Oct, the editor's LEFT / RIGHT): QUANT 3 with the
  change at trig 8.79 (counted from the transport start) committed on
  boundary 11; QUANT 1/2 at 8.21 on 8.5 and at 15.99 on 16.0, 40 samples
  after the change. The toast draws over the matrix and the matrix is
  whole after it.
- **The arrows and the toast** (30 Oct): the first RIGHT showed QUANT OFF
  and left it at OFF; RIGHT, RIGHT and LEFT inside the toast's 0.8 s set 1,
  2, 1; after the toast had closed, a press showed it again unchanged. The
  box was the same size for QUANT OFF and QUANT 1/2 TRIG (screen captures).
- **Stock's QREC, alongside.** A stock REC AB with QREC on T2 in the same
  run: its event was computed for sample 8 of its step's frame, as MTRX's
  is, but the take's first sample came 80 samples (5 frames) later than the
  grid places it, at the same in-frame sample 8; the arm followed the
  mailbox event by 84–85 samples in two runs. MTRX switches on the grid.

Under the ColdFire port (`ot_emu`), 17–18 Oct 2026, project MTRXTEST,
24-bit recorders, a tone on inputs A–D and T1:

- **The sum.** REC2 = A + B + T1 on T2: the take is T1 at stock's own
  read-back gain (0.98444, as stock SRC3 = T1 records it) plus 0.5(A + B)
  at gain 1.0000000, within 2 LSB over 19,120 samples. REC2 = A records A
  on both sides bit for bit. No `brain.work`: silence.
- **The settled path** (24 Oct 2026). The mixer rewritten to skip the
  per-path loop once the gains settle. In a ColdFire model (Unicorn) the
  old and new `rmx_select` side by side over 120,000 random calls (masks
  over all 16 bits, mid-take changes, new-take snaps, partial segments,
  saturating levels): every output sample, gain and stamp equal. Per
  recorder per frame, settled: AB + own track 1,938 → 758 instructions,
  one track 1,634 → 408, A+B fold + track 3,058 → 834, all 16 sources
  4,042 → 2,384; a ramp frame about the old cost. Under the port, 8 tracks
  recording 12 s with three mid-take changes, the image as built against
  the same image with the new routine: AB + own track and a chain
  (T n from T n-1) record byte for byte the same; the whole ColdFire goes
  30,587 → 26,988 and 30,351 → 25,770 instructions a frame. With wide
  masks on all 8 rows the old mixer halted the port at stock's frame check
  (`0x4000ab40`) or glitched 11 samples; the new one ran clean, and every
  call logged before the halt matched.
- **The ramps.** A switched off and back on mid-take (the mask poked from
  outside at two frames): the take follows the Q15 model exactly, a
  64-sample linear ramp down and up (also 128, before the length was
  settled). A alone to AB: L stays A throughout; R crosses from A to B over
  the ramp. A take's first sample is at full gain.
- **The editor.** Knob E opens the matrix only on RECORDING SETUP 1 with
  SRC3 on MTRX; the trigs toggle the active row with the pair exclusions;
  the track keys move the row; NO and knob E close it; each edit lands in
  `brain.work`. Three openings in a row behave the same (see "Notes").
- **CUE + MIX** (19 Oct 2026, MKII): opens the matrix from the pattern
  page, on a track whose SRC3 is not MTRX too; the trigs edit it; NO and
  CUE + MIX again return to the pattern page; from an open SETUP 2 it
  opens over SETUP 1 and NO returns to SETUP 1; a second opening works;
  MIX alone still opens the MIXER. The MKI's layers point at the same
  CUE layer; the MKI itself not run.
- **Page keys** (19 Oct 2026): AMP inside the matrix (opened by CUE +
  MIX) lands on the AMP page, FX1 (opened by knob E) on the FX1 page,
  with the matrix and the setup closed; the matrix opens again after.

## On the unit

Bryan T's MKII, images built from this module:

- 17 Oct 2026, BUILD 1 (a hard-coded matrix) and BUILD 2 (REC2 from the
  project's `brain.work` = A + B + T1): MTRX on T2 records T1 with A and
  B. REC2 edited in BRAIN > SETTINGS is saved to `brain.work` and read back
  on reload.
- 17 Oct 2026, the editor: a second opening of the matrix lost the track
  keys and NO, intermittently. Fixed (see "Notes"); the fixed build and
  BUILD 6 (the row number and pointer) were used at length for
  sound-on-sound looping and work as intended: passes chained through as
  many as seven tracks (T1 sampling T7, T2 sampling T1, … T7 sampling T6),
  with the inputs, MAIN and CUE mixed in. The trig LEDs show the active
  row and return to stock's display when the matrix closes.
- 18 Oct 2026, the trig LEDs' colours (a test build lighting each trig's
  two LEDs at fixed levels, 0–15): the first LED is red, the second green.
  15/0, 15/1 and 15/2 read red; 15/4 red-orange; 15/8 orange; 15/15 and
  6/6 yellow; 0/15, 8/15, 4/15, 1/15 and 0/6 green; level 2 alone dim.
  The editor lights a selected source 15/8, orange (BUILD 9).
- 18 Oct 2026, BUILD 7 (128-sample ramp) and BUILD 8 (64): toggling
  sources mid-take no longer clicks; 64 kept.
- 19 Oct 2026, BUILD 10 (CUE + MIX) and BUILD 11 (page keys): CUE + MIX
  opens and closes the matrix from other pages, and a page key inside it
  goes to that page; both work as intended.
- 29 Oct 2026, quantized switching: a step-quantized switch (the proof of
  concept), then QUANT's divisions on LEFT / RIGHT with the toast, then the
  ramp ending on the boundary; each works as intended.

## Inferred

- That the write path's prologue runs for every recorder every frame,
  recording or not (`docs/firmware/RECORDER.md`, the per-frame dispatcher
  `0x4000d2a0`). Falsified by a ramp at a take's start after the selection
  changed between takes.

## Open

- An MKI.
- A `brain.work` created on a Mac is not read by the unit; one the unit
  created and the Mac edited in place is. The cause is not known (the
  firmware's own file has the same 8.3 short name). To be raised with
  BRAIN once BRAIN is more settled; it is still under active development.
- Stock starts a take sourced from a track one frame earlier than one
  from MAIN, CUE or MTRX. Left as stock does it.
- A ramp length in BRAIN > SETTINGS (card scope) instead of the constant
  `RAMP` in `rmx.s`. Planned.
- MIDI control of the matrix.
- Whether stock's 5-frame QREC start lag (Measured) holds on the unit is
  untested.
- Not tried together with REC THRESHOLD or the other RECORDING SETUP
  modules. No hook site is shared with any module in the tree (18 Oct).

## Gates

None yet. A `tools/verify/verify_rec_matrix.py` gate is planned along the
lines of the measurements above: the sum against stock's SRC3 = T1 take,
the mask rules, the ramp against the Q15 model, and the editor's keys.

## Notes

- **Opening a window closes older ones.** The window constructor closes
  listed windows of the same level or higher by calling their close
  callbacks, stale ones included. The first editor's callback, left
  unguarded, closed the next editor as it opened: the second opening lost
  its key layer. `rmx_win_closed` now does nothing without an open matrix,
  and the window opens before the editor's flag and layer are set.
- **The row marker.** An inverted row was tried and dropped: it flips the
  boxes' meaning (filled = selected), which misreads with a diagonal of
  tracks selected.

## Thanks

- [Sam Banks](https://github.com/sambanks), octabam's author: the build,
  BRAIN, the hooks and their checks, and the ColdFire port this was
  measured under.
