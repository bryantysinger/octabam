"""mutables-scenes -- the five inserts + the MIDI SCENES family.

WarpFold, Ripple, Rungs, Streamz, BodeShift with MIDI SCENES, the LO-FI AMF
fix and CC PAGE 2. No bus: absent ids resolve to NONE. Unflashed.
"""

from remix.schema import Remix

REMIX = Remix(
    name="mutables-scenes",
    doc="Five MI inserts + MIDI SCENES + the LO-FI AMF fix + CC to page 2.",
    modules=("WARPFOLD", "RIPPLE", "RUNGS", "STREAMZ", "BODESHIFT",
             "MIDI SCENES", "LOFI AMF FIX", "CC PAGE 2"),
    fallback="NONE",
)
