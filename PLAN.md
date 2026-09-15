# The plan

octabam is a remixer for the Octatrack's OS: a mod is a module, a remix is
a selection of modules, and the build turns a remix and the user's own
1.40C into one image. `docs/remixer/PLACEMENT.md` is the architecture record
for where code goes; `docs/history/PLAN_EFFECTS.md` is the DSP-effects
programme this grew out of, with its open items.

## Where it stands (15 Sep 2026)

- **On hardware:** `ok-ms` (Octakit ot-26914 + MIDI SCENES 1.40MIDISC8 on
  the stock effects), built as `OKMS1`, confirmed working by midisc's
  author on his unit: the appended loader, the arena reserve, her runtime
  relocated through our loader, his thirteen units in DRAM. Its first
  Part Reload trapped (VEC:04 in Octakit's caller check, D0 = midisc's
  `rel_after`; not a byte collision, a return-address ABI): `modules/
  kits-reload` bridges it, the ledger sees the class
  (`Runtime.pinned_returns` vs `Detour.subst_return`), reproduced and
  fixed under the port (`ot_emu --call`); `OKMS2` = `ok-ms` with the
  bridge, unflashed. The rig (`bamsep26`) is on Sam's unit. octalab (nordseele) is a DRAM module of
  this remixer and has run on an MKI since 11 Sep 2026.
- **Built and gated, unflashed:** every other remix (`docs/remixes/`).
- **The platform** (`tools/remix/`): `schema.Linked` (GNU-as units the build
  assembles and links where it places them; `dram=True` puts them in the
  platform runtime), `Detour` / `Poke` / `TableGrow` (the OS-image edits,
  wired by symbol, asserted against stock), `schema.Runtime` (a recipe-built
  DRAM runtime, Em's `firmware.json`), `Override` (a bridge's claim at a
  shared site), the loader (`loader.S`, derived from Em's, an N-payload
  table, hash-gated, depacked with the firmware's own aPLib), the arena
  reserve (10 MiB off the bottom of stock's 85.5 MB sample/recorder pool,
  every reservation stacked and the geometry computed once), the ledger
  (every claim, the compatibility matrix), and the ColdFire port
  (`tools/emu/ot_emu`) that boots every DRAM remix and reads each window
  back.
- **A real project under the port, before a flash:** `OT_PROJECT=<dir>
  [OT_BANK=n] make check REMIX=<name>` (`verify_set`, `docs/remixer/EMU.md`)
  loads the project with its samples on the built image, plays it with
  both DSP cores, drives it over MIDI IN, and asserts the ids, the page-2
  delivery, the chain audio, the aux return, the main out, the card as
  the firmware left it and the firmware's own LOG. 18 checks on
  OCTABAM88 bank B / `bamsep26`, ~80 s. It found the T1 page-2 defect's
  cause (the tempo cave over the FX1 page 2 of every bus host, PR #271)
  — fixed; image 24 (15 Sep 2026) confirmed the sends into the delay on
  the unit, image 26 (SEND on every track, the WET pedal chain, PR #277;
  a MODE turned on the panel re-defaults its knobs, PR #281) is what the
  rig runs now.

## The ground

From `docs/remixer/PLACEMENT.md`, measured under the port unless marked.

| where | how much | status |
|---|---|---|
| ROM: the OS image's free zero runs (`0x400c45b0`, `0x400d24d0`, `0x400d2ee6`, `0x400d64da`) | ~8.4 KB, shared by every ROM cave and the chooser clones | measured |
| RAM | 128 MB at `0x40000000`, decoded over a 256 MB chip select, so `0x48000000..0x4fffffff` is the same memory uncached | boot code + hardware |
| the audio page arena `0x40a955e0..0x46025de0` | 14,602 × 6,144 B = 85.56 MiB. Octakit takes the top 528 pages, octamax the bottom 64; the platform reserve is the bottom 1,707 | measured |
| the top window `0x47fc7410..0x47fe0000` | 101,360 B; Octakit's boot-time stage at the bottom. Not clean: the engine task's sector bounce buffers land at `0x47fc8fe4..0x47fcd9e4` at project load | measured on the port (PIO path); DMA-card path unexercised |
| the delay rings `0x47502c10..0x47fc7410` | 10.8 MB, eight rings, cleared at boot through the alias | static + port + hardware; not free |
| `0x46025de0..0x4763d580` | stock's globals and object pool, zero-filled at boot | static; not free |

## Open

1. The Kit write protocol: midisc's Part save/reload hooks against Octakit's
   LOAD/SAVE KIT menus are unmeasured; a write into a Kit goes through her
   six editing functions (`modules/octakit/README.md`).
2. Tell Em what the port saw at `0x47fc8fe4` (her boot-time stage is the one
   thing still in the top window).
3. Upstream: `tools/gas_port.py` + `gas/` to bkkbrls-del (merged as his
   PR #1); an optional tidy PR to Em splitting her loader infrastructure.
4. The remixer TUI shows ColdFire modules as rows with the matrix's verdicts.
5. Measure `0x46000000..0x47502c10` with samples loaded and the recorder
   running before anyone places there.
6. octamax (mxldyn): ported on branch `octamax-deferred` (`d952976`), parked
   pending a conversation with the author.
7. The DSP side's open items: `docs/history/PLAN_EFFECTS.md`.
8. The reverb is closed out (15 Sep 2026, "is awesome"; its buffers and
   voicing are kept whatever else moves). Next rounds: BusDelay with the
   32K lines (741 ms; 1/4 and 1/2T at 121 BPM) is image 28 on the unit,
   "sounds fantastic now" (a stored TIME byte means twice the time:
   `stamp-slot <project> busdelay 1 20` on any other project before play);
   then Modulation v2 (PR #258, never heard). Sam's
   fallback if the long delay disappoints: revisit the voicing and the
   alternative delay algorithms (BBD/tape loop saturation, resonant TONE,
   ducking; `docs/firmware/CHIP.md` "The rig's load" for the cycle room).
9. Under the port the transport start re-applies the saved bank's FX ids
   for T1-T3, T7 and T8 only (T4-T6 keep the load's bank A ids, by
   `--bank` or by a program change); `verify_set` stages the tested bank
   as bank A. Cause open.

## Gates and rules

- `make check REMIX=<name>` is the floor for every remix touched.
- A change to the build proves it changed nothing: `scripts/refhash.sh save`
  on a tree you trust, then `scripts/refhash.sh check` (26 configurations,
  artifacts and build reports).
- The author's build is the oracle: `pinned`, `reference(addr)`,
  `Linked.reference` and a `Runtime` recipe's identities are four forms of
  one rule.
- Measured beats inferred, and says which it is (confidence markers as in
  `docs/firmware/CHIP.md`; a retraction propagates to every document that
  repeated the number).
- Never an Elektron byte in the repo; `.incbin` from the user's stock image
  at build time.

## Build commands

```sh
make modules                  # the index, the compatibility matrix, the remixes
make image REMIX=ok-ms BUILD=1   # a card-flashable image, version-stamped
make check REMIX=ok-ms        # everything that can be checked without hardware
make remix                    # the TUI remixer
scripts/refhash.sh check      # after a change to the build itself
```
