"""midi-scenes -- MIDI SCENES alone.

One ColdFire module, no DSP, no menu row: the reference minimal build of
the DRAM platform with a real mod on it. Unflashed on its own (ok-ms, which
carries it, has run on hardware).
"""

from remix.schema import Remix

REMIX = Remix(
    name="midi-scenes",
    doc="Reference minimal build: the MIDI SCENES ColdFire patch, alone.",
    modules=("MIDI SCENES",),
    fallback="NONE",
)
