"""mutables -- five Mutable-Instruments-flavoured inserts.

WarpFold (ring mod / wavefolder), Ripple (driven SVF), Rungs (8-mode modal
resonator), Streamz (vactrol lowpass gate), BodeShift (frequency shifter).
Inserts sit in both payloads and stack: any track can host any of them.
No bus and no SEND: absent ids resolve to the firmware's own NONE. No
ColdFire caves. Verified by local render; unflashed.
"""

from remix.schema import Remix

REMIX = Remix(
    name="mutables",
    doc="Five MI-flavoured inserts: WarpFold, Ripple, Rungs, Streamz, BodeShift.",
    modules=("WARPFOLD", "RIPPLE", "RUNGS", "STREAMZ", "BODESHIFT"),
    fallback="NONE",
)
