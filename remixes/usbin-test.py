"""usbin-test -- stock effects minus SPATIALIZER, plus the USB IN TEST
transport: the ColdFire sends a test pattern to core 0 every frame and the
DSP overwrites inputs A-D with it (the jacks are overridden).

Emulator-first (Bryan T, 26 Sep 2026). SPATIALIZER is off both choosers
because the DSP inject routine lives in its words on payload A.
"""

from remix.schema import Remix

REMIX = Remix(
    name="usbin-test",
    doc="stock - SPATIALIZER + USB IN TEST (CF -> DSP pattern over inputs A-D).",
    modules=("USB IN TEST",
             "FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER", "CHORUS",
             "COMB FILTER", "COMPRESSOR", "LO-FI", "DELAY",
             "PLATE REV", "SPRING REV", "DARK REV"),
    fx1=("FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER", "CHORUS",
         "COMB FILTER", "COMPRESSOR", "LO-FI"),
    fallback="NONE",
)
