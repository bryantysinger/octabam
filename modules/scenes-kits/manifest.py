"""SCENES KITS -- the bridge that lets CC PAGE 2 and Octakit share the MIDI CC
dispatch entry (0x400d64a0).

Her recipe installs her handler there; CC PAGE 2 repoints the entry to its
cave. With the bridge, the cave keeps the entry and its fall-through
(CC_NEXT) becomes her handler, which falls through to stock's: CCs 62-73
ours, then hers, then stock's. Declared as an Override: the build skips her
recipe write at the site and defines CC_NEXT as the target it carried.

The apply_part entry (0x40009094) needed no bridge since midisc 1.40MSCN6
leaves it stock (his earlier wrapper hung project load on hardware), so
MIDI SCENES and OCTAKIT no longer collide anywhere; the chain stub that
ordered his pack/after around her engine load is in history (chains.s).

Measured under the port (docs/remixer/PLACEMENT.md). Not measured: MIDI
CCs through the chained dispatch on hardware.
"""

from remix.schema import Kind, Module, Override


MODULE = Module(
    name="scenes-kits",
    key="SCENES KITS",
    kind=Kind.CF_PATCH,
    doc="The bridge that lets CC PAGE 2 and Octakit share the CC dispatch "
        "(MIDI SCENES needs no bridging since 1.40MSCN6).",
    overrides=(
        Override(0x400D64A0, "OCTAKIT",
                 write="midi-control-parameter-000-at-400d64a0", defsym="CC_NEXT"),
    ),
)
