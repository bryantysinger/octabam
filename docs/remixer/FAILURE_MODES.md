# Hardware failure modes — the register

One place for "the unit is doing X" → what it means and what clears it, so a
symptom is recognised instead of re-diagnosed. Each entry: **symptom** (what
the panel/audio does), **cause** (measured, inferred, or unknown — marked),
**fix**, and provenance. Add to this the moment a mode is seen on hardware;
do not let it live only in a commit message or one doc.

Confidence, per `CLAUDE.md`: separate measured from inferred. A fix that only
"seems to work" says so until it is confirmed twice.

---

## Audio engine wedged, sequencer alive ✅ CAUSE MEASURED 6 Sep 2026: the MASTER LOOP

> **STRUCTURAL FIX BUILT 7 Sep 2026 (one-aux rig, unflashed):** the
> stations have no sends, and the SEND is REFUSED at track 8's dispatch
> position on payload A whatever its knob says, so the master cannot send
> into the bus it returns. `tools/verify/verify_onebus.py` pins both.

**Symptom.** The sequencer runs (steps advance, transport works), but **no
audio plays** — not the tracks, and a **sample preview triggers but is
silent** too. The **record meters for B/C/D sit lit permanently**. Distinct
from the DSP-hang mode below: there the sequencer freezes; here it runs.

**Cause.** Not established. The frame interrupt is clearly still firing (the
sequencer is clocked by it), so it is the audio path / output mix that is
wedged, not the whole DSP. Candidates, unconfirmed: a cross-core bus /
accumulator wedge (this class has bitten before — `docs/effects/XBUS.md`), a
transient cycle overrun on a core near budget, or stale DSP audio state.

**Fix.** **Power-cycle** — CONFIRMED (5 Sep 2026: wedged mid-play on the
tag-93 rig, a power-cycle brought audio straight back). Recurring; Sam has
seen it before. If it recurs, capture what was playing when it wedged.

**Falsifier / next step.** If it recurs on a specific action (a bank change,
a heavy station turned up, the returns engaging), that names the cause. Log
the trigger here when seen.

**Recurrence, 6 Sep 2026 — WEDGED ON EVERY COLD BOOT INTO OCTABAM_RIG,
three images in a row (tags 16, 17, 18), NOT cleared by power-cycles.**
Localised without a flash:
- The image is innocent: tag 18's DSP is byte-identical to tag 13's, which
  played (807 ColdFire bytes differ, all chooser/descriptor plumbing).
- The project stamp is innocent: PROJECT 260810, stamped the same way, plays.
- A Pheasant set (no octabam engines) plays.
- **Cleared by SWITCHING PROJECTS and back** (Pheasant → 260810 → OCTABAM_RIG:
  "playing now without me doing anything"); reboots are clean since. So it
  is PERSISTENT STATE that the project switch REWROTE — the unit writes the
  current project's files before loading another. The wedging state is in
  the Friday backup (`~/octa/backups/PRESETS_20260905_pretag16/OCTABAM_RIG`)
  and the cleared state is on the card: **diff the two on the next mount
  (project files first, then banks) — the changed bytes name the state.**
- What OCTABAM_RIG has that 260810 does not: the RETURN engaged on every
  part (T8 FX1 = Character, SAT = BUS, RVRB 127, DLY 127 — never before run
  on hardware), and in bank02 the master's own -VRB send at 71 (the loop the
  spec forbade). Sam suspected a loop first; the "a loop would squeal, not
  go silent" dismissal was reasoning, not measurement — RETRACTED. Whether
  either is the cause is NOT established.
- **MEASURED (next mount, 6 Sep):** card vs the wedging backup — banks differ
  ONLY by the stamp (18 bytes each); `project.work` differs in TWO fields:
  the header's OS version string `OCTABAM13` → `OCTABAM18`, and `TRACK=4`
  (T5, the reverb host, selected) → `TRACK=7` (T8). Nothing else. Backup of
  the cleared state: `~/octa/backups/OCTABAM_RIG_20260906_cleared`.
  Prediction to test: tag 17 on the card, project says 18 → if the cold boot
  wedges, the saved-OS-version mismatch is the suspect (and every flash
  needs a project switch after it); if it plays, the selected-track-at-boot
  is what remains (select T5, save, cold boot).
- **✅ MEASURED, 6 Sep 2026 (tag 17, OCTABAM_RIG silent after a project
  switch): turning T8's FX1 -VRB from 71 down to 0 brought the audio back,
  live.** The master's station (Character, SAT = BUS = the return point)
  was SENDING into the reverb bus it RETURNS — the one loop the design
  forbids ("a master that sends into a bus it returns is the one loop
  left"). Sam called it a loop on the first symptom. Why the loop reads as
  SILENCE rather than a squeal is not established (inferred: the bus
  auto-gain / the return's clear-on-read stamp collapsing, not measured).
  The version-string idea was falsified the same hour (switching back under
  a matching tag was still silent) and the one earlier "cleared by a
  switch" was a different bank coming up: bank01's parts have T8 -VRB 0,
  bank02's have 71.
- **Fix, immediate:** T8 -VRB = 0 in every part (a track-filtered
  `stamp-slot`), and SAVE. **Fix, structural:** a station in BUS mode must
  not register or send at all — closes the loop by construction — and the
  spec's rule stands: the master's station carries no sends.
- ⚠️ Two wrong calls made the same day, both logic leaps: "intermittent"
  (it never cleared on a reboot) and "cleared by a power-cycle" (that was
  the 5 Sep instance, not this one). Say only what was observed.

---

## The audio engine wedges with ONLY BusVerb + the return 🔴 REPRODUCED UNDER MEASUREMENT, CAUSE OPEN

**Symptom.** Playing, the output drops to the noise floor and never comes
back while the transport keeps running. Same family as "Audio engine wedged,
sequencer alive" above, but this entry pins the *minimal* configuration and
gives a repeatable harness.

**Measured (13 Sep 2026, image 94, `tools/hw/ot_soak.py`).** The layout was
T5 FX2 = BusVerb and T8 FX1 = Character in `SAT=BUS` as the return — nothing
else of ours. No stations, no Modulation, no BusDelay:

| configuration | return level | 3 min soak |
|---|---|---|
| return alone, no engines | 127 | clean |
| BusVerb, return at 0 | **0** | clean (twice) |
| **BusVerb + return** | **127** | **silent at 131.5 s, never recovered** |
| the same, repeated | 127 | clean |
| the same, 9 min | 127 | clean |

**So it is NOT the cycle wall.** This layout is nowhere near it. The 13 Sep
morning reading — "core 0's shipped layout is over the real wall", from
T6/T7's stations going to NONE and the unit then playing — cannot explain a
wedge with two modules loaded. That reading is not retracted (the layout may
*also* be over the wall) but it is no longer sufficient.

**Rate: one freeze in ~15 minutes** at this layout. Rare enough that a single
3-minute pass cannot clear a configuration, which is the trap to avoid when
bisecting: two of the rungs above "passed" before the return was noticed to
be at 0.

**Recovery: a transport restart cleared it** — no power-cycle needed, unlike
the 5 Sep instance recorded above. Worth knowing whether those are the same
mode.

**Cause. NOT ESTABLISHED.** The only configuration that has ever wedged is
the one where the reverb's output actually reaches the mix, which points at
the return path rather than at the reverb's own DSP. Not enough runs to call
it.

**Falsifier / next step.** Soak `BusVerb + return` against `BusDelay +
return` for long enough to compare rates (tens of minutes each, given one
event per 15 min). If only the reverb wedges, it is the reverb's contribution
to the return; if both do, it is the return or the bus itself.

---

## BusDelay went silent with its knobs pinned ✅ CAUSE MEASURED 13 Sep 2026 evening: the MODE formatter cave wrote its rename bytes over the MINIMUM table

**THE CAUSE (measured under the ColdFire emulator with a write watch, 13 Sep
2026 evening; fixed the same evening in `tools/build/mode_names.py`).** The
MODE-select formatter that renames a mode's neighbouring knobs
(`mode_names.py`, 3 Sep 2026) was handed the clone's PAGE descriptor `P` and
wrote the names at `P + 0x4e + 6·slot`. The names live at `E + 0x4e` and
`P = E + 0x38` (PARAM_PAGES.md), so every rename landed 0x38 too high: in the
**minimum-value table** (`P + 0x6a + 4·slot`). BusDelay's GRAIN names
("MDEP"/"MRAT" restored, "SCAT"/"DENS" set) hit `min[3..5]` — **TONE, PING,
MIX** — with 0x4d444550 and 0x4d524154: a knob whose minimum is 1.3 billion
cannot be turned and publishes nonsense, so the delay went dead and its
encoders locked **whenever the panel formatted the delay's MODE** (page 2
drawn). A reboot reloads the image and clears it; the ladder never drew the
page and measured the delay working all evening. Sam's second sighting
named exactly TONE, PING and MIX. `verify_modenames` read the names back
from the same wrong offset and passed — a verifier circular with the write
it checks. Character's SAT view (slot 2 → `P+0x5a`, defaults[0..1]) and
Modulation's COMB view (slot 6 → `P+0x72`, `min[2]` = FDBK) had the same
fault with smaller blast radius. Fixed: `NAMES_AT = 0x16` (P-relative), the
verifier reads there, the emulator shows mins untouched and SCAT/DENS
landing. Needs a flash (a ColdFire cave). The earlier text below is kept as
the record of how it presented.

## BusDelay went silent with its knobs pinned (the earlier record)

**Symptom.** No delay is audible anywhere in the rig. Sam by ear first
("it's been on mix 127 this whole time which seems strange as I can't hear
delay"); confirmed by measurement.

❌ **THE "TIME IS INERT" MEASUREMENT IS RETRACTED (same session).** It read
the envelope autocorrelation of the WHOLE MIX and reported 248 ms at TIME
40/100/15 — unchanged, therefore "inert". But 248 and 496 ms are the eighth
and the quarter at 121 BPM: the peaks were the MATERIAL every time, and the
instrument could not have shown a delay-time change if there had been one.
After the reboot Sam heard TIME move clearly while the same measurement still
reported 249 ms at every value. **The ear was right and the metric was blind**
— the fourth instance this session of a null from an instrument that cannot
see the thing it is being used to rule out.

**The right instrument** (untried): stop the source mid-capture and measure
the SPACING OF THE DECAYING REPEATS, which is the delay time by construction
and has no material in it. Autocorrelating a mix against tempo-locked
material never will.

⚠️ **The first explanation offered was wrong and is retracted**: that both
stages at `MIX 127` give "reverb-of-delay" so the repeats are smeared rather
than absent. Taking BusVerb's MIX to 0 (the reverb then passes the delay
through by the stage law `out = in*(1-MIX) + wet*MIX`) did not make repeats
appear.

**AND ITS KNOBS ARE LOCKED (Sam, same session, the key observation).**
BusDelay's `TONE`, `PING` and `FDBK` sat at **68 / 0 / 84** and **the panel
encoders would not move them**. Those are not the manifest defaults (TONE
100, PING 0, FDBK 60), so they are stale values from somewhere, held against
the knobs. Then: *"when I jiggled around the knobs on the delay it started
working and is working now. Knobs still locked."* So the delay's silence and
the frozen parameters are the same fault, and it is recoverable by panel
activity without the values unlocking.

That a page-1 parameter can be pinned against the encoder has one obvious
stock mechanism: **page-1 params are scene-lockable** (BUS.md: "sends are
page 1 → scene-lockable: scene A dry, scene B wet"), and a held scene
overrides the knob. The crossfader position would then be selecting 68/0/84.
NOT YET TESTED — the discriminator is to move the crossfader (CC 48) and see
whether the three values move with it.

**A REBOOT CLEARED IT.** After a power-cycle (no save) the delay is audible
and TIME responds by ear. So the pinned knobs and the silence were **RAM
state, not stored data** — a runtime fault that will recur, not something
wrong on the card. That is the useful half of this entry.

**13 Sep 2026 evening — THE VALUES WERE STORED IN THE PART, not only RAM.**
OCTABAM86 bank A part 1 (the part yesterday's session played) holds BusDelay
`AUX 90, TIME 20, FDBK 85, TONE 68, PING 28` (page 2 `MRAT 70, SIZE 0, PTCH
68`), every other track's AUX at 110–127, and BusVerb at `AUX 0, MIX 0`; parts
2–4 hold TONE 68 and banks B/C TONE 0. So the "pinned 68/0/84" reading was
the part's own bytes (85 read as 84 at the panel, or one step moved), and a
rig with every send near full into a delay at FDBK 85 with a dark TONE is the
"loops and mess" of the last days by construction. Read with
`tools/hw/ot_ladder.py`'s diff on the card; the rig re-stamped from the
manifests (`OCTABAM87`, rigproj with the fixed stamper) measured clean on the
ladder at every rung and under a 5-minute page-1 stress. Why the encoders
would not move a stored value is still open.

**Cause. NOT ESTABLISHED.** Scene locks are ruled out: Sam checked by holding
scene A and scene B, no locks. Untested: whether the delay is audible with
BusVerb out of the chain entirely (T5 FX2 → a stock effect), and what the
"jiggling the knobs" that restored it actually touched — that step is lost,
which is why the next occurrence should be captured before anything is
moved.

---

## CC PAGE 2 does not write on hardware ✅ CAUSE FOUND AND FIXED 13 Sep 2026 evening (image 96): the cave used the PLAYBACK page's stores — see "An FX1 station's PAGE 2" below (was 🔴 MEASURED 13 Sep 2026, image 94)

**Symptom.** CC 62-67 change nothing. The panel value does not move, with the
transport stopped or running.

**Measured.** Sam set T5's BusVerb SHMR to 0 on the panel; one `CC63 ch5 =
127` was sent; the panel still read 0. Repeated with the transport running
(a running transport redraws the screen constantly, so a stale display was
the alternative explanation) — still 0.

**The image is correct**, so this is not a build or link fault: the cave sits
at `0x400d7700` in `out/mainos_bus.bin`, and the CC dispatch vector at
`0x400d64a0` holds exactly that address. The unit reports `OCTABAM94`, so the
flash took.

**Cause. NOT ESTABLISHED.** `tools/verify/verify_ccpage2.py` proves the write
**in the emulator** against the firmware editor `0x4003a474`, and passes. So
this is the standing rule again — the harness's model of the dispatcher is
not the dispatcher, and a hardware failure the lock-step harness cannot show
goes to the ColdFire port before it goes to a guess.

**Consequence for anything measured on page 2.** BusVerb's DIFF, SHMR, SHFT,
GATE, RATE and MODE cannot be driven remotely. A page-2 sweep run over MIDI
on 13 Sep reported "no change at any value" for all six and **that result is
void** — the CCs never landed. Page 2 is untested, not cleared. Page 1 *was*
swept with verified CCs and is genuinely clear.

---

## Re-selecting an effect zeroes the bus: the return level and every AUX ⚠️ 13 Sep 2026

**Symptom.** A rig that measures dead after ordinary panel work: no wet, the
engines apparently doing nothing, soak after soak passing because nothing is
connected.

**Cause (measured).** A re-select loads the module's MANIFEST DEFAULTS, and
the two knobs that connect the bus both default to 0 — BusVerb's `AUX` (0 is
load-bearing: a non-zero default registers every idle host as a bus client
and dilutes the real senders by N/(N+1), the -6.02 dB phantom-client defect)
and Character's return level, which in `SAT=BUS` is the repurposed `CRSH`
slot. Two ladder rungs passed spuriously this way before it was caught: the
give-away was that killing every send changed the output by +0.68 dB when the
same test on the stamped project gave -2.13 dB.

**Fix.** Assert the connections over MIDI immediately before every
measurement, never after a re-select: return level `CC 36` on the master's
channel, `AUX` `CC 40` per track. `ot_soak.py`'s docstring carries the
warning.

---

## A station stamped "at its defaults" was running its default MODE'S VIEW — a chorus on T5 in every RIG project since 12 Sep 2026 ✅ MEASURED 13 Sep 2026

**Symptom.** A station that documents a bit-exact passthrough at its
defaults changes the track's level. On the 13 Sep ladder, adding the
stations at "passthrough" (rung F against rung E) dropped T5's solo by
2.5 dB; the emulator renders Modulation CHOR at MIX 64 as −2.1 dB on a tone
and −3.8 dB on noise against MIX 0.

**Cause (measured).** `ot_project.module_defaults` applied the ModeView of
whatever MODE the manifest defaults select — for Modulation that is CHOR,
whose view sets MIX 64 and RATE 30 — so `rigproj` and `stamp-defaults`
wrote a chorus at half mix into every T5 since the mode-aware stamper
(PR #217). No other module's default-mode view differs from its manifest.

**Fix.** A view applies only when the MODE is explicitly chosen (given in
the knob dict); the manifest defaults are the stamped default. Re-stamp
the RIG projects.

**Falsifier.** Re-stamped, T5 with Modulation must solo within the
rung-to-rung scatter (±0.4 dB) of T5 without it.

---

## PARSE ERROR loading a generated project — a PART record copied whole keeps the DONOR'S INDEX ✅ MEASURED 13 Sep 2026

**Symptom.** LOAD PROJECT on a project written by our tooling stops with
"PARSE ERROR"; the same tooling's earlier projects (rigproj, testproj) load
fine, and so does the source project. Reliable, not intermittent, for the
affected project.

**Cause (measured).** Every PART record in a bank file carries **its own
index in byte 8 of the record** (the pad byte after the 8-byte tag+length
header): parts 1–4 hold 0, 1, 2, 3 and the saved mirrors 5–8 repeat 0, 1,
2, 3 — on every bank of the set. The first ladder project
(`tools/hw/ot_ladder.py proj`) copied the material's part 1 record whole
into all eight slots, so parts 2–4 claimed index 0, and the loader refused
the bank. rigproj/testproj never tripped it because they edit fields inside
a record and never move a record.

**Fix.** Write `p % 4` into byte 8 after any whole-record copy
(`ot_ladder.PART_INDEX_OFF`); the generator's read-back now checks the tag
and the index of every record. The other known parse error is different:
`project.work` edited in text mode loses its CRLF (Flash 7 notes,
`hw_flash7.stage`).

**Falsifier.** A whole-record copy with byte 8 corrected that still throws
PARSE ERROR would mean another per-record field is indexed; the PTRN
chunks carry no such byte (their 16-byte headers are identical across
patterns) and pattern 1 <- A2 loads.

---

## Sequencer stuck on step 1 (DSP hang) — CYCLE OVERRUN or a wild value

**Symptom.** Press play, the playhead lights **step 1 solid and never
advances.** No audio. The sequencer clock is the DSP frame interrupt, so a
hung core looks exactly like a dead transport.

**Cause (measured, 4–5 Sep 2026).** A core cannot finish a block. Two ways:
(1) **cycle overrun** — too much on one core (e.g. three heavy stations
beside an engine priced ~3,106 of 3,120 as a *floor*, over once contention
is added; `tools/build/cycle_count.py` is a floor, the wall is a cliff); (2) a
**wild stored value** feeding an engine on frame one (an old part's
crossed-slot byte after a layout change — the MODE re-slot family).

**Fix.** Fit the layout (≤ two heavy stations per core — the rig project's
`RIG` table, `tools/hw/ot_project.py`), and **stamp the project** for the
current remix before playing (`ot_project.py rigproj`/`stamp-defaults`) so no
stale byte reaches an engine. The single-core, no-project emulator cannot see
either — only the unit can.

---

## The RET/CRSH trap: a mode change on the master turned a 127 return into a 127 crusher ✅ REMOVED BY DESIGN 13 Sep 2026 (unflashed)

**Symptom.** With T8's Character in BUS mode and knob 3 (RET) at 127, turning
SAT to TAPE made the whole mix a 4-bit crush at full scale — the same knob
was RET in BUS and CRSH everywhere else (Sam: "huge noise, something wrong
with this effect").

**Cause.** By design: BUS was a mode of SAT that repurposed CRSH and RING as
the return levels (3 Sep 2026), so the return's existence depended on a
page-2 select — which on a THRU track the panel cannot even set (the entry
above). Two ways to blow up the master with one turn.

**Fix (built 13 Sep evening, gated, unflashed).** No BUS mode. Character is
one insert with TAPE / TUBE / FUZZ on every track, T8 included; slot 4 is
**RET**, the return level, live by DISPATCH POSITION (position 3 on payload
A, the same pin the return always had) and inert elsewhere; the wet enters
at the FRONT of the chain on the master, so glue, saturation, width treat
dry plus wet (safe: the stations have no sends, T8 cannot send). And **DRV 0
now skips the saturator stage entirely** (bit-exact, a per-block flag): the
tanh curve at 1x drive was unity only for small signals, which the one-aux
gate exposed once the wet went through the chain. `verify_character` 22/22,
`verify_onebus` 25/25. Sam's bar: "the Elektron way, where everything works
everywhere."

---

## An FX1 station's PAGE 2 does not reach the DSP on T1: the panel's SAT and the stamped bytes both ignored 🔴 MEASURED 13 Sep 2026 evening, MECHANISM OPEN

**Symptom.** Character on T1 (a THRU, FX1) makes a quiet tone at idle on the
set project; Sam: "it's the ret knob (3) on character ... turning that up
introduces trash ... it says CRSH on TAPE and RET on BUS, both cause the
issue".

**Measured (`out/hw/ladder/t1crush_{bus,tape}.log`).** Transport stopped,
T1's THRU gate open (an open input, ~−100 dBFS floor), knob 3 driven over
CC 36 on channel 1 with the panel's SAT at BUS, then at TAPE:

| knob 3 | SAT = BUS (panel) | SAT = TAPE (panel) |
|---|---|---|
| 0 | −101.7 dBFS | −101.7 |
| 64 | −100.7 | −100.7 |
| 100 | — | −71.3, flat + 500 Hz |
| 127 | **−47.2, flat broadband + 500 Hz tone** | **−47.2, identical bands** |

That is the BIT CRUSHER on the input floor (masking the low bits of
near-zero negative samples snaps them to a large negative value: at 4 bits a
−100 dBFS floor becomes a −47 dBFS square-ish mess; at 14 bits it quantises
to nothing). In BUS mode the source sets the crush mask to identity AFTER the
knob decode and clears the return level on payload B, so knob 3 should be
inert on T1 — **the DSP on T1 is in TAPE whatever the panel says.** The idle
"tone" at −77 dBFS was this crusher on the floor (Sam: disabling or
re-selecting the effect removed it; re-select loads defaults, CRSH 0).

**What it implies.** For an FX1 slot on T1, a page-2 edit at the panel does
not reach the DSP; the stamped page-2 bytes (`P2_OFF + track*30 + 0..5`)
are therefore also unverified for FX1 — the Stage B blocker ("which staged
index/lane an FX1 page-2 edit uses") with a symptom. Contradiction to
resolve: T8's Character in BUS mode DOES return the bus on hardware (flash
7, tonight's tails), so on T8 the SAT byte reached the DSP — the T8 crush
test (SAT = TAPE at the panel, knob 3 to 127 over CC 36 while playing)
decides whether page 2 reaches the DSP on the master only, or only via the
stamp and never via the panel.

**MECHANISM: THE COLDFIRE SIDE IS EXONERATED (port, 13 Sep evening, two
runs).** ❌ The first run's model — one page-2 editor `0x4003a474` writing the
lane at `+0x20 + staged_index*6`, so a THRU track's FX1 page "stages the
wrong index" — is RETRACTED: that routine is the PLAYBACK page's editor. The
FX1 page has its own, `0x4003abe4`, which writes the Part at `+0x8f07e +
track*30 + slot`, the shadow at `0x100a51cc + …` and the live lane at
`0x80000842 + track*72 + slot` (= +0x32, exactly the lane the per-frame
copier `0x4000cae8` delivers to the DSP record as FX1 page 2), with no page
or index term — and called under the emulator for T1 (THRU), T3 and T8 its
three writes landed exactly there on every track (PARAM_PAGES.md "The
page-2 lanes"). So the panel edit reaches the right lane on T1. **The fault
is downstream of the lane**: the DSP side at position 0 on payload B, or a
per-frame refresh of that lane peculiar to a THRU machine — not measured.
Hardware facts that any explanation must fit: T3 (STATIC, Spectrum MODE
LP→HP, `out/hw/ladder/bisect95/t3mode_{LP,HP}.wav`: rms −74 → −58, low
bands +27 dB) and T8 (FLEX master, Character SAT) take a panel page-2 edit;
T1 (THRU) does not; a T1 one-step SAT edit showed on neither the AMP nor the
LFO page 2; the stamp reaches all three. Next instrument: the port with
`--watch` on `0x80000842..0x80000847` and on T1's DSP record bytes 36-41
across frames after an FX1 editor call, THRU machine loaded.
**Consequence found on the way:** the CC PAGE 2 cave (`modules/ccpage2`)
used the PLAYBACK editor's three stores, so every CC 62-67 corrupted the
track's PLAYBACK page-2 byte and never touched FX2's; SHMR "moved" on 5 Sep
only because its DISPOFF write happened to hit the real FX2 Part byte. Now
on the FX2 editor's own stores (Part `+0x8f084`, shadow `0x100a51d2`, lane
+0x38), `verify_ccpage2` real and green — ✅ **CONFIRMED on image 96, 13 Sep
2026 evening:** CC 63 on channel 5 moved the SHMR knob on the panel (Sam) and
raised the tail's 2–8 kHz bands by 5–8 dB (`out/hw/ladder/ret96.log`).

**Interim for the set:** keep every station's knob 3 at 0 on FX1 tracks;
the stamp writes 0 there.

---

## A DC thump every 10.59 s at idle, from TRACK 6 ✅ SOURCE MEASURED 13 Sep 2026 evening: T6's LFO 2

**Symptom.** Transport stopped, nothing playing: a thump every 10.59 s, heard
as "bursts"; through the return it rings for 2 s.

**Measured (image 95 and image 94, OCTABAM87 and the ladder project,
`tools/hw/ot_ladder.py probe`/mute bisect, `out/hw/ladder/bisect95/`).**
- A **DC step**: +0.23 FS on L, +0.46 FS on R (R = 2·L exactly), rising in
  two samples, then the output DC blocker bleeds it away over ~35 ms.
  Period 10.577 / 10.588 / 10.592 s (466,930 samples).
- **On every ladder rung including A** (FX1 NONE, FX2 SEND with AUX 0 — no
  bus engine, no station), identical level; so not BusVerb, BusDelay, the
  stations, or the mode-rename cave fix (94 and 95 alike).
- **Track 6.** All eight tracks muted: −37 dBFS residual. Unmute T6 alone:
  the full −21 dBFS; any other track alone: −37. The residual is T6's send
  returning through the master, which a mute does not cut. T6 is a STATIC
  machine (slot 13, "Chupa Gat.wav", 23.78 s) with NO trigs in A02.
- **Between amp and level on T6:** AMP VOL 0 (CC 25) leaves it; track LEVEL
  0 (CC 46) removes it to the residual; all-sound-off / all-notes-off on
  channel 6 leave it; STOP sent twice leaves it.
- **Absent from all seven of the 13 Sep morning idle captures** (image 94,
  OCTABAM86 with the delay hosted on T1 at FDBK 85, sends 90–127).

**Not on the MicroBook's other inputs** (channels 0/1/4/5 clean), so it is
the unit's output.

**SOURCE (measured, same evening).** Zeroing T6's three LFO depths over MIDI
(CC 29/31/33 on channel 6) removes the thump entirely (floor −104.7, no
bursts); raising LFO 2's depth alone to 64 brings it back at the full −21
dBFS, LFO 1 and LFO 3 alone do nothing. The 10.588 s period is 64 steps at
121 BPM with a 3/4X scale — an LFO cycle, free-running with the transport
stopped. Confirmed independent of the effect slots first: a ladder bank with
T6 = Spectrum + stock DELAY (no SEND on T6) and every bank of OCTABAM87
(different T6 content per bank) thumped identically. What the LFO's
destination is, and why a parameter step lands as a DC step of +0.23/+0.46
FS in the audio with nothing playing, is the open half — the panel read of
T6's LFO 2 (DEST/SPD/MULT/WAVE/TRIG) decides whether it is the set's own
setting or a destination our image turns into DC. It was absent on 13 Sep
morning because those captures played a different part.

**The LFO, read from the part (`ot_project.py lfo`, octalab's offsets +9,
matching the panel):** T6 LFO 2 = destination 16 (AMP BAL), triangle, speed
18, depth 21, FREE — not deliberate (Sam). Any non-zero depth gives the
same −21 dBFS pulse; a plain BAL move over CC 8 never does, on any track;
the pulse rate follows the LFO speed (SPD 127: every 65 ms). The set's
parts also carried T8 LFO 2 on AMP BAL (depth 47) and T5 LFO 1 at depth
127 on an effect page. **Cleared: every LFO depth in OCTABAM87 and the
ladder (`lfo-clear all`, 13 Sep 2026 evening).** Open: whether a balance
LFO pulses on stock 1.40C too, or only on our image (the pan stage is
stock; its table may sit in harvested memory) — the port with a fast LFO
fixture decides it without a flash.

**Earlier suspect, retracted by the above:** T6's FX chain in rung A is SEND on both slots (id 0 runs SEND
on this image), the only code of ours in that rung — INFERRED, not shown:
the stock null effect and the track's own output path are not excluded.
The discriminator is a ladder bank with T6's FX2 = stock DELAY and FX1 =
NONE, and one with FX1 = a station and FX2 = stock DELAY (no SEND on T6):
if the thump goes with SEND, it is SEND. Why T6 (position 1 on payload A)
and why 10.59 s are open. A separate 593.5 Hz tone at −75 dBFS (with a
1187 Hz harmonic, mono) was measured after STOP on OCTABAM87 only, not on
the ladder project — cause open, project-dependent.

---

## Spectrum VOWL goes SILENT with RES up 🟡 MEASURED ONCE 13 Sep 2026 (image 96) — NOT REPRODUCED, suspect the CC-follows-the-displayed-page quirk

**Measured (`out/hw/ladder/spectrum/VOWL_F*_R*.wav`, T3 soloed, FREQ/RES over
CC 34/35, MODE set at the panel).** VOWL at RES 0 filters across FREQ (−42
to −45 dBFS, the tilt moving with FREQ); at **RES 100 with FREQ 96, 64, 32
or 0 the output is −102 dBFS — silence**, and RES 127 at FREQ 64 likewise.
FREQ 127 RES 100 still passes (−45 dBFS). LP, BP, HP and NTCH stay bounded
at RES 127 (peaks −17 to −23 dBFS). So the two-peak vowel's resonant path
collapses above some Q rather than ringing. Not a voicing choice: a defect
to reproduce in the emulator (`dsp_host`, MODE 4, RES ≥ 100, FREQ ≤ 96) and
fix; suspect the peak filters' coefficient range or a limiting store
clamping the state to zero.

**Later the same evening:** `dsp_host` does NOT reproduce it (every silent
cell renders at −22..−34 dBFS, resonance rising with RES like LP/BP; 4 s
renders at the unit's level flat within ±1.5 dB). And on the unit, image 97,
with MODE set over CC 69 and the same knobs moved in BOTH orders (RES first
then FREQ, FREQ first then RES, RES back and forth, a mode round-trip) VOWL
never went silent (`out/hw/ladder/vowl_order.log`, −36..−44 dBFS). The one
difference from the silent run: then T3's FX1 **page 2 was on screen** (Sam
had just set MODE at the panel) while the page-1 CCs were sent, and Sam saw
DRV (page-2 slot 0) flash on a CC 34. Hypothesis: an incoming page-1 CC is
routed by the DISPLAYED page (MIDI.md's slot-2 on-screen dependency is the
same family), so CC 35 = 100 landed in page-2 slot 1 = MODE = 100, out of
its count of 5 — the index trap — and the DSP went silent on the next
coefficient update. Discriminator: page 2 on screen, CC 35 = 100, watch
MODE. **Tested, falsified (image 97):** with T3's page 2 on screen a CC 35 =
100 left MODE at LP and landed on RES (page 1 read 100). And the EXACT
sweep that went silent, repeated with MODE set over CC 69 and page 1 on
screen, is clean in every cell (`VOWL2`: −35..−50 dBFS, RES 127 bounded at
−22 dBFS peak). So the silence is bound to what differed: image 96, MODE set
at the PANEL (the editor's refresher `0x40027e00` runs there and not on the
CC path), page 2 displayed during the page-1 CCs. Seen once. If it recurs
at the panel, capture before touching anything; the CC path is the one the
voicing rounds use.

---

## A one-sample tick on an exact 2048-sample grid at idle 🔴 MEASURED, CAUSE OPEN

**Symptom.** With the sequencer STOPPED and nothing playing, the main outs
carry a **one-sample downward spike, common-mode on L and R, −45 dBFS peak**,
at irregular intervals of a few hundred ms. Audible in a quiet room as an
intermittent tick; occasionally one is large enough that its reverb tail
lifts the noise floor to ~−90 dB for about a second, which is what reads by
ear as a "static burst". Present with the reverb's track MUTED.

**Measured (13 Sep 2026, image 93, ChongBongolo26, two 30 s captures off the
MicroBook, `tools/hw/rec`).** Reproducible to 0.001 samples between captures:

| | capture A | capture B |
|---|---|---|
| ticks in 30 s | 23 | 24 |
| grid period | 2048.050 samples | 2048.049 samples |
| fit residual over 631 periods | 0.29 samples | 0.25 samples |
| peak \|Δ\| between adjacent samples | 6.06e-3 | 6.04e-3 |

Three things follow from the fit and are worth reusing:

- **The unit generates it, not the capture rig.** The grid is +24 ppm off
  2048.000; forcing the period to exactly 2048 (the recorder's own clock)
  makes the fit 33× worse. Two unsynchronised converter crystals. A USB or
  CoreAudio dropout would land on exactly 2048.000.
- **It is not a cycle overrun.** An overrun drops blocks at arbitrary times;
  this is locked to a buffer boundary to a third of a sample over 30 s.
- **It is intermittent AT the boundary, not always-wrong.** Folding all 632
  wraps onto the grid: 96% of wraps are clean at the wrap point and 4% spike.
  The gaps between ticks are 8, 10, 18, 21, 29, 31, 47… wraps with no common
  divisor — a beat against a second process, not a sub-period.

**Cause. NOT ESTABLISHED.** 2048 samples has at least three owners and the
capture cannot choose between them:
1. BusVerb's lines — diffusers, allpasses, shimmer and a 2048-word pre-delay
   are all 2048-word modulo buffers (`m5 = $7ff`).
2. Modulation's buffer — `buffer_words=2048` on the stock instance buffer
   (`modules/modulation/manifest.py`), and it was on T5 FX1.
3. The firmware's PCM-pool block — `0x800` = 2048 samples for mono 24-bit in
   the recorder's block table at `0x80003c20` (`RTOS_FORK.md` §10.16), i.e.
   possibly not our code at all.

Ruled out on this capture: BusDelay's GRAIN grain-size table (its idx 0 is
G = 2048, and its own source warns a head past the bound gives "a full-scale
discontinuity once per grain") — the stored page 2 on T1 is MODE 0 = CLEAN,
SIZE 1 = 93 ms, so that code never runs.

**Ruled out, 13 Sep 2026, all measured.**
- **Not the capture rig** — the +24 ppm grid offset (above).
- **Not Character.** Removing Character from every track cleared the tick AND
  dropped the floor 28 dB — but Character on T8 is the one-aux RETURN
  (`SAT=BUS`, `RET 127`), with `DRV 0`/`FOLD 0`/`RING 0`/`SRR OFF`, so
  removing it removed the whole wet bus's only path to the outputs. It was
  never a source. This also explains why muting T5 never silenced the reverb:
  with the return up the reverb leaves T5 by design and enters at T8.
- **Not in the stored project.** A stock project measured -103.0 dBFS with
  zero events; the rig project RELOADED from the card measured -104.6 with
  zero events, against -73.9 and 23 ticks before the reload. The tick needs a
  LIVE edit that the card does not hold.
- **Not the input path.** Nothing is plugged into the inputs (Rytm on T1,
  synths on T2, both disconnected), and unmuting T2 moved the floor 3.3 dB.
  The -73.9 dB idle floor was therefore generated inside the DSP.
- **Not BusVerb page 1.** Every page-1 knob to extremes over verified CCs
  (AUX/TIME/MOD/SIZE/TONE/MIX at 127, then TONE 0): floor unchanged at
  -101.4, zero ticks.
- **Page 2 is UNTESTED, not cleared** — see the CC PAGE 2 entry: the sweep
  that reported it clean was run over CCs that never landed.

**Falsifier / next step.** The tick has not reappeared since the reload, so
the live state that produced it is lost; recovering it means reconstructing
what was changed by hand, or fixing CC PAGE 2 and sweeping page 2 properly.
⚠️ When bisecting by hand, take slots to a **stock effect, not NONE** — NONE
is id 0, which is SEND (see below), so "off" is not nothing.

**Instrument note.** `tools/hw/rec` must be the HAL recorder (PR #224); the
AVAudioEngine version silently captured zero frames whenever a Bluetooth
device was the system default input.

---

## Sequencer stuck on step 1 with EVERY effect turned off — id 0 IS SEND

**Symptom (measured, 13 Sep 2026, the first rig-burn image 85B).** Step 1
solid on play; still solid with every FX1 set to NONE and every FX2 set to
SEND, on a freshly stamped project and on a project that ran on flash 7.
The plain image (same DSP code minus the burn block) played.

**Cause.** Id 0 is aliased to SEND, and the FX1 chooser's NONE is id 0, so
**SEND's proc runs on every FX1 slot set to NONE** — with r6 on that slot's
page, whose bytes are whatever the last effect left there. The burn knob
read a stale slot-1 byte on four extra slots per core and burned the core to
a standstill. "Everything off" is not nothing: it is eight SENDs. The
emulator never instantiates an FX1-NONE slot, so no local render can show
this family.

**Fix.** Anything in SEND that reads a knob and can cost cycles or write
the bus must gate on the slot being FX2 (`X:$213` base ≥ 0x4000, tested
per call — an alias instance never ran init). The burn does now
(`dsp/burn_send.inc`, `verify_burn.py` check 5). ⚠️ SEND's AUX read has no
such gate: whether an FX1-NONE slot with a stale AUX byte registers as a
phantom sender on the unit is an OPEN hardware claim for the pass.

---

## Line-F exception on [PROJ] — a cave pinned in OS .bss

**Symptom.** The OS runs, but hitting **PROJECT throws an exception** and
wedges (recover via the Startup Menu, below).

**Cause (measured, 4 Sep 2026, tag 91).** A ColdFire cave was pinned at
`0x40108800`, inside the OS image's last ~30 KB — a zero run **at rest** that
is really uninitialised OS data (the PROJECT subsystem's RAM). Our cave and
the project collided the instant PROJECT ran. A static zero-check and a
no-project emulator boot both passed; `.bss` was mistaken for free padding.

**Fix / prevention.** `build_bus.SAFE_CAVE_CEIL` (0x400d8000) now refuses any
cave above the decoded free region. Caves belong in `0x400d2000..0x400d8000`.

---

## Garbled / wrong audio straight after an OS upgrade — WARM-UP TAG

**Symptom.** Right after OS UPGRADE, audio is garbled or wrong (worse for the
delay, which recirculates it). Not present after a reboot.

**Cause (inferred, matches the symptom; `docs/remixer/FLASHING.md` §3a).** An OS
upgrade rewrites program memory but does NOT clear DSP state RAM. An engine
skips warm-up when its tagged counter holds a valid tag at full count
(BusVerb `$2c0000` at `r7+$82`, BusDelay `$2e0000`, Nimbus `$2d0000`), so it
runs on the previous firmware's buffer contents.

**Fix.** **Power-cycle after every upgrade, before judging anything.** Clears
the tag, warm-up runs, buffers zero. Judge no defect until you have rebooted.

---

## Self-oscillating squeal — a page-2 value out of range, or deep overrun

**Symptom.** A rising/holding squeal.

**Cause.** Two measured sources: (1) a wild page-2 value — e.g. BusVerb DIFF
stamped to 127 self-oscillates the tank (the +0x325/+0x331 stamp-offset bug,
4 Sep 2026 — this is ALSO what flash 4's "the stock DELAY wedges the unit on
part load" was: T4's DELAY row landed on T5's BusVerb; the stock DELAY costs
the DSP nothing and is innocent); (2) **deep cycle overrun** — the
"high-pitch squeal" is the deep-overrun signature (`docs/firmware/CHIP.md`:
p3=23 × 32 breakup, 23 Aug 2026).

**Fix.** Re-stamp the project (1); fit the layout (2).

---

## "Z" screen / won't boot — corrupt OS

**Symptom.** A "Z" screen, or the unit will not boot.

**Cause.** The OS flash was interrupted or corrupted.

**Fix (never fails — the bootloader is untouched by an OS update).** Startup
Menu recovery: power off; hold **[FUNC]**, power on → Startup Menu → **[TRIG
3]** MIDI UPGRADE → send a good `.syx` (`make midi-flash PORT=A SYX=...`, or a
SysEx app). Factory rescue: `downloads/extracted/OCTATRACK_OS1.40C.syx`.
`docs/remixer/FLASHING.md` §1. Recovered from the tag-91 crash this way, 5 Sep 2026.

---

## Cross-core bus glitch — the accumulators' race 🟡 → ✅ MECHANISM MEASURED under the port, 9 Sep 2026: core 0's housekeeping flips the rotation word in the middle of core 1's frame and every client reads the word directly, so a frame's sends split across two buffers; the reverb (the cross-core reader) gets them a block late/split. `COLDFIRE_PORT.md` O12. ✅ FIXED 9 Sep 2026 (branch `bus-private-rotation`, UNFLASHED): one rotation tracker per core (`build_bus.py` ROTLATCH, payload B), every core-1 client resolves the same buffer per frame under the port; verify-onebus and make check green.

**Symptom.** A tear, stutter or hash on wet audio that crosses cores; often
smeared into a reverb tail so it is hard to localise.

**Cause (measured, 17 Aug 2026, three defects found + fixed through R26; one
residual on T4 + delay MODE 1).** The shared-window accumulators raced across
the two cores. `docs/effects/XBUS.md`.

**Fix.** The shipped fixes (four ACC buffers, per-core rotation tracking).
⚠️ **No local test is evidence here** — `dsp_host` runs both cores only
lock-step or under a guessed interleave (`-skew`), so a bus race that fails
to reproduce locally is not shown absent. A local mismatch under skew IS a
defect. Believe the hardware.

## CONTROL menu shows its stock six rows though the image carries eight 🔴

**Symptom.** MAIN MENU › CONTROL lists AUDIO … PERSONALIZE exactly as stock;
the REVERB / DELAY rows a module appended (modules/busscreen, also
modules/menushortcut's mechanism) are not there. Everything else in the
image works.

**Seen.** Tag 16, 6 Sep 2026. The image was checked afterwards: row count
at 0x400cbd54 = 8, the row pointer at +0x18 repointed to the relocated rows,
both labels present. The bytes are right; the firmware is not reading them.

**Cause.** Unknown (inferred: the CONTROL rows are copied or built elsewhere
-- a RAM copy at boot, a second descriptor, or the menu code takes its count
from another table). Not diagnosed.

**Fix.** None yet. BUS SCREEN is out of the rig (tag 17). Before any flash
that appends CONTROL rows again: navigate to CONTROL in the ColdFire
emulator's own menu and count rows; if it shows six there too, the emulator
can find where the count really comes from. Flash 4 (tag 79, MENU SHORTCUT)
used the same patch -- whether its rows appeared was never recorded.

## The one-aux return never reaches T8: the hosts keep printing their own wet 🔴

**Symptom.** With the one-aux rig on the unit, sending `AUX` from a track
produces wet — but it comes out of **T1 and T5, the engines' own host
tracks**. Muting T1 and T5 removes all wet. Nothing arrives at T8, the
pinned return. Turning the return knob down does silence the wet.

**Seen.** ✅ Flash 6, tag 20, 7 Sep 2026, reported from the unit. Claim ii of
the Flash 6 table ("T2 sends AUX: repeats AND reverb arrive on T8 with
nothing on T1/T5's own outputs"). Claims i (the re-slot) and iv (MIX) passed
in the same session.

**Cause.** 🟡 **INFERRED, not measured.** The symptom is the third falsifier
the claim itself names — *"the hosts still printing (RETV/RETD)"* — i.e. the
return-live stamp is not reaching the engines, so neither host goes quiet and
the return publishes nothing. The stamp has to cross cores here: the return
is a BUS-mode Character pinned to **T8 = payload A / core 0**, while the
delay host sits on **T1 = payload B / core 1**. Nothing has been measured on
the unit to distinguish a lost stamp from a return that never publishes.

✅ **CAUSE MEASURED 8 Sep 2026, under the ColdFire port (`COLDFIRE_PORT.md`
O11), and it is not a cross-core race:** the station pins the return to
track 8 by testing `r7 & 0xff00` against `$6700/$6800`, the harness's
two-per-track model of the dispatcher's state block. The stock dispatcher
bumps its r7 counter THREE times per track (FX1, FX2, and an unconditional
third at P:0x51e), so on the unit track 8's FX1 runs with **r7 = $6a00**,
the pin never matches, `ch_nopos` clears the RET level, the station stamps
nothing, and both hosts keep printing — exactly the symptom, reproduced
with the firmware driving both cores. Fixed: pin `$6a00/$6b00`; the
harness's r7 model corrected (rig_render, verify_onebus, send_probe,
dsp_host's comment); under the port the fixed image returns on T8 with both
hosts silent for 2,000 frames. UNFLASHED. The reading below stands as the
history of the wrong guess.

**⚠️ THE LOCAL GATE IS GREEN ON EXACTLY THIS.** `tools/verify/verify_onebus.py`
asserts "T5 (reverb host) prints nothing while the return is live" and the
same for T1, and both pass — the property hardware falsifies is the property
the gate checks. That is the standing rule in force, not a surprise:
`dsp_host` boots both payloads but runs them in lock-step, so a cross-core
timing defect cannot appear locally. **Believe the hardware.**

**Fix.** None yet, and per the Flash 6 stop condition the next step is
measurement, not code: *"any of ii–iv failing on the unit after passing
`make verify-onebus` locally is a cross-core timing fact — record the exact
configuration (which core, which position) before touching code."* What is
worth having before the next flash: which track the send came from, whether
a send from a **core 0** track (T6/T7) behaves differently from a **core 1**
one (T2–T4), and whether the return is dead or merely intermittent (the
free lever from `docs/effects/XBUS.md` is to change what sits on track 5).


## The port reports a wrong bank/pattern at play for an image that detours `0x40087d44` — the INSTRUMENT, not the firmware (13 Sep 2026)

**Symptom.** Under `ot_emu --sequencer`, an image that hooks the engine's
BANK= store at `0x40087d44` (midisc's Site B) plays bank 0 pattern 0 after
LOAD PROJECT, whatever bank the project was saved on: `saved_bank: -1` in
the load report, "playing bank 0 pattern 0", and a step-1 trig set that is
the default position's (tracks 0, 5, 7 on `dram_card.img`/`OCTABAM`/`RIG`)
instead of the saved one's (0, 1, 2, 4, 7). Stock and any image that leaves
the site alone play the saved bank.

**Cause.** `rtos.cpp` learns the saved bank from a write watch on
`BANK_PTR` (`0x46c82456`) that accepts only writes whose PC is the stock
store at `0x40087d44` — deliberately, to tell the engine's parse from
`sys`'s select-bank writer. A detour moves that store into a cave, the
watch never fires, and the port's own transport-start re-select (which
compensates for an emulator ordering defect) picks bank 0. Nothing in the
firmware did anything wrong.

**Cost.** Three sessions (10–12 Sep 2026): a 38-site bisect that "landed"
on this one site, a re-bisect that "narrowed it to `unpack`", an inferred
mechanism sent to the author, and a PR to his repository (bkkbrls-del/
midisc#2, withdrawn). Every step was internally consistent because every
step ran the same blind instrument. The tell that was missed: dropping the
site restored the control, but so would ANY change to the writing PC — and
"Site B as a cave holding only stock's store" (→ 3) was the one-line
experiment that separated the site from what it ran.

**Fix.** The watch follows a `jsr (abs).l` at the site and accepts the store
from the detour's own code (`rtos.cpp`, branch `port-bankwatch-detour`).
`--bank N` overrides for anything else. **Rule:** a port watch keyed on a
stock PC is blind to any module that detours that PC; when a "defect"
bisects to exactly one hook site and survives emptying the hook, suspect
the instrument's PC keys before the firmware.
