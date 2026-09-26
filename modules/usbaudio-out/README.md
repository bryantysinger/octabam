# USB AUDIO OUT: four channels from the host into inputs A–D

The Mac sends four 24-bit channels at 44.1 kHz over UAC2 on EP3 OUT, and they
arrive on the Octatrack's inputs A, B, C and D in place of the jacks. When the
stream is closed, A–D are the jacks again. Remix `usb-io` =
USB MIDI + USB AUDIO + USB AUDIO OUT + the stock effects minus SPATIALIZER.

Bryan T, with Claude, 26 Sep 2026. This is a **draft handed to Bam**: it works
on hardware (numbers below), but it is not PR-ready (see *State*).

## How it works

**Descriptors** (`modules/usbmidi/descriptors.py`, `with_out`):
- AudioStreaming interface 5, alt 0/1, with EP3 OUT: 4 ch × 24-bit in 4-byte
  subslots, 192 B every 250 µs at high speed. It is iso asynchronous and fed
  by IT `0x13` → OT `0x14`.
- EP3 OUT is the only free endpoint (EP1 mass storage, EP2 MIDI, EP3 IN
  audio), so there is none for explicit feedback. EP3 IN is marked as the
  **implicit-feedback** data endpoint (`bmAttributes 0x25`), and the host
  sizes each OUT packet from the IN stream's.
- With this module in the remix, usbaudio's high-speed input stream is
  **MAIN L/R + CUE L/R only** (4 channels, `AUD_IN4` via `remix.inc`).
  Without it, usbaudio is byte-identical to before.

**ColdFire** (`usbaudio_out.s`, a DRAM unit):
- `out_setiface_shim`, a detour after usbaudio's SET_INTERFACE shim:
  interface 5 records the alt setting and ACKs.
- `out_state7_shim`, a detour on the frame-transfer state machine's state 7
  (`0x40004bc0`). It is the one owner of EP3 OUT:
  - brings it up and down;
  - retires completed dTDs into a 1,024-frame ring;
  - self-heals the queue;
  - then runs a **second eDMA transfer** per DSP frame to core 0: 16 frames
    to `$6320` in the idle bank, in DSP slot order C, D, A, B, with a stream
    flag in bit 8 of the first low halfword.

  The stock frame-IRQ unmask runs on the second visit.
- Cushion `OUT_TARGET` = 384 frames (8.7 ms).
- The **dTDs and packet buffers are in on-chip SRAM** at `0x80007c00`, and
  the EP0 reply buffer at `0x80007f80`; see *SRAM*.
- `out_ctrl_shim`, a detour on the EP0 stall store (`0x4001de6e`), answers
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

**Fix**, in `out_up`:
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
- A 4-channel IN stream alone.
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
- `0x56` GET: USB AUDIO OUT's 28 counters (`tools/hw/usb_counters.py --out`):
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
  - `tools/verify/verify_usb_out.py`: bit-exact C D A B in the RX blocks and
    the recorder ring, the flag, the counters over `0x56`, and the jacks back
    after alt 0. The port does not model SCM/XBS, so the fix itself is
    measured on the unit only.
  - `verify_usb` for usb-io, usb-audio and usbin-test.
- **On Bryan's Mac:** `make check REMIX=usb-io` passes.

## State (not PR-ready)

- Not rebased onto `origin/main`, and the full CONTRIBUTING gate list has not
  been run.
- The sandbox builds were made with a toolchain that fails USB MIDI's
  reference hash, so that gate was downgraded there. Bryan's Mac builds pass
  it.
- `modules/usbin-test` and `remixes/usbin-test.py` (tones on A–D) are test
  scaffolding.
- **Changes to usbaudio for review:**
  - EP3 up/down write only ENDPTCTRL3's TX half.
  - `AUD_IN4`.
- **Open:**
  - Lower `OUT_TARGET` from `minfill` data.
  - DISK MODE on these images: it failed on image 93, unretested since.
  - The full-speed OUT alt is declared but not served.
  - GET_INTERFACE(5) returns stock `00`.
