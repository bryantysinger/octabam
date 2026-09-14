"""mutables-kits -- the five inserts + the Octakit family.

WarpFold, Ripple, Rungs, Streamz, BodeShift with Octakit, the LO-FI AMF fix
and CC PAGE 2 (bridged by SCENES KITS). No bus: absent ids resolve to NONE.
Back up projects first. Unflashed.
"""

from remix.schema import Remix

REMIX = Remix(
    name="mutables-kits",
    doc="Five MI inserts + Octakit + the LO-FI AMF fix + CC to page 2.",
    modules=("WARPFOLD", "RIPPLE", "RUNGS", "STREAMZ", "BODESHIFT",
             "OCTAKIT", "LOFI AMF FIX", "CC PAGE 2", "SCENES KITS"),
    fallback="NONE",
)
