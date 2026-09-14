# The master, as it works today (14 Sep 2026)

A short page for anyone touching the rig: what track 8 does, in what order,
with which knobs, and what we know is true because it was measured on the
unit. Longer arguments live in `docs/effects/BUS.md` (the bus and the
returns), `modules/character/character.asm` (the chain, line by line) and
`docs/effects/VOICING.md` (the listening log). Confidence marks as in
`CLAUDE.md`: ✅ measured on the unit, 🟡 measured under the port or the
harness only, ❓ inferred.

## The shape

```
T1..T7  ──(AMP VOL, BAL)──▶ FX1 station ──▶ FX2 = SEND, one AUX knob ──(LEVEL)──┐
                                                                                 │  the mix
T1 FX2 = DELAY SERVER ─ wet ─▶ T5 FX2 = REVERB SERVER ─ wet ─▶ (the last live stage's wet)
                                                                                 │
T8 (MASTER TRACK on)  ◀──────────────────────────────────────────────────────────┘
   FX1 = CHARACTER:  x += RET × wet  ▶  SRR ▶ CRSH ▶ FOLD ▶ RING ▶ SAT ▶ COMP ▶ WDTH ▶ MIX
   FX2 = nothing
```

- **T8 is the master.** With MASTER TRACK on, T8's effect chain sees the
  sum of the other tracks' outputs after their LEVEL (✅ O9d/O14 under the
  port: T8's chain input equals T1 + T2 summed; AMP VOL and BAL are pre-FX
  on each track, LEVEL is post-FX at the mix). T8 has no FX2.
- **One aux send per track**, the AUX knob at slot 0 of every track's FX2
  (the six ordinary tracks run SEND there; T1's FX2 is the delay engine
  and T5's the reverb engine, and both still have their AUX). The delay's
  wet feeds the reverb (✅ flash 7). No send on T8: a loop is impossible.
- **The return is RET on T8's Character**, slot 4, by position (dispatch
  position 3 on payload A = track 8; anywhere else RET is inert). Each
  sample the last live engine's wet — the reverb's if it runs, else the
  delay's — is added at RET BEFORE the chain, so the master's saturation,
  compression and width act on dry + wet together (✅ flash 7: the return
  reaches T8, the hosts go dry while RET is up; the engines print their
  own wet on their host again within 3 blocks of RET going to 0).
- **The stations on T1–T7** (Character on T1, Spectrum on 2/3/4/6/7,
  Modulation on 5) are ordinary inserts; their defaults are a bit-exact
  passthrough under the harness (🟡 — on the unit they appear to run LIVE
  at the stamp, ❓ the page-2 publish; harmless for the sound since 14 Sep,
  see below).

## The stamp (`ot_project.RIG`, `ot_ladder` bank G)

| track | FX1 | FX2 |
|---|---|---|
| 1 | CHARACTER, defaults | DELAY SERVER, AUX 30 |
| 2, 3, 4, 6, 7 | SPECTRUM, defaults | SEND, AUX 40 / 30 / 40 / 50 / 40 |
| 5 | MODULATION, defaults | REVERB SERVER, AUX 40 |
| 8 | CHARACTER, RET 127, CMOD GLUE, COMP 40 | — |

Stamp every project for the current remix before play
(`tools/hw/ot_project.py stamp-defaults`); a part saved under an older slot
layout feeds the new layout its old bytes.

## Character on the master, knob by knob

Page 1: DRV, FOLD, CRSH, COMP, RET, TONE. Page 2: MIX, SAT, RING, CMOD,
WDTH, SRR. The chain runs in the fixed order drawn above; distortion sits
BEFORE dynamics on purpose (a compressor after the dirt is a tool, before it
is a fader for the dirt).

- **RET** — the return level. 127 in the stamp. Only meaningful on T8.
- **DRV / SAT / TONE** — DRV 0 is bit-exact, no saturation stage at all
  (✅ the master's whole mix would otherwise pass through a curve that is
  unity only for small signals). SAT picks TAPE (TapeHead; TONE is its
  tilt), TUBE (DaTube) or INFL (OInflator).
- **COMP / CMOD** — JClones AC1's console channel law: |key| (the mono sum
  of the station's own input) smoothed by attack/release; `Lv = K ×
  level`; `gr = (Lv²/2 − 1)² + a·Lv` clamped at 1 — a dip around Lv = 1
  whose depth is `a = 0.75 − 0.675·COMP/128`; makeup `1 / (1 −
  0.3375·COMP/128)`. GLUE: 0.5 / 500 ms, K = 3. COMP: 0.5 / 50 ms, K = 4.
  COMP 0 skips the stage bit-exactly. The stamp is GLUE 40. ✅ On the unit
  (image 8): COMP 40 / 80 / 127 keep both channels within 0.6 dB of each
  other, RET 0 or 127, WDTH 64 or 127.
- **WDTH** — mid/side: mid stays, side scales; 64 is neutral.
- **MIX** — out = x + MIX·(w − x); 127 in the stamp.
- **FOLD, CRSH, RING, SRR** — the dirt; all skip at 0.

## What it cost us to learn, and the rule that came out of it

**"The master compressor collapses the RIGHT channel above COMP 40"
(13–14 Sep 2026) was not the compressor.** A station whose init did not
clear all of its state ran with whatever the block held before it:
Spectrum's filter B keeps its two HP poles frozen at the passthrough stamp,
and `hp2 = yB − h2` subtracted a stale value from every sample forever — up
to a full-scale DC on that track's output. An AC-coupled capture cannot see
DC, so it surfaced as the master's makeup clipping DC + audio to a constant
on one channel. ✅ Localised on the unit by track LEVEL (post-FX mute cleared
it, pre-FX mute did not), reproduced under `dsp_host` with the block
pre-filled with garbage, fixed by zeroing every persistent slot at init in
Spectrum, Modulation and Character (PR #246), confirmed on image 8.

The rule now in `make verify` (`tools/verify/verify_dirtystate.py`): every
module of the remix is rendered from a garbage-filled instance block on
silence, at its defaults and with every knob nudged, and must stay silent.
The unit's RAM is never zeroed; the port and the harness always are.

## Open, as of 14 Sep 2026

- 🔴 A diagnostic image whose Character was 189 words shorter silenced every
  bank with stations on the unit while the port played them; padding the
  module back to the known placement plays. Placement, cause not bisected
  (`FAILURE_MODES.md`, "A diagnostic image silenced every bank").
- ❓ The stations run live at the passthrough stamp on the unit (the port
  bypasses them). Costs cycles, not sound; the pricer already charges the
  live price.
- 🟡 The audio engine can wedge with only BusVerb + the return (one freeze
  in ~15 minutes on 13 Sep); cause open (`FAILURE_MODES.md`).
