"""_bt_mtrx_io36 -- _bt_mtrx_io on BUILD 36's USB (the OUT producer writes the packets).

_bt_mtrx_io -- _bt_core_mtrx as a 4-in / 4-out USB interface.

The same modules as _bt_core_mtrx (octabam-core + REC MATRIX + LOFI AMF FIX on
the 14 stock effects); USB as usb-io-stock14: MAIN L/R and CUE L/R to the
host, host channels 1-4 into inputs A-D (the inject in payload A's tail).
"""

from remix.schema import Pin, Proof, Remix

CORE = ("BRAIN", "STORE", "KITS", "MIDI SCENES", "SCENES P2", "PLOCKS P2",
        "CC MAP", "CC FEEDBACK", "USB",
        "RECORDER LOOP FIX", "BATCH_BUGFIXES", "ERASE_EMPTY_TRIGLESS_LOCKS",
        "QUANTIZE_LIVE_REC_TOGGLE", "REC_TRIG_MUTE", "MUTE_MODES",
        "SCALE QUANTIZER", "TUNER", "DIRECT_JUMP_KYOTI", "RELOAD_FROM_PROJECT", "RLEN PLEN",
        "ATA WRITE GUARD", "EVENTS")
STOCK14 = ("FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER", "CHORUS", "SPATIALIZER",
           "COMB FILTER", "COMPRESSOR", "LO-FI", "DELAY", "PLATE REV", "SPRING REV", "DARK REV")

REMIX = Remix(
    name="_bt_mtrx_io36",
    family="mods", proof=Proof.HARDWARE, proof_note="Bryan T's MKII; untested as of 24 Oct 2026",
    doc="REC MATRIX + the core ColdFire modules on the 14 stock effects, USB 4 in (ABCD) / 4 out (MAIN CUE).",
    modules=CORE + ("REC MATRIX", "LOFI AMF FIX", "STRETCH ANALYSIS GATE") + STOCK14,
    fallback="NONE",
    settings={("octabam.usb", "TRACKS"): "OFF", ("octabam.usb", "MAIN"): 1,
              ("octabam.usb", "CUE"): 1, ("octabam.usb", "MASTER"): 0,
              ("octabam.usb", "IN"): "ABCD",
              ("kyoti.mute-modes", "PLACE"): Pin("DRAM")},
)
