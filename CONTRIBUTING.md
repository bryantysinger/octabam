# Contributing

The contract a module signs, the rule every port lives by, and the
etiquette for building from somebody else's repository.

## The one rule

**Never an Elektron byte.** Not an OS image, not a `.syx`, not a slice of
either, not in a commit and not attached to an issue or PR. Describe it,
hash it, or name the commit that built it. Anything a module needs from
the stock firmware is taken from the user's copy at build time (Octakit
`.incbin`s 411 stock routines that way). `.gitignore` refuses `*.bin`,
`*.syx`, `downloads/` and `out/`.

What the rule does not cover (decided 16 Sep 2026): the few displaced
instructions at a cave's hook site. A `CfPatch.hook_stock` is the six to
ten bytes the installer overwrites with its `jsr` and the cave replays; the
build refuses an image that does not hold them, which is the check that
keeps a cave off the wrong OS. Those opcodes (four sites, 30 bytes in all,
across `tempo-sync`, `recorder-spacing`, `flex-seekbind*`) are an
instruction, not a firmware, and every ColdFire module carries its own
the same way. Keep a hook to whole instructions and the minimum span; data
tables, routines and anything longer than the displaced instructions come
from the user's image at build time.

## Your first pull request

1. Fork `sambanks/octabam` on GitHub and clone your fork with its
   submodules:

   ```bash
   git clone --recurse-submodules https://github.com/<you>/octabam
   cd octabam
   git remote add upstream https://github.com/sambanks/octabam
   ```

2. `make setup` builds the toolchain: dsp56300 at its pin with our patch,
   the ColdFire core, `elektron-firmware-tool` (`scripts/vendor.sh` holds
   the pins). macOS with Homebrew; `docs/WSL.md` for Linux.
3. `make os && make recon` turns **your own** copy of OS 1.40C into
   `out/raw/section_3_MAIN_OS.bin`. Every build and most gates read it;
   it never leaves your machine.
4. Branch from `upstream/main`, write the module (next section), and run
   the gates in [Before you open a PR](#before-you-open-a-pr).
5. Open the PR against `sambanks/octabam:main`. The template asks for the
   gates you ran and what was measured. CI runs on it; GitHub holds a
   first-time contributor's first CI run until a maintainer approves it.

Issues are turned off (`README.md`): a question about your change goes in
its PR.

## A module

One directory, `modules/<name>/`:

```
manifest.py     declares the module -- exports MODULE (tools/remix/schema.py is the vocabulary)
README.md       what it is, what was MEASURED, what is INFERRED, what is open
<sources>       .s for the ColdFire, .asm for the DSP -- or `upstream/`, a submodule
```

plus a remix that carries it (`remixes/<name>.py`) and, for anything with
behaviour worth pinning, a gate (`tools/verify/verify_<name>.py`, added to
`make verify`). Nothing else registers it: the registry discovers every
`modules/*/manifest.py`, and refuses two modules on one key or one FX2 id.

Two skeletons and two worked examples:

| you are writing | copy | then read |
|---|---|---|
| a ColdFire modification (parts, kits, menus, MIDI, fixes) | `modules/_template_cf/` | `modules/hello-dram/` (one DRAM unit, no hooks), then `modules/midi-scenes/` (a real one, built from its author's repo) |
| a DSP effect | `modules/_template/` | `modules/hello/` (one knob, 27 words, its own render gate) |

`docs/remixer/MODULES.md` is the full guide; `docs/remixer/PLACEMENT.md` says
where the bytes land and how much room there is.

**Declare what it is, not where it goes.** A ColdFire module is `Linked`
units (GNU-as, symbols, no absolute addresses of its own) reached by
`Detour`s that name those symbols, plus `Poke`s and `TableGrow`s for the
OS-image edits — each asserted against stock before anything is written.
`dram=True` is the default place for code: a 10 MB reserve carved off the
unit's sample/recorder pool, placed by the build, the way midisc and
Octakit live (`docs/remixer/PLACEMENT.md`). The ~8 KB of free ROM
inside the OS image is for what must be ROM-resident, and it is shared
with everyone. A module that keeps its own DRAM (a `Runtime`) declares
the pages it takes with `ArenaReserve`, and the build composes everyone's.

**`key` is API.** It appears in the build report, and tools parse the
report. Renaming a key, or rewording a report line, is a breaking change.

## The oracle rule

**A port is done when the author's build and this repo's build agree byte for byte.**
The form depends on the module:

| the module carries | the oracle |
|---|---|
| ratified hex (`CavePatch.pinned`) with a `.s` | the build assembles and links the source at its resolved address and refuses if the bytes differ |
| a floating source-linked cave | `reference(addr)` — the ratified bytes *at that address*, checked every build |
| `Linked` units | `reference=(addr, sha256)`: the unit re-linked at the author's own address, compared every build |
| a `Runtime` recipe | every identity the recipe pins — rebuilt runtime, packed runtime, append — re-derived and compared |

`tools/verify/verify_midiscenes.py` and `verify_octakit.py` are the two
standing proofs; write the equivalent for yours. When you port someone
else's mod, run their build against the shared stock image first and use
its output as the oracle.

## Building from an author's repository

The preferred shape for a module that has a repository of its own,
because the author keeps developing where they are:

- The repo is a git submodule at `modules/<name>/upstream`, **pinned to a
  commit**; a branch is named in `.gitmodules` when the port lives on one.
  `git submodule update --init` fetches it.
- **Nothing inside `upstream/` is edited here.** A change the port needs
  goes to the author as a PR (or, with their agreement, to a fork branch
  that will become one — midi-scenes's `octabam-gas` is the pattern). A
  bump is a commit here that moves the pin, with the oracle still holding.
- The author's repo stays under its own terms. Nothing from it is
  vendored or relicensed; octabam's MIT covers octabam.
- What makes a repo easy to build from: GNU-as sources (or a recipe the
  build can drive), symbols rather than absolute addresses for anything
  the build might place, an artifact of the author's own build to prove
  against, and no Elektron bytes.

## Gates

**`make check REMIX=<name>` is the floor**, for every remix you touched. It
builds, prices cycles, runs the ledger selftest, the menu verification,
the oracles and — for any remix with DRAM code — boots the image under the
ColdFire port and reads each window back against the linked image. Never
claim something works because it assembled.

For acceptance evidence, use `make accept REMIX=<name> OT_PROJECT=<dir>`.
Unlike the development check, this refuses missing evidence and writes a
versioned JSON report. The initial pressure profile covers the bamsep26
DSP selection; unsupported DSP selections are blocked, never silently
approved. See [the acceptance contract](docs/remixer/ACCEPTANCE.md) for
generated fixtures, report fields, coverage and hardware limitations.

**If you changed the build rather than a module, prove it changed
nothing**: `scripts/refhash.sh save` on a tree you trust, then
`scripts/refhash.sh check` — 26 configurations, artifacts *and* build
reports, bit-identical. Every step of the DRAM platform landed under it.

**Say what was measured and what was inferred**, in the README, with what
would falsify each claim; retract in every document that repeated a
number, not just the one you are editing.

**Flashing is the author's own step, on their own unit**, and it is
expensive: bump `BUILD` so the unit's version string maps to a commit,
stamp projects after any parameter-layout change (`tools/hw/ot_project.py
stamp-defaults`), read `docs/remixer/FLASHING.md` first, and record
anything that goes wrong in `docs/remixer/FAILURE_MODES.md` the moment it
is seen.

## Before you open a PR

Rebase onto current main, then run the gates on the rebased tree. Gates
run before the rebase are not a result: a branch that merges without a
conflict can still fail on main (PR #396's stress fixture named a knob
that #415 had renamed).

```bash
git fetch upstream && git rebase upstream/main
make check REMIX=<name>              # every remix the change can reach
make test-acceptance                 # firmware-free, seconds
make accept REMIX=bamsep26 STRESS_SOURCE=<a local project>
make accept REMIX=<name> OT_PROJECT=<project>   # any other remix the change reaches
scripts/refhash.sh check             # the change touches the build (save the baseline on main first)
make ci                              # optional: exactly what CI runs
```

A remix whose DSP selection has no pressure profile makes `make accept`
report `blocked`; name it in the PR. List each command and its result in
the PR body.

## What CI checks

`.github/workflows/ci.yml` runs on every PR, on `main` and by hand
(Actions → CI → Run workflow), on Ubuntu and macOS. It has no Elektron
bytes, so it checks only what needs none:

| job | make target | what it proves |
|---|---|---|
| acceptance runner tests | `make test-acceptance` | `make accept` refuses skipped, failed, incomplete and over-budget evidence |
| dsp56300 + our patch | `make ci-dsp` | the vendored DSP emulator at its pin takes `tools/patches/dsp56300.patch`, builds, passes upstream's own test runner, and `dsp_asm` emits the one-word displaced move (`make check-asm`) |
| ColdFire port unit tests | `make ci-emu` | `tools/emu/ot_emu` builds against the pinned cores and passes the EMAC, peripheral and mc68k unit tests |

The port's `rtos`, `dsp` and `repitch` tests read the stock OS and are
excluded from CI by name. **A green CI run says nothing about a
remix**: building, booting and playing one needs 1.40C, which is why the
gates above run on your machine. Actions are pinned to commit SHAs (the
repository requires it); a bump is a PR that changes the SHA and the
version comment beside it.

## Etiquette

- Read the traps in `AGENTS.md` before trusting an assembler, an
  emulator, or a null result.
- Collisions are refused by name; `make modules` prints the matrix. If
  your module cannot share an image with another, say so in its README
  and say why (a shared hook site, a shared data structure).
- Keep the report text stable, keep `priority` stable (it is
  byte-load-bearing), keep `key` stable.
- A PR that touches a submodule pin says which upstream commit and why.
