# The Unicorn ColdFire emulator

The firmware's own screens, drawn by its own code, without a flash. Two
routes on Unicorn's CFV4E core:

- **Tier-0** (`tools/emu/emu_bringup.py`): boots a MAIN OS image to the
  RTOS multitasking handoff (`trap #0`, ~7,000,000 instructions, ~4 s),
  then calls draw code directly against the warm machine. What the
  remixer's UNIT pane and the label/formatter gates use.
- **Route A** (`tools/emu/emu_rtos.py`): crosses the handoff and runs the
  firmware's own scheduler (the trap dispatched by hand, every `rte`
  popped by hand, PIT0 as a timer counted in samples, the interrupt
  controllers modelled), loads a project from an emulated card, runs the
  sequencer. ~120× real time, no audio; the oracle the C++ port
  (`docs/history/COLDFIRE_PORT.md`) is measured against.

The bring-up record is `docs/history/EMU_BRINGUP.md`; route A's is
`docs/history/RTOS_FORK.md`.

## Setup

```sh
make emu-setup                       # uv sync --extra emu -> .venv with unicorn + textual
make emu-unicorn                     # route A: the EMAC-fixed Unicorn
.venv/bin/python3 tools/emu/emu_bringup.py [image]
make emu-rtos PROJECT=<project dir>
.venv/bin/python3 tools/emu/emu_rtos.py --project <dir> --set OCTABAM --name RIG --load-project --ms 6000
.venv/bin/python3 tools/emu/emu_rtos.py --project out/_testproj --set OCTABAM --name RIG \
  --sequencer --internal-clock --poke-trig 2 --frames 400 --ms 20000 [--via-key]
.venv/bin/python3 tools/emu/emu_rtos.py --selftest
```

`unicorn` must be given `UC_CPU_M68K_CFV4E`: the default plain-68k core
does not decode `mvz`/`mvs`/EMAC. The `.venv` must be the host's native
architecture (an x86_64 build under Rosetta crashed on its first
`emu_start`).

**Route A needs the EMAC-fixed Unicorn.** Stock Unicorn 2.1.4 computes the
ColdFire's fractional-mode `macl`/`macw` as an unsigned product `>> 32`
where the MCF5445x does a signed product `>> 31`, and reads the MAC/MSAC
bit from the wrong word so `msac` adds. `scripts/build_unicorn.sh` applies
`tools/patches/unicorn_emac_fractional.patch` and builds the m68k-only
library into `.venv/lib/unicorn-emac/`; `emu_bringup` points the Python
bindings at it through `LIBUNICORN_PATH`. `emu_bringup.emac_selftest()`
pins the semantics (`0xc00 × 0x200000` = 3, `−0xc00` = −3, `msacl` = −3);
`emu_rtos.py` refuses a stock EMAC unless `--stock-emac`. The
EMAC-with-load shim keeps one trampoline slot per distinct instruction
(a rewritten trampoline is not retranslated).

## What the boot needs

Reset state: `SR = 0x2700` before `A7 = 0x48000000` (SR first, or the
supervisor/user stack banks swap). Peripheral MMIO is modelled by callback;
default read = all-ones satisfies every wait-until-set poll. One value is
load-bearing: the firmware reads `0xfc0c4000`, takes the top byte as the
PLL multiplier, and halts at `0x4000fa8c` unless `(reg>>24) × 12 MHz`
equals 264 MHz, so the harness returns `0x16000000`. Async completion
flags are auto-poked after the write that starts each operation.

| region | what it is | notes |
|---|---|---|
| `0xfc0c4000` | clock/PLL config | load-bearing (above) |
| `0xfc0a4066/69` | serial/UART-ish | writes `0x43`, `0x33` |
| `0xfc064000..01c` | a serial/timer module | status polled at `+4` |
| `0xfc048018..05b` | another module | writes `0x1b`, `0x06` |
| `0xfc088000/02` | serial shift-out (shift-done in bit 2) | write datum, poll bit 2, 8× |

## Drawing the firmware's screens (Tier-0)

The capture primitive is `FUN_40012bd8`, the draw-string call every
renderer funnels through (189 call sites): `FUN_40012bd8(font, canvas, x,
y, count, char *str)`, cdecl, `sp@(12)=x sp@(16)=y sp@(24)=str`. The detour
recipe: boot to the handoff; install the string-capture hook and a
map-on-fault hook (a cold detour can leave one stale pointer; a zero page
under it makes `strlen` read `""`); `ctl_flush_tb()` (the draw functions
were JIT-cached during the boot splash without the hooks); call the window
open (`FUN_40064c18`); set `[0x400cbf40]=1` and `[0x400cbd9c]=6` (the
visible-row clamp; the row loop bound is `min(clamp, count)`); poke
`[0x400cbd98]` = cursor row; call the draw (`FUN_40064d7c`). The line
pitch is 7 px, larger y = higher row. The selection highlight is an XOR
rect (`FUN_40012254`), not captured.

`render_menu(r, cursor)` returns the MAIN MENU as `(x, y, string)` tuples;
`render_fx2(r, track, effect_id)` / `render_fx1(...)` render the real FX
parameter pages with the effect assigned (the chooser column plus the
twelve knob rows, both pages). `tools/build/stock_labels.py` and
`tools/verify/verify_labels.py` / `verify_modenames.py` call display
formatters through the same machine. Item-level descent inside the menu
(a submenu item, a param page reached by key) needs the real key handler
`FUN_40064e64`, whose keycodes are position-dependent; repointing the
display at a submenu descriptor directly lands the labels at a bogus x.

## The card (route A)

`tools/emu/emu_card.py`: a pure-Python FAT16 image builder (a SET folder
holding a PROJECT folder → an MBR + FAT16 image the firmware's mount code
accepts; VFAT long names), an ATA task-file model at the FlexBus window
`0x90000000` (IDENTIFY advertises PIO only, so the driver never programs
the on-chip DMA channel), and one wait hook past the RTOS: the PIO
handlers only program the registers, and the data phase is the ATA
interrupt handler, so `attach()` hooks the queue primitive `0x40000818`
and performs the transfer the handler would when a command is in flight.
The set name needs a leading `/`; a WRITE's count byte is the remaining
count.

## Limits

No audio, no display pixels (strings only), no key matrix; route A models
no DSP. The C++ port (`make emu-cf`, `tools/emu/ot_emu`) runs both DSP
cores and the host port and is what `make check`'s boot verifier uses.

## The C++ port on a project

```sh
.venv/bin/python3 tools/emu/ot_emu/stage_card.py PROJECT_DIR OCTABAM RIG --out out/card.img \
    [--audio "SRC.wav:RIG/name.wav" --audio "SRC.ot:RIG/name.ot"]   # a sample the part plays
out/emu/ot_emu --image out/mainos_bus.bin --card out/card.img --set OCTABAM --project RIG \
    --sequencer --internal-clock --frames 600 --load-ms 20000 --dsp --main-level 64 \
    [--poke-trig 2] [--audio-in tone.wav] [--block-dump F] [--audio-out PREFIX]
```

- The project's `[STATES] BANK=` is the bank that plays; `--bank N` selects
  live and the transport start re-applies the saved bank's part over the
  live lane (half of the live id array was the other bank's after three
  frames, 15 Sep 2026). Write the fixture into the saved bank.
- Samples: `stage_card.py` skips `.wav`/`.ot`; `--audio` stages one at its
  card path. FLEX and STATIC (measured 15 Sep 2026: TSMODE 0 fits the file
  at unity, −69 dB) both play. `--main-level` is required for any voice.
- Cost: the 20 s load ≈ 40 s wall; ≈ 15 frames/s with both cores live.
- A panel action: `--poke-early ADDR=BYTE` (before the call; `0x80000000`
  is the current track), `--call ADDR,arg,...` (a firmware routine as
  main, after the load) and `--call-at N` (the same call N frames after
  the transport start, so the part re-apply does not erase an edit).
  `--poke` writes after the load, before the frames.
- Watches: `--watch-mem ADDR,LEN[;ADDR,LEN...]` (every write, with the
  PC), `--watch-read`, `--watch-pc`, `--dsp-watch core:X|Y|P:addr`,
  `--dsp-pcwatch core:pc`, `--dsp-peek core:X|Y|P:addr,len` (upper-case
  space letter), `--mem-dump addr,len=file`.
- The record a track's DSP instances read is `0x80000110 + 64·t` (32
  halfwords, `docs/firmware/MIDI.md`); the page-2 lane `0x80000810 + 72·t`.
