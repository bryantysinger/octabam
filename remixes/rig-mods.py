"""rig-mods -- bamsep26 + MIDI SCENES + Octakit (bridged).

No LO-FI AMF fix (Character replaces LO-FI). The rig-kits caveat applies:
the hosts' part bytes against her migration are unmeasured. Back up
projects first. Unflashed.
"""

from remix.schema import Remix

REMIX = Remix(
    name="rig-mods",
    doc="The rig + MIDI SCENES + Octakit, bridged.",
    modules=("REVERB SERVER", "DELAY SERVER", "SEND", "DELAY",
             "SPECTRUM", "CHARACTER", "MODULATION",
             "TEMPO SYNC", "CC PAGE 2",
             "MIDI SCENES", "OCTAKIT", "SCENES KITS", "KITS RELOAD"),
    fallback="SEND",
    fx1=("SPECTRUM", "CHARACTER", "MODULATION"),
)
