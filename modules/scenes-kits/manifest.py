"""SCENES KITS -- the bridge: Octakit and CC PAGE 2 sharing the CC dispatch.

Until 10 Sep 2026 the ledger refused every pair of the community mods
(Sam: "rather than make them exclusive can we be brutal and make them all
work?"). This module is what lets them share a stock site:

  * the MIDI CC dispatch entry (0x400d64a0): her recipe installs her
    handler, CC PAGE 2 repoints it to its cave. The cave keeps the entry;
    its fall-through (CC_NEXT) becomes her handler instead of stock's, and
    hers falls through to stock as before. CCs 62-67 are ours, then hers,
    then stock's.

It USED to bridge a second site, the apply_part entry (0x40009094), where
midisc's wrapper and Octakit's engine-load both rewrote the prologue:
`chains.s` ran his pre-work (caller into apply_ret, return through `after`,
`jsr pack`) and jumped into her entry, gated on her lifecycle state so his
swap never tripped her boot-time fatal. Since his 1.40MSCN6 (13 Sep 2026)
midisc leaves that site stock -- "apply pack/unpack during project load
hangs HW" -- so Octakit owns it alone and the chain is gone (chains.s is in
history). MIDI SCENES and OCTAKIT no longer collide anywhere; this module
is needed only when CC PAGE 2 and OCTAKIT are both in the image.

Declared as an Override (schema.Override): the build skips her recipe
write at the CC site and defines CC_NEXT as the target it carried.

MEASURED (port): see docs/remixer/PLACEMENT.md and this README. NOT
measured: hardware. Kits semantics -- his Part save/reload menu hooks
against her LOAD/SAVE KIT menus -- remain the open question this bridge
does not answer.
"""

from remix.schema import Kind, Module, Override


MODULE = Module(
    name="scenes-kits",
    key="SCENES KITS",
    kind=Kind.CF_PATCH,
    doc="The bridge that lets CC PAGE 2 and Octakit share the CC dispatch "
        "(MIDI SCENES needs no bridging since 1.40MSCN6).",
    # Since his 1.40MSCN6 (13 Sep 2026) MIDI SCENES no longer hooks
    # apply_part (0x40009094): Octakit owns that site alone, and the chain
    # stub that ordered his pack/after around her engine load is gone with
    # it (modules/scenes-kits/chains.s, in history). What is left to bridge
    # is the CC dispatch, CC PAGE 2's stub tail-calling her handler.
    overrides=(
        Override(0x400D64A0, "OCTAKIT",
                 write="midi-control-parameter-000-at-400d64a0", defsym="CC_NEXT"),
    ),
)
