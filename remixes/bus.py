"""bus -- the plain two-server image: BusVerb, BusDelay, SEND, tempo sync.

The registry default and scripts/refhash.sh's subject: a change to the
build proves itself by rebuilding this byte for byte. Module order is the
FX2 chooser order. TEMPO SYNC takes no row; it is the cave that makes
BusDelay's TIME read "1/8" rather than milliseconds.
"""

from remix.schema import Remix

REMIX = Remix(
    name="bus",
    doc="The plain two-server image: BusVerb + BusDelay + send bus + tempo sync.",
    modules=("REVERB SERVER", "DELAY SERVER", "SEND", "TEMPO SYNC"),
    fallback="SEND",
)
