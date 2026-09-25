# USB AUDIO

The eight tracks over USB as a UAC2 audio input: at high speed sixteen
channels of 44.1 kHz 24-bit PCM (in 4-byte subslots), track N's L/R on
channels 2N-1/2N, post-FX and pre-fader; at full speed the stereo sum of
the tracks, 24-bit as well. markandrus's proof of concept
([octemu](https://github.com/markandrus/octemu), `custom/usb-audio.py` +
`custom/coldfire/usb-audio.s` at `6a9ff68`, MIT, 16-bit), carried onto
octabam's DRAM platform and widened to 24 bits here (25 Sep 2026). Needs
USB MIDI: the audio function is added to its composite.

**Channels 17–20: MAIN and CUE (Bryan T, 25 Sep 2026; on hardware as
`usb-lean` image 90).** At high speed the stream carries twenty channels: the sixteen
track channels above, then MAIN L/R on 17/18 and CUE L/R on 19/20. These
are the words core 0 sends to the DACs (ESAI TX slots 2/3 and 0/1), which
its mixdown also packs into the host read-back after the track blocks
(`P:0x2df`, `P:0x2e2`); the frame ISR's eDMA chain ch1 → ch6 → ch7 lands
them at `0x80005e60` (MAIN) and `0x80005ee0` (CUE), 16 × (L,R) each, the
same buffer the stock recorder reads for SRC3 = MAIN / CUE. MAIN and CUE
therefore include everything the outputs do (track levels, crossfader,
master stages), unlike channels 1–16. The ring slot is 80 bytes (the
index math multiplies by 80 instead of shifting), packets are at most
12 × 80 = 960 B (one high-speed transaction), and the full-speed stream is
unchanged (the tracks' stereo sum). Which half of `0x80005e60` is MAIN
rests on the recorder's SRC3 byte being raw−1 (8 = MAIN), and hardware
confirms it: on Bryan's MKII (image 90, 25 Sep 2026) channels 17/18 carried
MAIN and 19/20 CUE (an uncued track on MAIN, a cued track on CUE).
`MC_MAIN_OFF` / `MC_CUE_OFF` stay as they are.
Open: on hardware MAIN lags the track channels (Bryan T, 25 Sep 2026; lag
not measured). The producer reads MAIN/CUE from the current pull and the
tracks from the previous bank, so core 0's mixdown path adds more than one
block. Aligning them means delaying channels 1-16 by the measured lag.

Measured under the port: `verify_usb` (960 B / bInterval 2, AS_GENERAL
20 channels, 880/960 B packets, low bytes zero, 0 under/overruns); and a
throwaway build with `MC_BASE` pointed at a frame- and channel-coded
pattern in the unit: 8,709 streamed frames, every channel 17–20 subslot
the expected word in order, frame indices consecutive, channels 1–16
untouched. The port's project is silent, so MAIN/CUE content itself was
not measured there.

## What it is

- **Source.** The read-back arena at SRAM `0x80003190`: the eDMA deposits
  every track's post-FX pre-fader block there each frame (the same memory
  the stock delay and Tape Echo read). The producer runs from the frame
  interrupt's last instruction (`0x4000d9a0`), reads the previous
  ping-pong bank, keeps the top 24 bits of each 32-bit sample (the low
  byte cleared, left-justified in a 4-byte subslot) and writes one 64-byte
  slot per frame into a 1,024-frame ring (plus a stereo-sum ring, 8 bytes
  a frame, for full speed). The arena's full scale is 2^31, the scale his
  16-bit build calibrated (a right shift of 16), so a 24-bit sample is the
  same level with 8 more bits below it. Track LEVEL, the crossfader, MAIN volume and the
  master effects are downstream of the tap and not in the stream.
- **Endpoint.** EP3 IN, isochronous, asynchronous, bInterval 2 (a 250 µs
  poll), 11 or 12 frames per packet, at most 768 bytes: sixteen 4-byte
  channels at 44.1 kHz are 2,822 bytes a millisecond, and one high-speed
  isochronous transaction carries at most 1,024 bytes, so his 500 µs poll
  (1,104 bytes a packet at 24 bits) does not fit. Four transfer
  descriptors, so 1 ms of packets is queued ahead of the host, the cover
  his two gave at 500 µs; the frame interrupt (every 363 µs) is the only
  context that queues. A rate servo nudges the
  packet size ±0.1 frame against a 512-frame target fill, which is "send
  what is produced": the stream is a gap-free copy of the ring. Underruns
  (nothing to send) and overruns (the host stopped draining) are counted
  in the unit's data (`usbaudio_underruns`, `usbaudio_overruns`).
- **Descriptors.** Two functions under interface associations, the shape
  macOS accepts (his measurement against a Digitone): the MIDI function,
  then a UAC2 AudioControl with a read-only 44.1 kHz clock source and an
  AudioStreaming interface 4 (alt 0 idle, alt 1 streaming). The clock
  source's CUR/RANGE/validity class requests are answered by a shim on
  the stock "unknown request" STALL tail.
- **DMA memory.** The USB controller is a bus master that does not snoop
  the data cache, so the four dTDs and four 768-byte packet buffers are
  read and written only through the uncached SDRAM alias (address +
  `0x08000000`, `docs/remixer/PLACEMENT.md`): they are this unit's data
  (`aud_dtds`, `aud_bufs`, 3,200 bytes, dTDs 32-byte aligned), and the
  loader depacks the unit through the same alias. His build placed two
  dTDs and two 736-byte buffers in a 1,536-byte window at `0x4ec94a00`,
  itself an alias address (his measurement: per-line cache pushes did not
  work, cache-inhibited structures did); four 768-byte buffers do not fit
  it, and the window is no longer used.

His card-loaded payload, page allocator, self-relocating entry, stage-2
hook installer, trampoline, on-screen reporter and hook guard are not
ported: the loader places the unit, the rings are its zeroed data, every
hook is a build-time detour, and the unit is up before the host can
enumerate, which is also why his "re-plug the cable" caveat does not
apply. The ISR site is USB MIDI's; this module's shim retires EP3
completions and chains to USB MIDI's by symbol (`Override`).

## Measured on hardware: the 24-bit stream (image 69, Sam's MKII, 25 Sep 2026)

macOS lists the unit as a 16-channel 44.1 kHz input. Two takes with
`tools/rec` (HAL IOProc, Float32 → int32 WAV), the counters read over the
vendor request before and after each:

| take | project | length | tones | samples with non-zero low 8 of 24 bits | underruns / overruns / reprimes | events after 0.76 s |
|---|---|---|---|---|---|---|
| 1 | USBSIG | 60 s | all 16 at their frequency, −27.0 dBFS | 97.1–100% per channel | 0 / 0 / 0 | 0 |
| 2 | USBLOAD (locks every step, 200 BPM) | 120 s | all 16, −19.3 dBFS | 97.1–100% | 0 / 0 / 0 | 0 |

- `lastn` 11 and `lastfill` 512–576 after each take: the 250 µs poll and
  the servo at its target on silicon.
- Both takes have the start-of-stream burst (0.51–0.76 s after the
  recording opened) on the RIGHT channel of every pair (channels 2, 4 …
  16: 23–38 events each) and on no left channel. In the burst the right
  channels hold the tone in runs whose phase is 124–380 frames off:
  reordered samples, not corrupted ones. `docs/remixer/FAILURE_MODES.md`.
- Both projects were stamped with `ot_project.py stamp-defaults
  usb-audio --all` first (SEND's DEL/REV split since image 64).

## Measured: the 24-bit stream (25 Sep 2026, under the ColdFire port)

`verify_usb` (in `make check REMIX=usb-audio`), no card, silent tracks:
EP 0x83 iso 768 bytes bInterval 2; FORMAT_TYPE_I subslot 4, 24 bits;
800 polls at the device's 250 µs cadence carry 704/768-byte packets
(11/12 frames), none empty after the first ten; every subslot's low byte
zero; 0 underruns, 0 overruns; alt 0 → every poll empty.

The USBSIG tone project (`tools/harness/usb_sig_project.py`) staged on a
card under the port, `--sequencer --poke-trig 2`, streamed by
`usb_host.py`'s paced drain:

- High speed, 3 s: all sixteen channels carry their track's tone at the
  expected frequency (T1 L 300 Hz … T8 R 1050 Hz), −25 to −29 dBFS.
  95.2–99.8% of each channel's 24-bit samples have non-zero low 8 bits:
  the 8 bits below a 16-bit stream's LSB carry signal.
- Full speed, 3 s: 360-byte packets at bInterval 1, 44/45 frames; the
  left sum carries every left tone and the right sum every right tone;
  0 overruns.
- Overruns under the port follow the bench host, not the device. Five
  high-speed runs of the same project: 0 or 3 polls with no IN from the
  bench host waiting → 0 overruns and no discontinuity (runs of 3 and
  5 s); 79–91 such polls → 17–47 overruns and one cluster of
  discontinuities 50–80 ms long. The port counts them (`iso poll(s) with
  no IN waiting` in its USB summary; a run of 16 or more is logged). The
  Python host answers each poll with one socket round trip, at 4,000 a
  second of device time; a host's own schedule on hardware does not skip
  polls.
- Main's 16-bit build on the same fixture without the poked trig carries
  −4 on four idle channels where the 24-bit build carries −936
  (−936 / 256 = −3.66: the same level, 8 more bits).

Not measured: the cost of four times the packet completions per second
on the unit's USB controller beyond the two takes above (no completion
interrupt is requested); Windows and Linux hosts.

## Measured: the 16-bit stream (25 Sep 2026, under the ColdFire port)

`make check REMIX=usb-audio`, `verify_usb` with the frame engine on and no
card (silent tracks, a live stream):

- five interfaces, 250-byte configuration, device class EF/02/01, EP 0x83
  iso 736 bytes bInterval 3; CS_SAM_FREQ_CONTROL CUR answers 44100;
- SET_INTERFACE 4 alt 1 → GET_INTERFACE reports 1; 400 polls at the
  device's 500 µs cadence carry 704/736-byte packets (22/23 frames), none
  empty after the first ten; alt 0 → every poll empty.

With a project playing (the eight-track stress project of
`tools/harness/stress_project.py`, `--sequencer`, 2.0 s drained at the
500 µs poll): 4,000 polls, none empty, 88,200 frames; eight distinct
stereo pairs, T1 −34 dBFS through T3 −23 dBFS, no two channels equal,
the largest sample step on T1 L 2,031 against a 99th percentile of 121
(the loop's own transients).

The port's host polls on the device's own clock (`tools/emu/ot_emu/usb.h`
`isoPoll`), which is what keeps the servo at 22/23: an unpaced drain
starved the ring and read as 21/22.

What the port cannot see: the producer's race against the read-back bank
swap, his open hypothesis for the clicks he hears on hardware (the
`usbaudio_bankdup` counter is in the unit's data for a hardware read-back).
A lock-step emulator serialises the frame interrupt and the eDMA.

## The counters, from a host

The unit answers a vendor control request (bmRequestType 0xc0, bRequest
0x55) with its twelve counters as 48 big-endian bytes: consumed, acc,
overruns, underruns, lastn, lastfill, lastbank, bankdup, lastsamp,
srcjump, reprimes, produced. `tools/hw/usb_counters.py [--watch 1]` reads
them on a unit (`brew install libusb`, `.venv/bin/pip install pyusb`); the
port's bench reads them with `usb_host.py … counters`, and `verify_usb`
checks them after its stream (under the port: 0 underruns, 0 overruns,
bankdup 2 at the frame engine's start).

## Hardware test protocol (image 64, the first flash)

The question is his mid-stream clicks: not packet loss on his unit
(0 overruns, 0 steady-state underruns), so either the producer reads a
read-back bank twice or skips one (`bankdup` moves) or the fault is on the
host side (`bankdup` stays). One flash, one recording.

1. `make image REMIX=usb-audio BUILD=64` → `out/OCTATRACK_OCTABAM64.bin`
   to the card root, PROJECT → SYSTEM → OS UPGRADE; the rig modules are
   bamsep26's, so the current project plays as before.
2. USB to the Mac. Audio MIDI Setup should list the unit as a 16-channel
   input at 44.1 kHz (the MIDI Studio shows its MIDI port too). If it does
   not enumerate, `system_profiler SPUSBDataType | grep -A12 Octatrack`.
3. `tools/hw/usb_counters.py` once: produced counts up while idle (the
   producer runs from the frame interrupt whether or not anyone listens);
   underruns, overruns and bankdup should sit at 0 while nothing streams.
4. Record while the project plays, 60 s, all sixteen channels:
   `sox -t coreaudio "Elektron Octatrack" -c 16 -r 44100 -b 24 out/usb_take1.wav trim 0 60`
   (the exact device name is in `sox -V6 -n -t coreaudio /dev/null 2>&1 | grep -i octa`
   or Audio MIDI Setup), with `tools/hw/usb_counters.py --watch 5` in a
   second terminal from before the recording starts to after it stops.
5. Read the take: `python3 tools/harness/click_scan.py out/usb_take1.wav`
   lists per-channel sample steps above 8× the channel's 99th percentile
   with their times; line them up against the counter watch.

Outcomes: bankdup increments during the take → the producer (the frame
interrupt's read of the previous bank lands against the eDMA's swap; the
fix is a copy taken at a proven-safe point, the shape of #397). bankdup
still, underruns still, clicks present → the host or the cable; try a
second host and USB port before touching the unit. Clicks absent → his
caveat does not reproduce here. A freeze, a hang or a wedge on plugging
in: power off, recover per `docs/remixer/FLASHING.md`, and the FAILURE_MODES
entry gets the symptom.

## Measured on hardware: the 16-bit stream (image 64, Sam's MKII, 25 Sep 2026)

Four takes with `tools/rec` (a raw HAL IOProc, all sixteen input
channels) on the USBSIG project (`tools/harness/usb_sig_project.py`), the
counters read over the vendor request before and after each:

| take | length | load | events in the first 1.6 s | events after 2 s | underruns / overruns / bankdup |
|---|---|---|---|---|---|
| 1 | 60 s | none | 9 (all at 0.743 s) | 0 | 0 / 0 / unchanged |
| 2 | 60 s | none | 76 (0.998–1.254 s) | 0 | 0 / 0 / unchanged |
| 3 | 300 s | none | 110 (1.091–1.509 s) | 0 | 0 / 0 / unchanged |
| 4 | 120 s | 896,760 USB-MIDI messages in (7,170/s, notes + CCs on channel 16), menus, sample manager, project save, LEVEL and main turned | 85 (0.871–1.231 s) | 0 | 0 / 0 / unchanged |
| 5 | 180 s | USBLOAD (`--load`: 200 BPM, trigless locks on 63 steps × 10 slots per track), 1,471,080 USB-MIDI messages in, FX knobs turned on T1 | 0 | 24, all on T1's channels while its knobs were turned (35.7–51.3 s); 0 on the other fourteen | 0 / 0 / unchanged |

- The unit enumerates on macOS at high speed as a 16-channel 44.1 kHz
  input "Elektron Octatrack DPS-1" and a MIDI port of the same name.
- Every channel carries its track's tone (FFT peak at 100 s and at 60 s of
  the loaded take), −27 dBFS.
- After the first 1.6 s of a host stream, zero discontinuities in 9.6
  minutes of audio, with and without load. The device's counters never
  moved: bankdup stayed at 1 (its boot-time value) across all four takes,
  so the producer did not read a bank twice or skip one; underruns and
  overruns stayed at 0.
- Every take has one burst of reordered samples between 0.75 and 1.5 s
  after the host opened the stream: the following samples sit a few frames
  to two packets off their phase (−11.6, +10.3, −41 frames measured), then
  the stream is in order for good. No frames are lost (the long-window
  phase before and after agrees to 0.1 frame). A host that opens a fresh
  stream per run (sox, `tools/rec`) hears this at every start, which is the
  candidate for octemu's "some crackles". Open: whether the reorder is the
  device's two-slot packet queue at stream start (the packet order the
  controller follows on the first primes, which the port's bench cannot
  model: it serves queue heads in list order) or the host's stream start.
  A take with the stream held open across two recordings, or a packet
  sequence counter in the stream, decides it.
- The USB-MIDI receive path took 7,170 messages a second for 125 s, then
  7,950 a second for 185 s, without a stall or a change in the audio stream.
- Take 5 had no start burst at all, so the burst is not on every stream
  open. The pop Sam heard once per pattern is the trig on step 1 restarting
  the looping sample (a phase reset the device counts in `srcjump`: 12 in
  180 s at 200 BPM), not USB; the tone loops themselves are seamless (an
  integer number of cycles per 2 s).
- His own image, built from Sam's stock bytes and packed as image 65 with
  `USBAUDIO.BIN` on the card root, enumerated on this MKII as the MIDI
  composite only: his card-loaded payload never installed (no `USBAUD E<n>`
  popup after a boot with the card in, after a DISK MODE enter/exit, or
  after pulling and re-seating the card). So no A/B against his build was
  possible here, and nothing about his crackles is attributed.

## Ground

| what | where |
|---|---|
| code | DRAM unit `usbaudio`, 1,774 B text |
| rings + state | 76,000 B of the unit's data (1,024 × 64 B + 1,024 × 8 B + 4 dTDs + 4 × 768 B packets + counters) |
| DMA memory | `aud_dtds` + `aud_bufs` in the unit's data, 3,200 B, through the uncached alias (+`0x08000000`) |
| hooks | `0x4001dd04` `0x4001d824` `0x4001de64` `0x4001d4b2` `0x4000d9a0` `0x4001e606` (USB MIDI's, overridden) |
| poke | `0x400e2004` device class → `ef 02 01` |
| descriptors | USB MIDI's `usbmidi_cfg` unit, generated with the audio function when this module is in the remix |
