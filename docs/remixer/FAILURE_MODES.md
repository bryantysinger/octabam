# Hardware failure modes: the register

Symptom → cause (measured, inferred or open) → fix. Add an entry the moment
a mode is seen on hardware.

## Audio engine wedged, sequencer alive: the master loop ✅ measured

**Symptom.** The sequencer runs but no audio plays, sample preview is
silent, the record meters for B/C/D sit lit. Distinct from the DSP hang
(there the sequencer freezes).

**Cause (measured 6 Sep 2026).** The master's station (T8, Character in
the return role) was sending into the reverb bus it returns: T8 FX1 -VRB
at 71 in bank02's parts; turning it to 0 brought the audio back live. Why
the loop reads as silence rather than a squeal is not established. On the
tag-93 rig (5 Sep) one instance cleared with a power-cycle; the 6 Sep
instances did not.

**Fix.** By construction since the one-aux rig: the stations have no
sends and the SEND is refused at track 8's dispatch position on payload A
whatever its knob says (`tools/verify/verify_onebus.py`).

## The audio engine wedges with only BusVerb + the return 🔴 cause open

**Symptom.** Playing, the output drops to the noise floor and never comes
back while the transport keeps running.

**Measured (13 Sep 2026, image 94, `tools/hw/ot_soak.py`)**, T5 FX2 =
BusVerb, T8 FX1 = Character as the return, every other slot stock:

| configuration | return level | 3 min soak |
|---|---|---|
| return alone, no engines | 127 | clean |
| BusVerb, return at 0 | 0 | clean (twice) |
| BusVerb + return | 127 | silent at 131.5 s, never recovered |
| the same, repeated | 127 | clean |
| the same, 9 min | 127 | clean |

Not the cycle wall (this layout is nowhere near it). Rate ~one freeze in
15 minutes, so a 3-minute pass cannot clear a configuration. Recovery: a
transport restart.

**Cause.** Open. The only configuration that wedged is the one where the
reverb's output reaches the mix. Next: soak `BusVerb + return` against
`BusDelay + return` for tens of minutes each.

## BusDelay silent with its knobs locked: the MODE formatter wrote over the minimum table ✅ measured

**Symptom.** No delay audible; BusDelay's TONE, PING and MIX pinned and the
encoders would not move them; cleared by a reboot, returned when the
delay's page 2 was drawn.

**Cause (measured under the emulator with a write watch, 13 Sep 2026).**
`tools/build/mode_names.py` was handed the clone's page descriptor `P` and
wrote the rename bytes at `P + 0x4e + 6·slot`; the names live at `E + 0x4e`
and `P = E + 0x38`, so every rename landed 0x38 too high, in the
minimum-value table (`P + 0x6a + 4·slot`). BusDelay's GRAIN names hit
`min[3..5]` (TONE, PING, MIX) with 0x4d444550 / 0x4d524154: a knob whose
minimum is 1.3 billion cannot be turned. `verify_modenames` read the names
back from the same wrong offset and passed. Character's SAT view and
Modulation's COMB view had the same fault with a smaller blast radius.

**Fix.** `NAMES_AT = 0x16` (P-relative); the verifier reads there.

The stored values themselves (TONE 68, FDBK 85, AUX 90 in OCTABAM86's
parts, every other track's AUX at 110-127) were the part's own bytes;
re-stamped from the manifests (OCTABAM87) the rig measured clean on the
ladder at every rung. An autocorrelation of the whole mix that "measured
TIME inert" was reading the material's own eighth and quarter at 121 BPM
(248 / 496 ms) and is retracted; measure a delay time from the spacing of
the decaying repeats after the source stops.

## CC PAGE 2 did not write on hardware ✅ fixed (image 96)

**Symptom.** CC 62-67 changed nothing on the panel, transport stopped or
running, on an image whose dispatch vector held the cave's address.

**Cause.** The cave used the PLAYBACK page-2 editor's three stores
(`0x4003a474`), so every CC corrupted the track's PLAYBACK page-2 byte and
never touched FX2's. The FX2 editor's stores are Part `+0x8f084`, shadow
`0x100a51d2`, lane +0x38.

**Fix.** The cave uses those; `verify_ccpage2` proves the write against the
FX2 editor; CC 63 on channel 5 moved SHMR on the panel and raised the
tail's 2-8 kHz bands 5-8 dB (image 96). Every page-2 sweep taken over the
old cave is void.

## Re-selecting an effect zeroes the bus ⚠️

**Symptom.** A rig that measures dead after ordinary panel work: no wet,
soak after soak passing because nothing is connected.

**Cause (measured).** A re-select loads the manifest defaults, and the two
knobs that connect the bus both default to 0: BusVerb's AUX (0 is
load-bearing: a non-zero default registers every idle host as a client)
and Character's RET.

**Fix.** Assert the connections over MIDI immediately before every
measurement: RET `CC 36` on the master's channel, AUX `CC 40` per track.

## A station "at its defaults" was running its default mode's view ✅ measured

**Symptom.** A station that documents a bit-exact passthrough at its
defaults changes the track's level (T5 −2.5 dB on the ladder).

**Cause.** `ot_project.module_defaults` applied the ModeView of the MODE
the manifest defaults select (Modulation's CHOR: MIX 64, RATE 30), so
`rigproj` and `stamp-defaults` wrote a chorus at half mix into every T5.

**Fix.** A view applies only when the MODE is explicitly given; the
manifest defaults are the stamped default. Re-stamp.

## PARSE ERROR loading a generated project ✅ measured

**Symptom.** LOAD PROJECT on a project written by our tooling stops with
"PARSE ERROR", reliably.

**Cause.** Every PART record in a bank file carries its own index in byte
8 (parts 1-4 hold 0-3, the saved mirrors 5-8 repeat 0-3). A whole-record
copy keeps the donor's index.

**Fix.** Write `p % 4` into byte 8 after any whole-record copy
(`ot_ladder.PART_INDEX_OFF`); the generator's read-back checks every
record. The other known parse error: `project.work` edited in text mode
loses its CRLF.

## The set went silent after a test flash: the firmware reset the project 🟡

**Symptom.** After flashing a test image whose remix omitted Character,
the set printed nothing under it and stayed silent back on the rig image.

**Measured.** The card's bank records had every part reset: FX1 id 4 with
FILTER's page-2 bytes, FX2 = the stock delay, T1/T2 no longer THRU, T8 =
FX1 NONE / FX2 COMPRESSOR (0x18, a harvested donor id on the rig → the
null stub on the master).

**Inferred.** The firmware sanitises part records whose FX ids are not in
the running image's tables and writes the .work files back. Never load
the set under a test image.

**Recovery.** Regenerate from the material (`ot_project.py rigproj … +
lfo-clear … all`), copy the banks over the card's project in place, keep
the project's own `project.work` (a foreign `OS_VERSION` tag gave PARSE
ERROR, inferred from the diff). Save a copy of the card's project first.

## The master compressor collapses one channel above COMP ~40 ✅ measured

**Symptom.** Character on T8 with COMP above ~40: the right channel drops
40+ dB, L holds; scales with WDTH; only with the stations loaded.

**Cause (measured 14 Sep 2026).** Character's compressor was innocent.
Track LEVEL 0 on T4 cleared it and T4's AMP VOL 0 did not: T4's Spectrum
generated a near-full-scale DC from its state. Reproduced under `dsp_host`:
Spectrum with its instance block pre-filled with 0x400000 outputs −0.5 FS
on silence forever; filter B's two HP poles at cHP = 0 were frozen and
`hp2 = yB − h2` subtracted the stale h2 every sample. Init cleared
`$00..$17` only. The makeup then clipped DC + audio to a constant on the
channel whose offset was larger; an AC-coupled capture cannot see the DC.

**Fix.** Every persistent slot zeroed at init (Spectrum `$00..$3f`,
Modulation's LFO values, Character's counters, phase and grace);
`tools/verify/verify_dirtystate.py` (in `make verify`) renders every module
from a garbage block on silence and refuses any output above −100 dBFS.
Confirmed on the unit (image 8): bank G's master at COMP 40 / 80 / 127
reads R−L −0.4 / −0.1 / −0.6 dB (was −44 at COMP 80).

## A diagnostic image silenced every bank with stations; the port played them 🔴 open

**Symptom.** OCTABAM5 (Character 189 words shorter) played banks A, B, E
and was silent on F and G (the station layouts), DSP not hung. Image 4 and
the shipping image play G.

**Measured.** Under the port image 5 plays F and G; the stopwatch reads
its Character cheaper; no instruction runs in image 5 that image 4 did
not. The differences left are placement: Modulation moved down on both
payloads (A 0x1c1b, B 0x193c) and the build kept the stock COMB code and
dispatch on payload B (never executed under the port). Image 6 = image
5's Character plus 189 nop words (image 4's placement) plays F and G.

**Cause.** Open: something at that placement the port does not model
(the kept stock COMB on payload B, or Modulation's address). Not bisected.

**Workaround.** Pad a diagnostic module to a placement known to play.

## Sequencer stuck on step 1 at project load: an init that moved r1 ✅ measured

**Symptom.** Play sticks on step 1 on every project that loads a Spectrum
on FX1 (image 99).

**Cause (the port's last-PC ring).** The stock FX1 dispatcher keeps the
effect id in r1 across `jsr init` and indexes the proc table with it
(`P:0x4c8..0x4d7`). Spectrum's init zeroed its state through r1 and
returned with r1 = r7+24; the proc lookup read garbage and `jsr (r2)`
landed on P:0. `dsp_host` cannot see it: it calls init and proc itself.

**Fix.** Zero through r5; `tools/verify/verify_initregs.py` (in `make
check`) refuses an init that writes r1/n1/m1. Recovery: a power-cycle and
a project without the module.

## Sequencer stuck on step 1: cycle overrun or a wild value

**Symptom.** Step 1 solid and never advances, no audio.

**Cause (measured).** A core cannot finish a block: a cycle overrun (three
heavy stations beside an engine at a static 3,106 of 3,120; the counter
is a floor, the wall a cliff), or a wild stored value feeding an engine
on frame one (an old part's crossed-slot byte after a layout change).

**Fix.** Fit the layout (≤ two heavy stations per core) and stamp the
project for the current remix before playing.

## The RET/CRSH trap ✅ removed by design

**Symptom.** With T8's Character in the old BUS mode and knob 3 at 127,
turning SAT to TAPE made the whole mix a 4-bit crush at full scale: the
same knob was RET in BUS and CRSH elsewhere.

**Fix.** No BUS mode. Slot 4 is RET on every track, live by dispatch
position on the master and inert elsewhere; the wet enters at the front of
the chain; DRV 0 skips the saturator (bit-exact).

## An FX1 station's page 2 does not reach the DSP on T1 🔴 mechanism open

**Symptom.** Character on T1 (a THRU, FX1) made a quiet tone at idle; knob
3 at 127 gave −47 dBFS of broadband hash with the panel's SAT at BUS or
TAPE alike: the DSP on T1 was in TAPE whatever the panel said (the old bit
crusher on the input floor).

**Measured under the port.** The ColdFire side is exonerated: the FX1
page-2 editor `0x4003abe4` writes the Part at `+0x8f07e + track*30 +
slot`, the shadow at `0x100a51cc + …` and the live lane at `0x80000842 +
track*72 + slot` (+0x32, the lane the per-frame copier `0x4000cae8`
delivers), with no page or index term, and did so for T1 (THRU), T3 and
T8. T3 (STATIC) and T8 (FLEX master) take a panel page-2 edit on
hardware; T1 (THRU) does not; the stamp reaches all three.

**Cause.** Downstream of the lane: the DSP side at position 0 on payload
B, or a per-frame refresh of that lane peculiar to a THRU machine. Not
measured. Next: the port with `--watch` on `0x80000842..0x80000847` and
T1's DSP record bytes 36-41 across frames after an FX1 editor call, THRU
machine loaded. Interim: keep every station's knob 3 at 0 on FX1 tracks.

## A DC thump every 10.59 s at idle, from track 6 ✅ source measured

**Symptom.** Transport stopped: a thump every 10.59 s, ringing 2 s through
the return. A DC step, +0.23 FS on L, +0.46 on R, rising in two samples,
bled away by the output DC blocker over ~35 ms. On every ladder rung
including the one with no module of ours. Track LEVEL 0 on T6 removes it;
AMP VOL 0 does not.

**Source.** T6 LFO 2: destination 16 (AMP BAL), triangle, speed 18, depth
21, FREE (`ot_project.py lfo`). Zeroing the three LFO depths over CC
29/31/33 removes it; depth 64 on LFO 2 alone brings it back at −21 dBFS;
the period is 64 steps at 121 BPM with a 3/4X scale; the pulse rate
follows the LFO speed. A plain BAL move over CC 8 never pulses.

**Fix.** Every LFO depth cleared in OCTABAM87 and the ladder (`lfo-clear
all`). Open: whether a balance LFO pulses on stock 1.40C too (the pan
stage is stock; its table may sit in harvested memory); the port with a
fast LFO fixture decides it. A separate 593.5 Hz tone at −75 dBFS after
STOP on OCTABAM87 only: cause open.

## Spectrum VOWL went silent with RES up 🟡 seen once

**Measured (image 96, T3 soloed, FREQ/RES over CC, MODE set at the
panel).** VOWL at RES 100 with FREQ ≤ 96, and RES 127 at FREQ 64, output
−102 dBFS; LP/BP/HP/NTCH bounded at RES 127. `dsp_host` does not reproduce
it, and on image 97 with MODE set over CC 69 the same sweep in both knob
orders never went silent. The one difference: T3's FX1 page 2 was on
screen while the page-1 CCs were sent, MODE set at the panel (the editor's
refresher `0x40027e00` runs there and not on the CC path). A CC 35 = 100
with page 2 on screen landed on RES, not MODE (falsifying the
routed-by-displayed-page hypothesis). The two-peak VOWL it happened on is
gone (image 98: a three-formant resonator bank, bounded at RES 127). If
it recurs at the panel, capture before touching anything.

## A one-sample tick on an exact 2048-sample grid at idle 🔴 cause open

**Symptom.** Sequencer stopped, nothing playing: a one-sample downward
spike, common-mode on L and R, −45 dBFS peak, at irregular intervals of a
few hundred ms; occasionally its reverb tail lifts the floor to ~−90 dB
for a second. Present with the reverb's track muted.

**Measured (image 93, two 30 s captures).** 23 / 24 ticks in 30 s on a
grid of 2048.050 / 2048.049 samples (fit residual 0.29 / 0.25 samples
over 631 periods). The +24 ppm offset says the unit generates it (a
capture dropout lands on exactly 2048.000). Not an overrun (locked to a
buffer boundary to a third of a sample). Intermittent at the boundary:
96 % of wraps clean, 4 % spike, gaps 8, 10, 18, 21, 29, 31, 47 wraps.

**Ruled out.** The capture rig; Character (removing it removed the whole
wet bus's path to the outputs, not a source); the stored project (a
reload measured −104.6 dBFS with zero ticks against −73.9 and 23 before:
the tick needs a live edit the card does not hold); the input path;
BusVerb page 1 (every knob to extremes over verified CCs: zero ticks).
Page 2 was untested (the CC PAGE 2 fault) and is not cleared.

**Candidates for 2048.** BusVerb's diffusers, allpasses, shimmer and
pre-delay are 2048-word modulo buffers (`m5 = $7ff`); Modulation's
`buffer_words=2048`; the firmware's PCM-pool block (`0x800` in the
recorder's block table at `0x80003c20`). The live state that produced it
is lost. When bisecting by hand, take slots to a stock effect, not NONE
(id 0 is SEND). `tools/hw/rec` must be the HAL recorder.

## Sequencer stuck on step 1 with every effect turned off: id 0 is SEND

**Symptom (image 85B, the first rig-burn image).** Step 1 solid with every
FX1 set to NONE and every FX2 set to SEND; the plain image played.

**Cause.** Id 0 is aliased to SEND and the FX1 chooser's NONE is id 0, so
SEND's proc runs on every FX1 slot set to NONE with r6 on that slot's
page, whose bytes are whatever the last effect left. The burn knob read a
stale slot-1 byte on four extra slots per core. The emulator never
instantiates an FX1-NONE slot.

**Fix.** Anything in SEND that reads a knob and can cost cycles or write
the bus gates on the slot being FX2 (`X:$213` base ≥ 0x4000, tested per
call); the burn does (`dsp/burn_send.inc`, `verify_burn.py` check 5).
SEND's AUX read has no such gate: whether an FX1-NONE slot with a stale
AUX byte registers as a phantom sender on the unit is an open hardware
claim.

## Line-F exception on [PROJ]: a cave pinned in OS .bss

**Symptom.** PROJECT throws an exception and wedges.

**Cause (measured, tag 91).** A cave pinned at `0x40108800`, inside the OS
image's last ~30 KB: a zero run at rest that is the PROJECT subsystem's
RAM.

**Fix.** `build_bus.SAFE_CAVE_CEIL` (0x400d8000) refuses any cave above
the decoded free region.

## Garbled audio straight after an OS upgrade: the warm-up tag

**Symptom.** Right after OS UPGRADE, audio is garbled (worse for the
delay). Not present after a reboot.

**Cause (inferred).** An OS upgrade rewrites program memory but does not
clear DSP state RAM; an engine skips warm-up when its tagged counter holds
a valid tag at full count (BusVerb `$2c0000` at `r7+$82`, BusDelay
`$2e0000`, Nimbus `$2d0000`).

**Fix.** Power-cycle after every upgrade before judging anything.

## A module mistuned on tracks 1-4 only: an absolute stock-table address ✅ measured

**Symptom.** An effect behaves differently on tracks 1-4 than on 5-8
(Bryan T's LOFI2 low-pass three times too bright on 1-4).

**Cause.** The two payloads are linked separately: the 6,305-word curve
bank is `X:0x438` in A and `X:0x42b` in B; the Y tables shift by 16. A
module is one source assembled into both, so an absolute stock-table
address is right on A (tracks 5-8) and 13 words off on B. The
single-payload audition render dumps payload A.

**Fix.** Never write a stock X or Y table address as a bare literal;
declare it so the build rewrites it per payload, or read through a
build-supplied base. Audit any stock-table read on both payloads with
`rig_render.py`.

## Self-oscillating squeal: a page-2 value out of range, or deep overrun

**Cause.** (1) A wild page-2 value (BusVerb DIFF stamped to 127
self-oscillates the tank: the +0x325/+0x331 stamp-offset bug, which is
also what flash 4's "the stock DELAY wedges the unit on part load" was;
T4's DELAY row landed on T5's BusVerb). (2) Deep cycle overrun (the
high-pitch squeal signature, `docs/firmware/CHIP.md`).

**Fix.** Re-stamp the project (1); fit the layout (2).

## "Z" screen / won't boot: corrupt OS

**Fix.** Startup Menu recovery: power off; hold [FUNC], power on; [TRIG 3]
MIDI UPGRADE; send a good `.syx` (`make midi-flash PORT=A SYX=…`, or a
SysEx app). `docs/remixer/FLASHING.md` §1.

## Cross-core bus glitch: the accumulators' race ✅ mechanism measured, fixed

**Symptom.** A tear, stutter or hash on wet audio that crosses cores,
often smeared into a reverb tail.

**Cause.** Core 0's housekeeping flips the rotation word in the middle of
core 1's frame and every client read the word directly, so a frame's
sends split across two buffers (measured under the port,
`docs/history/COLDFIRE_PORT.md` O12; `docs/effects/XBUS.md`).

**Fix.** Four ACC buffers; one rotation tracker per core (`build_bus.py`
ROTLATCH, payload B). No local test is evidence here: `dsp_host` runs the
cores lock-step or under a guessed interleave.

## CONTROL menu shows its stock six rows though the image carries eight 🔴

**Seen (tag 16).** The rows a module appended (the bus screen) were not
there; the image held row count 8 at 0x400cbd54 and the repointed row
pointer.

**Cause.** Unknown; the CONTROL rows are read from somewhere the patch
does not reach. The module is out of the tree; navigate to CONTROL in the
ColdFire emulator's own menu before any flash that appends rows again.

## The one-aux return never reached T8 ✅ measured under the port

**Symptom (flash 6).** Sending AUX produced wet out of T1 and T5, the
engines' own hosts; nothing arrived at T8.

**Cause.** The station pinned the return to track 8 by testing `r7 &
0xff00` against `$6700/$6800`, the harness's two-per-track model. The
stock dispatcher bumps r7 three times per track (FX1, FX2, an
unconditional third at P:0x51e), so track 8's FX1 runs with r7 = `$6a00`;
the pin never matched, the RET level was cleared, the station stamped
nothing. `verify_onebus` was green on exactly this property.

**Fix.** Pin `$6a00/$6b00`; the harness's r7 model corrected. Confirmed on
flash 7.

## The port reports a wrong bank/pattern for an image that detours `0x40087d44`: the instrument

**Symptom.** Under `ot_emu --sequencer`, an image hooking the engine's
BANK= store at `0x40087d44` plays bank 0 pattern 0 after LOAD PROJECT
(`saved_bank: -1`).

**Cause.** `rtos.cpp` learns the saved bank from a write watch on
`BANK_PTR` (`0x46c82456`) that accepted only writes whose PC is the stock
store; a detour makes the store from a cave's PC, the watch never fires,
and the port's transport-start re-select picks bank 0. A 38-site bisect,
a "narrowed to `unpack`" reading and a PR to midisc's author (withdrawn)
were built on it.

**Fix.** The watch follows a `jsr (abs).l` at the site and accepts the
store from the detour's own code; `--bank N` overrides. A port watch keyed
on a stock PC is blind to any module that detours that PC.
