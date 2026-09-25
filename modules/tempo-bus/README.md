# TEMPO BUS

The TEMPO window edits the bus engines. [TEMPO] opens it at the menu
window's size (118 × 64), with two boxes, DELAY and REVERB. The boxes list
each engine's parameters with the values the host page would show.

| control | does |
|---|---|
| A | moves the cursor in the focused box (the box scrolls, four rows visible) |
| B | edits the selected parameter on the host track; ×7 while B is pushed (the stock fast turn) |
| LEFT / RIGHT | focus DELAY / REVERB |
| LEVEL | BPM (stock) |
| UP / DOWN | the tempo step (stock) |
| C–F | held while the window is open |
| [TEMPO], [YES], [NO] | close (stock) |

The header prints the tempo as `TEMPO 121.2`. It prints `PTN TEMPO` while
the pattern tempo is on, using the same test the stock TEMPO draw uses
(`0x80000024`, `0x460d1aec`).

- **Rows and labels.** The rows are each engine's named slots, taken from
  its manifest when the remix is built. Labels are the engine descriptor's
  names, so a mode's `---` and GLEN/SLEN show here as they do on the host
  page. The MODE row is labelled MODE, and its value is the mode.
- **Values.** Values are printed by the slot's own formatter: TEMPO SYNC's
  divisions, the select labels. A slot with no formatter prints a plain
  number.
- **Page-1 edits** go through the firmware's page-1 writer
  `0x40054cd8(track, 24 + slot, value)`.
- **Page-2 edits** make the FX2 page-2 editor's stores: Part `+0x8f084`,
  shadow `0x100a51d2`, live lane `+0x38`, and the four dirty flags. This is
  CC MAP's write path. When MODE DEFAULTS is linked before this module,
  its `CC_MODEDEF2` then applies the view, so a MODE change re-defaults
  its knobs as it does on the panel.
- **Clamping.** Values are clamped to the descriptor's minimum and count.

## How

| site | what |
|---|---|
| `0x40059f04`, `0x40059f08` (pokes) | the TEMPO window is created at 118 × 64 instead of 73 × 48 |
| `0x40059f2c` (detour) | the opener's tail: push this module's input layer over TEMPO's, draw |
| `0x4004b528` (detour) | the TEMPO draw, for every caller (BPM edits included): the bus screen |
| `0x40056930` (detour) | the TEMPO close: pop the layer, then the stock close |

Every draw call is one the stock CONTROL INPUT (`0x40065674`) and MIDI
SYNC (`0x4006730c`) screens make:
- header text `0x40012bd8` and its width `0x40012f30`, in font `0x400ba876`;
- the CONTROL icon `0x400128a8(0x400cbc5c, …)`;
- the rule `0x40011910`;
- the titled box `0x4007efd0`, with the focused box's title inverted;
- rows at a 7-pixel pitch;
- the invert bar `0x40012254`.

The input layer format is in `docs/firmware/MAINMENU.md` §6c.

Two units, both pinned in measured free runs:
- `helpers.s` (314 B) at `0x400d24d0`, the start of the overflow run. The
  floating caves take the run after it.
- `tempobus.s` (1,316 B) at `0x400d64e0`, below the FX2 chooser's NONE
  row.

## Measured

- **Under the port** (`tools/verify/verify_tempobus.py`, in `make verify`
  with OT_PROJECT), on verify_set's staged card:
  - TEMPO opens the 118 × 64 window.
  - Delay MODE → GRAIN lands on the host's page-2 lane, with GRAIN's view
    applied.
  - Delay FDBK set to 5 and reverb SEND set to 3 land on the hosts'
    page-1 lanes.
  - Close leaves the window handle 0 and no layer of this module
    registered.
  - The run ends on quit.
- **The port also:**
  - rendered the window planes (`out/tempobus/screen.png`);
  - raised the BPM by 5.1 through LEVEL with the window open;
  - reopened the window after a close;
  - with the window closed, gave knob A to the page behind.

## Not measured

- Anything on hardware.
- The MKII keymap: the port boots the MKI one. TEMPO, LEFT and RIGHT have
  the same codes in both.
- EXT SYNC: the header prints the internal tempo, where the stock window
  prints the external one.
