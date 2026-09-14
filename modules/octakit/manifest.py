"""OCTAKIT -- Em's Octakit: 256 Kits per Project in place of 64 bank-tied
Parts, built from her repository (emuyia/ems-octakit, submodule `upstream/`).

`upstream/runtime/firmware.json` is the recipe; the build compiles, links,
packs and appends her runtime itself (tools/remix/runtime_build.py),
re-deriving every identity the recipe pins and refusing on a mismatch.
Nothing of hers is vendored or rewritten; the 411 stock routines her runtime
carries are sliced out of the user's 1.40C at build time.

What it changes on the unit (her README): 64 Parts become 256 Kits
untethered from Banks (3.6 % of the flex pool); old Projects migrate their
Parts into the first 64 Kit slots on load, and downgrading may lose Kit
data; MKII PART = LOAD KIT, FUNC+PART = SAVE KIT (MKI FUNC+MIDI / FUNC+BANK);
FUNC+CUE reloads the assigned Kit; 7-character Kit names; copy/paste/clear/
undo in the LOAD/SAVE KIT menus; the splash animation is removed. This
module writes only the OS image; the migration is runtime behaviour.

Placement: her packed runtime is a payload of octabam's loader
(tools/remix/loader.S, derived from hers), staged at her own stage address
so her post-clear relocation finds it; her guarded sparse writes are kept;
her own append is replaced. Her runtime, Kit store and backup are the top
528 pages of the audio page arena, declared as an ArenaReserve so the build
stacks her pages with the platform's and computes the arena geometry once.

Measured: the runtime, packed runtime and append rebuild byte-identical to
her pinned identities with Homebrew m68k-elf-gcc 16.2.0 (recipe pins
16.1.0); tools/verify/verify_octakit.py reproduces her combined OS image from
stock + her writes + her append; under the ColdFire port her window reads
back byte-identical after boot. On hardware as OKMS1 (remix
ok-ms, her 92cf70b / ot-26914 + midisc 1.40MIDISC8), confirmed by midisc's
author.

Her recipe rewrites the apply_part entry 0x40009094 and the scene-parameter
writer 0x40052ae8; the ledger refuses any other module on those sites. CC
PAGE 2 shares her MIDI CC dispatch entry through the SCENES KITS bridge.
"""

from remix import arena
from remix.schema import ArenaReserve, Kind, Module, Runtime

MODULE = Module(
    name="octakit",
    key="OCTAKIT",
    kind=Kind.CF_PATCH,
    doc="Em's Octakit: 256 Kits per Project instead of 64 Parts, built from "
        "her repo (submodule) as a loader-appended DRAM runtime.",
    runtime=Runtime(
        recipe="modules/octakit/upstream/runtime/firmware.json",
        sources="modules/octakit/upstream/runtime",
        report_note=" -- Em's Octakit (emuyia/ems-octakit), submodule "
                    "modules/octakit/upstream",
    ),
    # Her runtime, Kit store and backup: the top 528 pages of the audio page
    # arena (0x45d0dde0..0x46025de0). Her four recipe writes shrink the arena
    # by exactly that; declared so the build stacks every reservation and
    # computes the geometry literals from the total (for her alone, her bytes).
    arena=ArenaReserve(pages=528, where="top",
                       recipe_writes=arena.OCTAKIT_RECIPE_WRITES),
)
