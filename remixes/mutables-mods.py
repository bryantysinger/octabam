"""mutables-mods -- the five inserts + every community firmware mod.

WarpFold, Ripple, Rungs, Streamz, BodeShift with MIDI SCENES, Octakit, the
LO-FI AMF fix and CC PAGE 2, bridged by SCENES KITS. No bus: absent ids
resolve to NONE. Back up projects first. Unflashed.
"""

from remix.schema import Remix

REMIX = Remix(
    name="mutables-mods",
    doc="Five MI inserts + every community firmware mod, bridged.",
    modules=("WARPFOLD", "RIPPLE", "RUNGS", "STREAMZ", "BODESHIFT",
             "MIDI SCENES", "OCTAKIT", "LOFI AMF FIX", "CC PAGE 2", "SCENES KITS"),
    fallback="NONE",
)
