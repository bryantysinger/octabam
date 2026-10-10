# `lofi2` -- LOFI2

One modulator, ring mod or a stereo frequency shifter, followed by stock LO-FI's sample-rate and bit reduction and a high-shelf cut.

An insert on a free id (`0x1f`; `0x1e` until the October port), so it displaces no stock effect: stock LO-FI stays in the chooser beside it. Signal chain: `dry -> modulator -> MIX -> SRR -> BRR -> LPF -> out`. MIX is the modulator's depth, not a global wet/dry: SRR and BRR run after it and stay live at MIX 0, as they do in stock LO-FI. The defaults are a passthrough (MIX, FREQ, FDBK, SRR, BRR, AMPH at 0, LPF at 127).

How it differs from CHARACTER, which replaces stock LO-FI and also crushes and ring-modulates: LOFI2 is built around the modulator. It adds a frequency shifter, gives the ring mod an MF-102-style exponential FREQ with a LOW/HIGH range and LO-FI's L/R phase offset, and keeps stock LO-FI's own SRR and BRR curves (ported, not reinvented) so measurements and note tables made against stock LO-FI still apply. CHARACTER is a channel-strip chain (crush, fold, saturation, compression, width).

## Knobs

| page | slot | name | range | what it does |
|---|---|---|---|---|
| 1 | 0 | FREQ | 0-127 | modulator frequency, exponential over six octaves from RANGE's base; read by whichever MODE is selected |
| 1 | 1 | MIX | 0-127 | modulator depth: crossfades the ring or shift output against the dry |
| 1 | 2 | FDBK | 0-127 | shifter feedback (the f, f+d, f+2d ladder), capped at 0.45; does nothing in RING |
| 1 | 3 | SRR | 0-127 | sample-rate reduction, stock LO-FI's fractional hold: 44,100 Hz at 0 down to 1,782 Hz at 127 |
| 1 | 4 | BRR | 0-127 | bit-depth reduction, stock LO-FI's continuous round-to-nearest quantiser |
| 1 | 5 | LPF | 0-127 | high-shelf cut, stock EQUALIZER's HIGH shelf at a fixed -32; 127 does nothing, turning down darkens |
| 2 | 6 | RANGE | LOW / HIGH | FREQ's base: RING 2 Hz / 60 Hz (MF-102), SHIFT 2 Hz / 31.25 Hz (Bode 1630, six octaves to 2 kHz) |
| 2 | 8 | MODE | RING / DOWN / UP | ring mod, or the shifter moving every partial down or up; mutually exclusive |
| 2 | 10 | AMPH | 0-127 | ring carrier's L/R phase offset, 0 to ~360 degrees; RING only |

## Design

- **Ring mod** is not stock's: WarpFold's parabolic carrier `4p(1-|p|)` under an exponential six-octave taper (the MF-102's ranges, 2-130 Hz and 60-4,000 Hz, are each exactly six octaves). An exponential taper has no zero: FREQ 0 is the base frequency, not silence.
- **The shifter is stereo**: two Hilbert allpass pairs (BodeShift's eight coefficients) sharing one oscillator, rather than BodeShift's analytic pair on the mono sum, which would collapse the image at MIX 127. Direction is a per-block sign on Q, so UP/DOWN costs no branch in the loop. The chains are pointer-walked, which lets each section carry parallel moves (12 words a section against 21 with displaced addressing).
- **SRR** is stock's hold from `P:0x01c56` / `func_001cba` and **BRR** stock's quantiser from `P:0x01c84` / `func_001cac` and the table at `X:0x7400`, read out of `payload_A.asm`. Stock's quantiser carries a structural x0.5 that stock's surrounding pipeline makes up; LOFI2 restores it with one extra shift (`asl #$18` where stock stores off `#$17`).
- **LPF** is stock EQUALIZER's HIGH shelf (`func_000bfa` coefficients, `func_000cb9` filter) with GN fixed. Its four curve-bank reads are declared in `DspSection.xtables`, so the build rewrites them for payload B (`docs/firmware/TABLES.md` "Payload-relative addresses"). The coefficient glides to its target once a sample (`c += (target - c)/256`).
- `init` zeroes the whole instance block (`$00..$83`).

## Status

- Flashed and heard on Bryan T's MKII in September 2026, built on the tree of 12 Sep 2026.
- Ported to this tree in October 2026. Three changes the port required:
  - the shifter's chain pointer was `lua (r7+$40)`, which assembles to `r7-$40` (`lua` takes a displacement of -64..63; AGENTS.md). All four Hilbert chains had been reading and writing the 64 words below the instance's own block. This tree's build refuses it (the disassemble-what-you-assemble round-trip); the pointer is now `r7 + n1`. SHIFT is expected to sound different from the September images; RING is not.
  - every page-1 knob read is masked with `and #>$7f0000` (an LFO-modulated knob word carries bits 8-15; AGENTS.md).
  - `init` zeroes the block (verify_dirtystate), where it had been a bare `rts`.
- This port has not been flashed.

## Open

- Turning BRR off 0 clicks; stock does not. Suspected cause: coefficients that snap per block rather than glide (the LPF clicked the same way until its smoother).
- Whether the LPF smoother cured the LPF's click on the unit was never recorded.
- The MODE labels (`RING` / `DOWN` / `UP`) are built but not confirmed on the unit through all three positions.
- Ring mod's level against the dry has not been measured.
- Tuning by ear: whether six exponential octaves suit the knob, and the SHIFT range pair.

## Gates

- `make check REMIX=lofi2`.
