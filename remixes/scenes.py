"""scenes -- the MIDI SCENES family, no effects of ours.

MIDI SCENES + the LO-FI AMF fix + CC PAGE 2. No octabam DSP; every stock
effect stays and the chooser is stock's. Unflashed.
"""

from remix.schema import Remix

REMIX = Remix(
    name="scenes",
    doc="All the firmware mods of the MIDI SCENES family, no effects: scenes "
        "over MIDI, the LO-FI AMF fix, CC to page 2.",
    modules=("MIDI SCENES", "LOFI AMF FIX", "CC PAGE 2"),
    fallback="NONE",
)
