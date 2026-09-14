"""rig-scenes -- bamsep26 + MIDI SCENES.

No LO-FI AMF fix: the Character station replaces LO-FI, so its code is
harvested. Unflashed.
"""

from remix.schema import Remix

REMIX = Remix(
    name="rig-scenes",
    doc="The rig + MIDI SCENES.",
    modules=("REVERB SERVER", "DELAY SERVER", "SEND", "DELAY",
             "SPECTRUM", "CHARACTER", "MODULATION",
             "TEMPO SYNC", "CC PAGE 2",
             "MIDI SCENES"),
    fallback="SEND",
    fx1=("SPECTRUM", "CHARACTER", "MODULATION"),
)
