"""lofi-amf-fix -- the LO-FI AMF fix alone.

Two DSP-word pokes, no cave, no menu, no FX2 id, no free-space claim.
"""

from remix.schema import Remix

REMIX = Remix(
    name="lofi-amf-fix",
    doc="Reference minimal build: the LO-FI AMF mpysu->mpyuu fix, alone.",
    modules=("LOFI AMF FIX",),
    fallback="NONE",
)
