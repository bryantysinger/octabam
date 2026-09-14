"""kits -- the Octakit family, no effects of ours.

Octakit + the LO-FI AMF fix + CC PAGE 2, with SCENES KITS bridging CC PAGE 2
and Octakit at the CC dispatch entry. No octabam DSP. Unflashed.

Octakit migrates Parts into Kits on load: back up projects first.
"""

from remix.schema import Remix

REMIX = Remix(
    name="kits",
    doc="All the firmware mods of the Octakit family, no effects: 256 Kits, "
        "the LO-FI AMF fix, CC to page 2.",
    modules=("OCTAKIT", "LOFI AMF FIX", "CC PAGE 2", "SCENES KITS"),
    fallback="NONE",
)
