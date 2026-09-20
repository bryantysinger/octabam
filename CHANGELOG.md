# Changelog

One entry per image that reached a unit, newest first; `Unreleased` is what
main carries beyond the last flashed image. The version the panel shows is
`BUILD` (`make image BUILD=N`); a git tag `OCTABAM<N>` marks the commit each
flashed image was built from.

## Unreleased (main after image 29)

- BusDelay: the tape wow is back and the freeze is gone (Sam, 20 Sep 2026:
  "wow back freeze gone"). WOW on page-2 slot 11 (the freeze's), one depth
  knob, 0 .. ±254 samples, wow 0.8 Hz + flutter 7.3 Hz at an eighth, fixed
  rate, on the loop tap in every mode through the glide's between-samples
  read; WOW 0 is bit-identical to the glide alone (`verify_delay`, every
  case, against image 33's source). The freeze hold, its crossfade, the
  `DFRZ`/`DFRZAT` build hooks and the refhash cases go; CC 67 is WOW. Delay
  1,362 -> 1,385 words. Stamp before play: slot 11 stored 0/1 reads as WOW
  0/1.
- BusDelay (image 33 defect): the glide's fraction slot was raw `$41`,
  inside GRAIN's line-L record (grain 0's window), so in GRAIN the loop tap
  read a window value as its fraction. Found by `verify_delay` when the
  fraction moved: image 33's source differed from itself-with-the-slot-moved
  only in the GRAIN 23 ms +12 case. The lag and fraction are per-sample
  slots `$2b/$2c` now.
- Character RET defaults to 127 and draws as `---` with no value on
  tracks 1-7 (Sam, 20 Sep 2026): a formatter cave
  (`modules/character/ret_fmt.s`) reads the current-track byte and writes
  the descriptor's name field (`RET` on T8, `---` elsewhere, Sam's ask after 35) before
  printing; the build exports every clone's address (`CLONE_<KEY>`) for a
  cave that writes its own descriptor. The DSP already clears the level off
  the master. `verify_labels` reads name and value back from the emulated
  firmware per track; the drawn page is not yet looked at under the port.
- Knob glides against the crackle on knob turns (Sam, 20 Sep 2026: TIME and
  FDBK on the delay brought it back on a clean project): BusDelay reads its
  tap between samples at the glide's fraction and glides FDBK/TONE/PING/WET
  per block; BusVerb glides SIZE (1/64 per block) and TONE/DIFF/SHMR/WET, and
  its init zeroes those slots. Image 33: the crackles gone (Sam, 20 Sep 2026).
- BusDelay: the TIME glide snaps onto its target once within one step. In
  image 33 a TIME increase stopped up to 4 samples short (the /1024 step
  rounds to zero), leaving the tap between samples at rest: a two-sample
  average on every pass round the loop, up to -10 dB at Nyquist per pass.
  Measured: state 600/256 samples below the target stayed there for 2,940
  blocks; with the snap both directions land exactly.
- BusVerb: +6 dB on the wet (WET 127 = ×2); BIG with eight senders at SEND 100
  peaks −8.9 dBFS on the wet alone.
- Modulation: MIX bottom right (page-1 slot 5), LOFI on slot 4 — the wet/dry
  knob sits bottom right on every effect (image 30, on the card).
- MODE top left (page-2 slot 6) on every effect, Character's SAT included;
  page 2 fills from the top left with no gaps: BusVerb `MODE TONE DIFF GATE`,
  Spectrum `MODE`, Character `SAT TONE WDTH`, Modulation `MODE TONE WDTH`.
  `stamp-defaults --all --keep-mode` before play.

## Image 29 — 16 Sep 2026 (`OCTABAM29`, bamsep26 at ed27afe)

On the unit: the link brackets draw, SHFT draws its words on page 1, the
`---` names draw. Before play: `stamp-defaults <project> bamsep26 --all
--keep-mode`.

- The knob pass (Sam, 16 Sep 2026): BusVerb p1 `SEND TIME⌐SIZE SHMR⌐SHFT WET`,
  p2 `MODE TONE DIFF — GATE —`; Character p1 `DRV FOLD TXTR COMP RET MIX`,
  p2 `TONE SAT — — WDTH —`; Modulation p1 `RATE⌐DPTH DLY FDBK MIX LOFI`,
  p2 `— MODE TONE WDTH — —`; links on BusDelay TIME⌐FDBK, SCAT⌐DENS,
  SIZE⌐PTCH and Spectrum FREQ⌐RES, LDP⌐LSP; BusDelay's SCAT/DENS read `---`
  outside GRAIN. `⌐` = the panel's link element (`Param(link=True)`, bit 1 of
  the enable nibble); first use by a module, and the first stepped select on a
  page 1 (SHFT). Renders bit-identical by knob name across the layouts.
  `stamp-defaults --all --keep-mode` before play.
- Modulation: ENS (the Solina) removed; MODE = JUNO DIM FLNG COMB PHSR; FLNG's
  view RATE 8; per-mode output trims (DIM −8, FLNG −7, PHSR −2, COMB −12 dB);
  a LOFI knob on page-2 slot 8 (the delay line clocked coarse and quantised).
  Stored MODE bytes 3..5 read one mode lower: `stamp-defaults` before play.
- BusDelay: the tape wow knobs removed (slots 7/8 are GRAIN's SCAT/DENS).
- BusVerb: MOD / RATE knobs removed, tank modulation pinned; SHMR on page-1
  slot 2 (`stamp-slot <project> busverb 2 0` before play).
- `make check`: the ColdFire-port gates no longer masked as SKIP; the module
  gates (character, spectrum, modulation, nimbus, hello) run; the set gates
  read `~/.octabam_project`; `make image` requires `BUILD=N`.

## Image 28 — 15 Sep 2026 (`OCTABAM28`, bamsep26 at 7b5da98)

- BusDelay: two 32K lines, TIME to 741 ms (1/4 and 1/2T at 121 BPM); a
  stored TIME byte means twice the time.
- Spectrum: TAME removed.
- MODE set over CC 62/68 re-defaults the mode's knobs, as the panel does.

## Images 25–27 — 15 Sep 2026

- 25: the bus engines are add-only pedals with WET knobs; SEND on every
  track; host print only while no return.
- 26: MODE DEFAULTS — a MODE turned on the panel re-defaults its knobs.
- 27: only the MODE select names itself (SIZE / FRZE / SHFT keep their names).

## Image 24 — 15 Sep 2026

- The tempo cave no longer clobbers an FX1 station's page 2 on a bus host
  (note-only cave; the DSP reads tempo from stock).

Earlier images (the 13 Sep 96–100 series, flash 7 = `OCTABAM21`, and before)
are in `docs/remixer/FAILURE_MODES.md`, the module READMEs and the git log
(`git show 3ceba41:docs/history/VOICING.md` for the ear rounds up to 16 Sep 2026).
