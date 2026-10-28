# `sidechain-compressor` -- SIDECHAIN_COMPRESSOR

Stock COMPRESSOR with a side-chain KEY from any of T1-T8 and a base-width key filter. Page 2 adds MON (hear the processed key instead), KEY (OFF or T1-T8), KGN (the key's gain, about -24..+24 dB), KBAS (the key's high-pass, 18 dB/oct: OFF, 20 Hz-19.6 kHz, shown in Hz) and KWID (the key's low-pass, 12 dB/oct, this many octaves above KBAS: 0.5-9.9 or OFF, shown in octaves; with KBAS OFF a plain low-pass from 20 Hz), beside stock's RMS. The filter isolates the key (a kick's fundamental without its sub-sonic rumble, say), which reduces distortion and keeps the compression smooth at short attack and release settings.

Built from [Zac-Kyoti/octatrack-kyoti-fw](https://github.com/Zac-Kyoti/octatrack-kyoti-fw)
(submodule `upstream/`, pinned to `6c9180d` on the [sambanks fork](https://github.com/sambanks/octatrack-kyoti-fw) until [Zac-Kyoti/octatrack-kyoti-fw#4](https://github.com/Zac-Kyoti/octatrack-kyoti-fw/pull/4), the opt-in `FORM = SHARED` octabam uses, is merged upstream). `Kind.DSP_EFFECT` with `MenuEntry(replaces="COMPRESSOR", stock_dsp=True)`: the row is COMPRESSOR's and its dispatch entry stays stock's. Two linked units, in a ROM cave or DRAM by the `PLACE` setting (default CAVE): `patch_sidechain.s` (698 B: MON's and KEY's step handlers, MON's switch, the MON, KEY, KBAS and KWID formatters and `sc_norm`, reached by two `jsr` detours at the first instruction of both page-2 copiers, `0x4000cae8` and its twin `0x40003d1c`) and `ui_switch.s` (616 B, shared with VARISPEED: KEY's widget, a 9-position rotary switch like Spectrum's LADR knob in 22.5-degree steps, and KWID's, the stock knob with the link clip to KBAS, which the FX SETUP window does not draw itself); page-2 slots 7-11 as raw descriptor words; four per-payload `DspHook`s (`sctap`, `scdet`, `moncommit`, and `scinit` on COMPRESSOR's init, which resets the key filters' state at r7+$1c..$2d); the per-core values as `DspSection.subst`; the 16 KEY GAIN words as the `ptable` and the 49 key-filter words as the `ptable2`.
`upstream/octabam-modules/sidechain-compressor/README.md` is the full description, with what was measured and what was inferred.

## Changed on 25 Oct 2026: the key-filter table, MON and KEY

- **Fixed:** in this octabam form KBAS and KWID read their coefficients from the wrong memory (the table base came from `lua (r1+$10),r1`, after the gain store had moved r1), which gave silence, level jumps and squeals on the author's MKI (OCTABAM31, `554ca1c`). The key-filter table is now the `ptable2`, loaded by its own literal as in the standalone image. The image differs from `554ca1c`'s in two DSP words per core.
- MON shows OFF on the left and ON on the right (it stores 2 / 3); a COMPRESSOR saved with any earlier version comes up with MON OFF.
- KEY moves one position per detent when the encoder is pressed and turned (stock's generic step handler moves 7).
- Switching MON, or changing KEY while MON is on, fades over 256 samples (64 before).

## Changed on 22 Oct 2026: the base-width key filter

This version replaces the previous one, whose page 2 was RMS · KEY · KFLT · KGN · MON with a one-knob key filter (KFLT, 6 dB/oct). The new filter isolates the key much better, but page 2 is laid out differently, so **a COMPRESSOR saved with the previous version sounds different** until its knobs are set again: it keeps its KEY; KGN gets the old KFLT value (set it back, 64 is unity), KBAS the old KGN (set the key's high-pass, OFF for none), KWID the old MON (set the key's low-pass, OFF for none), and MON (now slot 7) comes up OFF. A COMPRESSOR saved on stock firmware is not affected. The DSP section grows from 465 to 677 words (see Notes).

## Measured

- Every build re-links `sc_cf` and compares it with the author's own bytes (`reference`); a difference refuses the build.
- `upstream/tools/emu_sc_dsp3.py --layout octabam` (this manifest's addresses): the key filters bit-exact against `upstream/tools/sc_keyfilt.py`, the MON crossfade, the KEY hold, `scinit`.
- `make check REMIX=sidechain-compressor` (`remixes/test/sidechain-compressor/`) and `make check REMIX=kyoti-mute-sidechain` build and boot the image under the ColdFire port.
- DSP section 677 words (612 code, the 16-word `ptable` and the 49-word `ptable2`), in SPRING REV's words.
- `upstream/tools/emu_sc_dsp3.py --ftab-lua` replays the `554ca1c` table load: every key-filter case fails, as heard on the unit.

## On the unit

- 22 Oct 2026, on the author's MKI, in the author's standalone image (`140C_SCKF4`): page 2 and its readouts, a kick fundamental keyed at short attack and release, MON and KEY declick, the load with 1 + 7 and 4 + 4 COMPRESSOR / DJ EQ per core. The author's KYOTI V1.6 image (with MUTE_MODES' SC_KEY) ran on the unit the same day.
- 24 Oct 2026, this octabam form at `554ca1c` (OCTABAM31): ducking worked, KBAS and KWID broken (the table bug above). 25 Oct 2026, with the table fix (OCTABAM32): KBAS and KWID work.
- 25 Oct 2026, the author's standalone image `140C_SCKD3`: MON's new switch and its OFF on older projects, KEY's pressed turn, the longer fades.
- 26 Oct 2026, this pin's octabam form (`test/sidechain-compressor`, OCTABAM33): KBAS and KWID, MON's switch and its OFF on older projects, KEY's pressed turn and the fades, all good.

## Notes

- The bigger DSP section no longer fits beside EUCLID, SHATTER or TRANSIENT when a remix frees only SPRING REV, nor beside VOID when it frees SPRING REV and PLATE REV (a pairwise survey on `ff9c5f84`, against the previous version); all four fit with all three reverbs freed. No official remix carries this module.
- The keybus and MON words at core-private `Y:$7f0-$9ff`, and the cross-core window (the last `$202` words of each core's half of the shared window), so it is refused beside BusDelay, BusVerb and WAVE (a pairwise survey on `ff9c5f84`).
- For a composed caller, `scmonbody` uses a, b, x0, x1, y1, r1, n1 and r3.
