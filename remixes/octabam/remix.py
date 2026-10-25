"""octabam -- the core ColdFire modules, all 14 stock effects and our effects.

CORE (BRAIN, STORE, KITS, MIDI SCENES, SCENES P2, PLOCKS P2, CC MAP, CC FEEDBACK,
USB at MAIN CUE, the recorder and bug fixes, MUTE_MODES from DRAM, SCALE QUANTIZER,
TUNER, DIRECT_JUMP_KYOTI, RELOAD_FROM_PROJECT, RLEN PLEN, LOAD METER) with all 14
stock effects and LOFI AMF FIX. SPECTRUM, CHARACTER, MODULATION, TRANSIENT and
GATE VERB run from the shared P window beside them, each on its own free id;
LOAD METER's DSP half runs from the window too. No bus and no SEND (fallback NONE).
"""
from remix.schema import Pin, Proof, Remix

CORE = ("BRAIN", "STORE", "KITS", "MIDI SCENES", "SCENES P2", "PLOCKS P2",
        "CC MAP", "CC FEEDBACK", "USB",
        "RECORDER LOOP FIX", "BATCH_BUGFIXES", "ERASE_EMPTY_TRIGLESS_LOCKS",
        "QUANTIZE_LIVE_REC_TOGGLE", "REC_TRIG_MUTE", "MUTE_MODES",
        "SCALE QUANTIZER", "TUNER", "DIRECT_JUMP_KYOTI", "RELOAD_FROM_PROJECT", "RLEN PLEN",
        "ATA WRITE GUARD", "SEQUENCER EVENTS",
        "LOAD METER")
STOCK14 = ("FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER", "CHORUS", "SPATIALIZER",
           "COMB FILTER", "COMPRESSOR", "LO-FI", "DELAY", "PLATE REV", "SPRING REV", "DARK REV")
OURS = ("MODULATION", "SPECTRUM", "CHARACTER", "TRANSIENT", "GATE VERB")

REMIX = Remix(
    name="octabam",
    family="mods", proof=Proof.CHECK, proof_note="",
    doc="The core ColdFire modules, all 14 stock effects, and SPECTRUM, CHARACTER, MODULATION, TRANSIENT and GATE VERB.",
    modules=CORE + ("LOFI AMF FIX", "MODE DEFAULTS") + STOCK14 + OURS,
    window=(("GATE VERB", 0x35800), ("MODULATION", 0x36300), ("SPECTRUM", 0x36a00),
            ("CHARACTER", 0x37100), ("TRANSIENT", 0x37600), ("LOAD METER", 0x37800),
            ("LOAD METER:B", 0x37900)),
    fallback="NONE",
    settings={("octabam.usb", "TRACKS"): "PRE", ("octabam.usb", "MAIN"): 1,
              ("octabam.usb", "CUE"): 1, ("octabam.usb", "MASTER"): 0,
              ("octabam.usb", "IN"): "OFF",
              ("kyoti.mute-modes", "PLACE"): Pin("DRAM")},
)
