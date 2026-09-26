"""usbin-test -- stock effects minus SPATIALIZER, plus the USB IN TEST
transport: the ColdFire sends a test pattern to core 0 every frame and the
DSP overwrites inputs A-D with it (the jacks are overridden).

Emulator-first (Bryan T, 26 Sep 2026). USB MIDI and USB AUDIO as in
usb-lean, so the tones can be recorded over USB (MAIN 17/18 with DIR up).
USB AUDIO OUT step 1: the configuration also declares a 4-channel output
(EP3 OUT, implicit feedback), with no data path behind it yet. SPATIALIZER is off both choosers
because the DSP inject routine lives in its words on payload A.
"""

from remix.schema import Remix

REMIX = Remix(
    name="usbin-test",
    doc="stock - SPATIALIZER + USB MIDI + USB AUDIO (20 ch out) + USB IN TEST (tones over inputs A-D).",
    modules=("USB IN TEST", "USB MIDI", "USB AUDIO", "USB AUDIO OUT",
             "FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER", "CHORUS",
             "COMB FILTER", "COMPRESSOR", "LO-FI", "DELAY",
             "PLATE REV", "SPRING REV", "DARK REV"),
    fx1=("FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER", "CHORUS",
         "COMB FILTER", "COMPRESSOR", "LO-FI"),
    fallback="NONE",
)
