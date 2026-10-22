# `cxosc` — CX OSC

Buchla-flavoured **complex oscillator** as a machine-list machine (sibling to
SYNTH MACHINE). Local fork of Tim Hastie's FM SYNTH ColdFire engine; not an
edit of the `modules/synth` submodule. Provenance: `NOTICE`, `LICENSE-TIM`,
and the `THIRD_PARTY.md` row.

## Select

**FUNC + SRC** or **SELECT MACHINE TYPE** → **CX OSC** (sixth row). No marker
file. Stored as FLEX with Part signature `"CX", 1`. At most **one CX OSC track
per Part** (`ml_guard` / `ML_FM_MAX 1`) — so **one track can sound** as CX OSC
at a time on the active Part. A second choice (machine window, SRC SETUP,
track/Part paste) shows **CX OSC: 1 MAX**. `verify_cxosc` exercises the
refusal under Unicorn.

## Provenance

| File | Upstream pin |
|------|----------------|
| `poly.s` | timhastie/octatrick-modules **v2.9** `525f4b1` |
| `page.s`, `machine.s` | **v2.15** `17ba281` (`machine.s` via Modwerk FM Synth `1c1d938`) |

CX-specific: marker-less list row, FOLD + SYMM waveshape, free/snap RATO,
harder FDBK, mono + stock LFOs (no VOIC/CHRD).

## PLAYBACK

| Slot | Name | Role |
|------|------|------|
| A | PTCH | Semitones (−64..+63) |
| B | RATO | Mod:carrier ratio (free 0.25..4; FUNC snaps classic table ≤4.01) |
| C | INDX | FM index (holds; LFO/plock for motion) |
| D | FOLD | Sine waveshape fold (dry/wet; moderate drive) |
| E | SYMM | Fold symmetry (DC bias into the fold; 0 = centered) |
| F | FDBK | Modulator feedback (up to ~1 cycle at 127) |

Mono only. Stock LFO page (all three LFOs). No VOIC/CHRD.

## Cost

Unicorn executed instructions for one mono CX OSC track (`tools/verify/verify_cxosc.py`,
`sy_render`, base knobs; pitch curve stubbed — EMAC): **~1290 instructions/frame**
(~81/sample), peak ~1293. Not hardware cycles. One track per Part by the
selection guard; how that sits against ColdFire headroom on a loaded Part is
**unmeasured** on the chip (same caveat as SYNTH MACHINE's lockstep figures).

## Conflicts

**SYNTH MACHINE**, **ANALOG BD**, **BLACKPYRAMIDS_303** (shared ROM hooks such
as MIDI note-on `0x4000e746`). The build refuses the pair.

## PLACE

Setting `ilia.cxosc` / `PLACE` (Apply.BUILD, default **DRAM**): the PLAYBACK
page lives in the platform runtime with `poly.s`, and the resolver at
`0x40031ece` is a detour to `pg_resolve`. That leaves the stock DELAY curve
table tail at `0x400d24d0` alone (issue #771). **CAVE** is the pinned ROM
form at that address; the ledger refuses it in a remix that lists DELAY.

## Proof / hardware

**Port:** `make check REMIX=cxosc` runs `verify_cxosc` (FOLD/SYMM/RATO/FDBK
change the waveform; FOLD=SYMM=FDBK=127 stays off the rails).

**Hardware (author MKII):** image **BUILD CS**, commit **`052bb14d`**
(`cxosc-core`). Tried and OK: machine select; each PLAYBACK knob (PTCH, RATO,
INDX, FOLD, SYMM, FDBK); FUNC snaps on RATO; MIDI note-on; STOP/START; Part
change.

## Build

```bash
make check REMIX=cxosc
```
