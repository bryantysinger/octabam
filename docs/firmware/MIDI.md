# MIDI: how a CC, a scene or a note reaches a parameter the DSP reads

The disassembly records are `midi_re_cc.md`, `midi_re_scene.md` and
`midi_re_note.md`; this is the summary. Markers as in `CHIP.md`: ✅
measured / decompiled, 🟡 inferred. r2's m68k backend misdecodes ColdFire
`mvs/mvz/mov3q/mac`; read this code with `m68k-elf-objdump -m m68k:cfv4e`
(`scripts/disasm.sh emac`).

## MIDI in → parameters ✅

UART0 `0xfc060000` is MIDI IN; RX ISR `0x400106ec`, framer `0x40092bf4`
(running status `0x46100b70`), the MIDI thread `0x40005540` dispatching on
`status>>4` via `0x400d6474`: note-off `0x4000db98`, note-on `0x4000e018`,
CC `0x4000e79c`; realtime via `0x40001900` → `0x400d2d98` (F8 →
`0x40005a48`, a clock/tempo estimator writing `0x80001818/14`).

**CC map** (handler `0x4000e79c`): CC 16-45 → `idx = cc−16` (bounds `<
30`), posted as kind `0x40` to the kernel queue `0x460d17ae`; consumer
`0x40062496` maps `idx/6` through `{0,2,1,3,4}` to page_kind, `flat =
page_kind·6 + idx%6`. CC 40-45 = FX2 slots 0-5 (page 1). Other CCs: 7/46
level, 47 cue, 8 AMP BAL, 48 crossfader, 49-51 mute/solo/cue, 52-54 arm,
55/56 scene select, 59/60 synth note on/off, 61 send request, 112-127 →
`0x8000000c`. Unused: 0-6, 9-15, 62-111.

Page 2 is unreachable from stock CC: `cc−16 < 30` and the writer derives
`slot = flat % 6`. `modules/ccpage2` adds CC 62-67 (FX2 page 2) and
68-73 (FX1 page 2).

**The generic writer `FUN_40054cd8(track, flat, value)`** ✅ resolves the
descriptor via `FUN_40031da4(track, flat/6)`, refuses disabled slots,
clamps to `[min, min+count−1]` from `P+0x6a/P+0x9a`, stores to the Part
(`+0x8ee9a + track·24 + flat−6` for AMP/LFO/FX1/FX2), a shadow, and the
live byte `0x80000810[track·72 + flat]`; the frame builder `0x4000c0f0`
copies those `<<8` into the DSP frame every frame (why knobs sit at bits
16-23). The UI knob path is a near-copy, `FUN_40055008(slot, delta)`.
Page 2 is in the same 72-byte block ✅: an FX2 page-2 slot's live byte is
`0x80000810 + track·72 + 32 + slot2` (traced on tracks 0/1/4/7); page 1
occupies `+0..+29`. The FX2 page-2 editor's stores are Part `+0x8f084`,
shadow `0x100a51d2`, lane +0x38; the FX1 page-2 editor `0x4003abe4`
writes Part `+0x8f07e + track·30 + slot`, shadow `0x100a51cc`, lane
+0x32 (`PARAM_PAGES.md`, `FAILURE_MODES.md`).

## Scenes / crossfader ✅

`FUN_4003f1b4` handles only STRT/LEN/RATE. The general morph runs every
DSP frame inside the frame builder `FUN_4000c8a4` (`0x4000cc6c..0x4000cf3e`)
on the ping-pong frame copy; live param words are never touched. Scene
block = 8 tracks × 0x20; byte *k* ↔ frame halfword *k*; bytes 24-29 = FX2
page 1 (`r6+0..5`); the loop stops at halfword 17 of the page block; `0xFF`
= not locked. A lock is the knob byte `<<8` and the whole 16-bit halfword
is lerped (`A·xf/127 + B·(1−xf/127)`, MAC unit, weights `0x80003c60` from
curve `0x400bcd90`), so companion bits become fraction bits: page 2
cannot be scene-locked.

Fader position: `0x460d16c8` (long, 0..127), written by the panel path
(`0x40061e0a`, raw) and by CC 48 (`0x4006269a`, `127−value`); `xf=127` ⇒
scene A. Nothing of ours is hard-locked to the fader, and nothing of ours
reads it on the DSP.

## Notes ✅

Channel→track route `0x46c7febe[16]` from per-track channel
`0x8000003f+t` (−1 off) + auto channel `0x80000047`. Audio note map
(`0x4000e464`): 36-43 = sample trig of track note−36; 72-96 = chromatic
play (`0x4000e6e2`), which p-locks PTCH `64+5·(note−84)`, writes the held
note `0x400d64c2[t]` (byte, `0xFF` on release), a gate bit in
`0x46c7fb08`, and posts event 0x41. Velocity is never retained for audio
tracks. Per-channel held count `0x46c7fe4c[chan·4]`. The per-track loop
`0x4000e724..0x4000e790` writes `0x400d64c2[t]` for every track in the
channel mask with no machine-type test ✅; the only skip is the
panel-selected track when `0x46104cb0` is set and `0x40033970` returns 0
🟡 (an editor guard). On hardware: chromatic notes 72-96 on a track's
channel trigger reliably; sample-trig notes 36-43 never fired on the test
project; a note to the panel-selected track is eaten (keep an empty track
selected while driving notes).

## The DSP record ✅

The record (32 halfwords per track) is fully rewritten every frame
(`0x4000cb6e..0x4000cb7c` copies `0x80000830+72t` into `+0x24..+0x3d`
before `jsr 0x40004bd4`). Every halfword is read by something: `+0x24..
+0x28` (18-20) are the FX1 instance's page 2 (`r6_FX1+$c..$e` = `r6_FX2+
$6..$8`), `+0x2a..+0x2e` (21-23) the AMP page 2 (`r6_block+$15..$17`,
read by the dispatcher at P:0x231), `+0x30..+0x34` (24-26) the FX2 page 2,
`+0x36/+0x38` the ids, `+0x3a..+0x3e` (29-31) the writer's own words: a
per-track table word, the flag/split word (`r2+$1e`) and **tempo24
(`0x8000181c`) at `+0x3e`**, stored by stock at `0x40004d6a` for every
track. Retracted 15 Sep 2026: "`+0x24..+0x2c` are dead" (they were read
by no FX2 effect; the FX1 effect on the same track reads them).

The tempo cave (`modules/tempo-sync/tempo_cave.s`, hooked at `0x40004d40`
in the per-frame voice-record writer, for FX2 id 6) publishes one byte:

```
+0x1b  r6+$1 bits 8-15   held note (0x400d64c2[track]) or 0 on release
                         (the low byte of BusDelay's TIME halfword)
```

BusDelay reads tempo24 at `r6+$13` (`+0x3e`) and derives the MIDI-clock
period (42,336,000 / tempo24, Q12.4) per block. Until 15 Sep 2026 the cave
stored tempo24, the period, fader+1 and the note at `+0x24..+0x2a` (FX2
ids 6 and 7), which clobbered the FX1 page 2 and the AMP page 2's first
halfword on every host track (`docs/remixer/FAILURE_MODES.md`).

The track index is `a0 − 0x80000110` (`moveal %d4,%a0 ; addal
#0x80000110,%a0` at `0x40004d38`).

## Note → pitch on the DSP ✅

BusDelay latches the note in `y:>$090a` (HOLD: the last note sticks after
note-off; a never-received note leaves the PTCH knob in force). In GRAIN
the note drives the continuous pitch, `2^((note−84)/12)`, ±24 semitones.
`tools/verify/verify_midi.py` checks the note against the PTCH knob path
(bit-identical at unison, spectral elsewhere); `DNOTE=n` is the local
override. Hardware-confirmed: +12/+6/0/−5/−12 within 1/4 semitone.

## Hardware findings

- CC 40/41/43/44/45 (page-1 slots 0,1,3,4,5) work un-selected. CC 42 →
  slot 2 (TONE on the delay) lands in the Part (the panel shows the new
  value) but reaches the DSP only while the host track's FX2 page is on
  screen; the reverb's slot 2 (SIZE, T5) takes CC un-selected. Enable
  bitmap and min/count clamp verified sane in the image; the frame-builder
  path for that slot is the suspect. 🟡 untraced, single-slot; not a
  general rule and not page 2's.
- The OT echoes TIME as CC 40 with CC OUT on.
- Transport: the Rytm is clock master over its own USB port
  (`ot_midi.py -p "Elektron Analog Rytm MKII" start|stop`); never send
  start/stop to the OT's own port.
- A Midihub reverts to its stored preset on power/USB blips: save the
  session pipes (FROM A → drop-realtime-only → OCTATRACK).

## Remote CC reference

From the official appendices (OT MKII 1.40A Appendix C, AR MKII 1.72
Appendix C). ✅ = exercised here; 🟡 = manual-only.

**Octatrack, per-track channel:** CC 7 track level (receive-only) ✅, CC
46 track level (trn+rec), CC 8 balance, CC 25 AMP VOL 🟡 (amp page = CC
22-27), playback 16-21, LFO 28-33, FX1 34-39 🟡, FX2 40-45 ✅ (the slot-2
quirk above), CC 47 cue, 48 crossfader ✅, 49/50/51 mute/solo/cue, 55/56
scene A/B select. Pattern select via program change needs PROG CH receive
ON (PROJECT→MIDI→SYNC) 🟡.

**Rytm MKII, per-track channel** (RECEIVE CC/NRPN ON in MIDI CONFIG): CC
95 track LEVEL 🟡, CC 7 amp VOLUME, CC 8x amp page (81 overdrive, 82/83
delay/reverb send), CC 31 sample level, 94/93 mute/solo. FX track channel:
delay 16-23, reverb 24-31, distortion 70-77, compressor 78-85 (78 thresh,
81 makeup, 84 mix, 85 output vol) 🟡. Transport start/stop over its own
USB port only ✅.
