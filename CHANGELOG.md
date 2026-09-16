# Changelog

One entry per image that reached a unit, newest first; `Unreleased` is what
main carries beyond the last flashed image. The version the panel shows is
`BUILD` (`make image BUILD=N`); a git tag `OCTABAM<N>` marks the commit each
flashed image was built from.

## Unreleased (main after image 29)

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
