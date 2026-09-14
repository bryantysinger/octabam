"""nimbus -- the granular texture insert, alone.

Nimbus owns the core-private FX2 buffer region Y:0x4000-0xBFFF, so it is one
instance per core and cannot share an image with a server (BusVerb's tank
is in that region) or with the seven stock effects that allocate a buffer.
Unflashed.
"""

from remix.schema import Remix

REMIX = Remix(
    name="nimbus",
    doc="Nimbus granular texture, alone. One instance per core.",
    modules=("NIMBUS",),
    fallback="NONE",
)
