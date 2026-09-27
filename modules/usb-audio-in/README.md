# USB AUDIO IN: four channels from the host into inputs A–D

The Mac sends four 24-bit channels at 44.1 kHz over UAC2 on EP3 OUT, and they
arrive on the Octatrack's inputs A, B, C and D in place of the jacks. When the
stream is closed, A–D are the jacks again. Remix `usb-io` =
USB MIDI + USB AUDIO MC + USB AUDIO IN + the stock effects minus SPATIALIZER.

Bryan T, with Claude, 26 Sep 2026, as USB AUDIO OUT on the `usbin-test`
branch (draft PR #468); ported onto the current layouts and renamed for the
unit's point of view on 27 Sep 2026. The USB endpoint keeps USB's own
host-centric name, EP3 OUT.

## How it works

**Descriptors** (`modules/usb-midi/descriptors.py`, `with_in`):
- AudioStreaming interface 5, alt 0/1, with EP3 OUT: 4 ch × 24-bit in 4-byte
  subslots, 192 B every 250 µs at high speed. It is iso asynchronous and fed
  by IT `0x13` → OT `0x14`.
- EP3 OUT is the only free endpoint (EP1 mass storage, EP2 MIDI, EP3 IN
  audio), so there is none for explicit feedback. EP3 IN is marked as the
  **implicit-feedback** data endpoint (`bmAttributes 0x25`), and the host
  sizes each OUT packet from the IN stream's.
- It needs a USB AUDIO layout beside it for that feedback: **USB AUDIO MC**
  (MAIN L/R + CUE L/R, the four channels usbin-test forced with `AUD_IN4`),
  FULL or EXTENDED. The descriptor unit refuses a remix without one, and one
  with MASTER (a 1 ms input stream; this stream's feedback was built and
  measured against 250 µs). With MC, all four configuration descriptors are
  byte-identical to the ones usbin-test's `usb-io` served on Bryan T's MKII
  (both generators run side by side, 27 Sep 2026). Without this module they
  are byte-identical to main's.

**ColdFire** (`usbaudio_in.s`, a DRAM unit):
- `in_setiface_shim`, a detour after usbaudio's SET_INTERFACE shim:
  interface 5 records the alt setting and ACKs.
- `in_state7_shim`, a detour on the frame-transfer state machine's state 7
  (`0x40004bc0`). It is the one owner of EP3 OUT:
  - brings it up and down;
  - retires completed dTDs into a 1,024-frame ring;
  - self-heals the queue;
  - then runs a **second eDMA transfer** per DSP frame to core 0: 16 frames
    to `$6320` in the idle bank, in DSP slot order C, D, A, B, with a stream
    flag in bit 8 of the first low halfword.

  The stock frame-IRQ unmask runs on the second visit.
- Cushion `IN_TARGET` = 384 frames (8.7 ms).
- The **dTDs and packet buffers are in on-chip SRAM** at `0x80007c00`, and
  the EP0 reply buffer at `0x80007f80`; see *SRAM*.
- `in_ctrl_shim`, a detour on the EP0 stall store (`0x4001de6e`), answers
  the diagnostic vendor requests.

**DSP** (`rx_inject.asm`, 24 words in SPATIALIZER's space on payload A,
hooked at `P:0x88`):
- If the host word at `$320` of the bank carries the flag, it copies the 64
  words over the last completed RX block (`X:$202`).
- Every instruction form has a stock precedent.

## The click bug and its fix (the finding that matters for usbaudio too)

**Symptom.** At first, about 1 OUT packet in 2,000 idle, and 1 in 200 under a
busy project:
- completed with the dTD transaction-error bit;
- 2–12 bytes short, at the end only;
- each one dropped a frame, heard as a click on all channels at once.

**Cause** (MCF54455RM, NXP's public reference manual: ch. 10 USB, 14 SCM,
15 XBS).
- In device mode the controller has **one 16-byte RX FIFO** (10.4.3), about
  270 ns of slack at 480 Mbit/s.
- **SCM BCR (`0xfc040024`), which enables USB bursting over the crossbar,
  resets to 0**, and nothing sets it: the unit read 0 on stock boot.
- So the FIFO was emptied one beat at a time. Under load it overflowed near
  the end of a packet, and the controller flagged a CRC error. For ISO RX,
  transaction error = CRC or fulfillment. The data before the cut was clean,
  checked under digital silence.
- Stock's USB traffic is bulk and retried, so it never shows.

**Fix**, in `in_up`:
- BCR = `0x3ff`.
- On SDRAM (XBS slave 2) and the SRAM backdoor (slave 4), USB first under
  fixed priority: PRS = `0x60504321`, CRS = `0x10`. Stock is PRS
  `0x65403210`, USB at level 6 of 7, and CRS `0x110`, round robin.

**Measured on the unit, same busy project:**

| Setting | Bad packets |
|---|---|
| Stock | 1,189 / min |
| BCR on | 5–11 / min |
| BCR on + USB first | **0 in 10 min**, no audible or UI change |

EP3 IN (the stream to the Mac) and DISK MODE very likely benefit too.
Arguably these settings belong in usbaudio or the platform rather than here.

**Ruled out on the way:**
- The cable and the port.
- Queue and service timing (`dry`/`late` 0).
- USBMODE.SDIS.
- RXPBURST 1–8 (16 exceeds the FIFO and fails every packet).
- Buffers in SRAM alone.
- A 4-channel EP3 IN stream alone.
- Bit errors.
- dQH Mult 0 (Linux's ISO RX choice), which kills the stream: this
  controller needs Mult ≥ 1.

## SRAM

`0x80007c00`–`0x80007fff` (1 KB) holds the dTDs, the buffers and the EP0
reply. Evidence that it is free:
- The stock image's highest static SRAM use is the 768-byte buffer at
  `0x80007574` (`0x40098890`), ending `0x80007874`.
- No module touches anything above `0x80006907`.
- Under the port, nothing touches `0x80007874`–`0x80007fff`: boot, frames
  and USB streaming, and Bryan's busy project via
  `tools/verify/verify_set.py --extra "--touch-map 0x80000000,0x8000=…"`
  plus `tools/verify/sram_census.py`.
- RAMBAR1 is `0x80000235`, so the backdoor is on for bus masters.

SRAM is not cached, so no alias is needed.

## Diagnostics (debug tools; strip or gate before shipping)

**EP0 vendor requests:**
- `0x56` GET: USB AUDIO IN's 28 counters (`tools/hw/usb_counters.py --in`):
  fill watermarks, underruns, and `err`/`partial`/`errmask`/`lasttok` for bad
  completions.
- `0x57` GET: read any long in `0xfc000000..`.
- `0x58`/`0x59` OUT: write the low/high half of an allowlisted register.
- `0x5b`/`0x5a` OUT: stage a high half, then write the whole long in one
  store. The XBS PRS registers bus-error on any intermediate value with two
  masters on one level.

**`tools/hw/usb_reg.py`** drives these: `show`, `peek`, `poke`, `poke32`,
`usbprio on|off` and `sdis`. It checks PRS values before sending.

`0x57` can read any peripheral address. A read with no register behind it can
take an access error.

## Verification

- **Under the port:**
  - `tools/verify/verify_usb_in.py`, this module's gate (`make check` runs it
    for any remix that carries it): bit-exact C D A B in the RX blocks and
    the recorder ring (which the DSP copies only while it sees the flag), the
    counters over `0x56`, and the flag clear and the jacks back after alt 0. EP3 IN's frame size comes from the remix's layout, so the
    same gate runs beside MC, FULL or EXTENDED. The port does not model
    SCM/XBS, so the click fix itself is measured on the unit only.
  - `verify_usb` for `usb-io`: the six-interface configuration, EP3 IN marked
    as implicit-feedback data, EP 0x03 and interface 5's four channels.
- **Results, 27 Sep 2026** (`usb-io`, beside USB AUDIO MC, Bryan T's Mac):
  `make check` passes. `verify_usb_in` passed eight runs in a row, one of
  them `POLLS=40000` (10 s of device time): every packet whole, 0 underruns,
  bit-exact C D A B on the RX blocks and the recorder ring; ring fill 343-388
  frames against the 384 target. The first run on this port failed one
  check, "the stream flag is set", and so did the `make accept` run of
  `usb-io`: the gate read the flag from a snapshot of `in_tx` taken at
  whatever instruction the port stopped on, and inside `in_build` the first
  sample is rewritten before the flag is set (`2157001b`: a valid coded
  sample without bit 8), while the RX blocks in the same run carried the
  host's samples, i.e. the DSP saw the flag. On the unit the DMA to the DSP
  starts only after `in_build` returns. The gate now proves the flag through
  the RX blocks and checks the snapshot only after the stream closes, where
  it is a constant zero. (A guess recorded here before the line was caught,
  pacing or underruns, was wrong.)
  The port's fill band says nothing about hardware headroom: its host is
  locked to the device, where the unit's EP3 IN servo lets the fill wander
  +-128 frames. `IN_TARGET` comes down from the unit's `minfill`, not this.
- **On hardware:** as USB AUDIO OUT with `AUD_IN4`, builds 12-15 on Bryan T's
  MKII (26 Sep 2026): the numbers above. This port has not been flashed.

## What the port changed (27 Sep 2026)

- Names: the key, folder, unit, symbols (`out_*` -> `in_*`) and constants
  (`OUT_TARGET` -> `IN_TARGET`, ...). `usbaudio_in.s` reverses to
  usbin-test's `usbaudio_out.s` (at `f1432c9`) exactly under that renaming,
  except four comment lines. The DSP pokes and detour sites are byte-identical.
- `AUD_IN4` is gone: MAIN + CUE is USB AUDIO MC, a layout of its own.
- usbaudio.s's EP3 bring-up and teardown write only ENDPTCTRL3's TX half,
  as on usbin-test. For every layout without this module the RX half is
  never set, so the register values are unchanged.

## Open


- **Beside FULL or EXTENDED: not measured.** Before the crossbar fix, the
  twenty-channel EP3 IN stream beside EP3 OUT lost EP3 OUT packet tails
  under load (images 97-99), which is why usbin-test forced four channels.
  The fix (build 14) is what cured the tails, and a four-channel EP3 IN
  stream alone did not, so the larger pairings are plausible; they have not
  been run since. Count bad packets with `usb_counters.py --in` first.
- **A remix with this module and DSP modules** could have the placer pack a
  module into SPATIALIZER's words, over the inject. No remix does that yet.
  Whether the build refuses it (each poke asserts stock bytes first) or
  the inject is overwritten depends on the order it applies pokes and
  placement; not traced, not tested.
- Lower `IN_TARGET` from `minfill` data.
- DISK MODE on these images: it failed on image 93, unretested since.
- The full-speed alt of interface 5 is declared but not served.
- GET_INTERFACE(5) returns stock `00`.
- The diagnostic vendor requests (`0x57`-`0x5b`) are debug tools; strip or
  gate before this ships to anyone else.
