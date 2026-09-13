"""COMPTEST -- the rig minus CHARACTER, plus the STOCK COMPRESSOR kept AND
listed in the FX1 chooser, so it can go on the master (T8 FX1) with a wide
stereo mix and we see whether IT collapses the right channel the way
Character's AC1 comp does on the unit (14 Sep 2026). Character is dropped to
free its 1,170-word contiguous run for COMPRESSOR.

First cut (OCTABAM2) was silent, not hung: Character's id on T1/T8 in the
stamped project resolved to the null stub (proven silent on hardware) and
COMPRESSOR was not in the FX1 chooser at all. On the unit: select COMP on
T8's FX1 (and NONE on T1's) at the panel before judging anything."""
from remix.schema import Remix

REMIX = Remix(
    name="comptest",
    doc="rig minus Character + stock COMPRESSOR on FX1, for the master-comp A/B.",
    modules=("REVERB SERVER", "DELAY SERVER", "SEND", "DELAY", "COMPRESSOR",
             "SPECTRUM", "MODULATION",
             "TEMPO SYNC", "CC PAGE 2"),
    fallback="SEND",
    fx1=("SPECTRUM", "MODULATION", "COMPRESSOR"),
)
