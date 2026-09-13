"""COMPTEST -- the rig minus CHARACTER, plus the STOCK COMPRESSOR kept, so
the stock compressor can go on the master (T8) with a wide stereo mix and we
see if IT collapses the right channel like Character's AC1 comp did (14 Sep
2026). Character dropped to free its 1,170-word contiguous run for COMPRESSOR;
no return (Character was the return-by-position), so the engines print on
their hosts -- the mix is still wide stereo. Not a shipping rig."""
from remix.schema import Remix

REMIX = Remix(
    name="comptest",
    doc="rig minus Character + stock COMPRESSOR, for the master-comp test.",
    modules=("REVERB SERVER", "DELAY SERVER", "SEND", "DELAY", "COMPRESSOR",
             "SPECTRUM", "MODULATION",
             "TEMPO SYNC", "CC PAGE 2"),
    fallback="SEND",
    fx1=("SPECTRUM", "MODULATION"),
)
