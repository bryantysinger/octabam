"""_bt_mtrx_io_rcs -- _bt_mtrx_io plus REC CS1 SKIP: the everyday looping image
with both recorder-cost changes sent upstream (sambanks/octabam #1014, #1015).

RECORDER LOOP FIX's memoised spacing cave is already in every image that carries
RECORDER LOOP FIX; this adds REC CS1 SKIP (the same instructions as #1015). The
modules otherwise are _bt_mtrx_io's: octabam core + REC MATRIX + LOFI AMF FIX +
STRETCH ANALYSIS GATE on the 14 stock effects, USB 4 in (ABCD) / 4 out (MAIN CUE),
plus EVENTS, which PLOCKS P2 now requires (as in the stress images).
"""

from remix.schema import Pin, Proof, Remix

CORE = ("BRAIN", "STORE", "KITS", "MIDI SCENES", "SCENES P2", "PLOCKS P2",
        "CC MAP", "CC FEEDBACK", "EVENTS", "USB",
        "RECORDER LOOP FIX", "BATCH_BUGFIXES", "ERASE_EMPTY_TRIGLESS_LOCKS",
        "QUANTIZE_LIVE_REC_TOGGLE", "REC_TRIG_MUTE", "MUTE_MODES",
        "SCALE QUANTIZER", "TUNER", "DIRECT_JUMP_KYOTI", "RELOAD_FROM_PROJECT", "RLEN PLEN",
        "ATA WRITE GUARD")
STOCK14 = ("FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER", "CHORUS", "SPATIALIZER",
           "COMB FILTER", "COMPRESSOR", "LO-FI", "DELAY", "PLATE REV", "SPRING REV", "DARK REV")

REMIX = Remix(
    name="_bt_mtrx_io_rcs",
    family="mods", proof=Proof.CHECK, proof_note="built 2 Nov 2026 to try #1014 and #1015 on Bryan T's MKII",
    doc="_bt_mtrx_io + REC CS1 SKIP: the everyday looping image with both recorder-cost changes.",
    modules=CORE + ("REC MATRIX", "LOFI AMF FIX", "STRETCH ANALYSIS GATE", "REC CS1 SKIP") + STOCK14,
    fallback="NONE",
    settings={("octabam.usb", "TRACKS"): "OFF", ("octabam.usb", "MAIN"): 1,
              ("octabam.usb", "CUE"): 1, ("octabam.usb", "MASTER"): 0,
              ("octabam.usb", "IN"): "ABCD",
              ("kyoti.mute-modes", "PLACE"): Pin("DRAM")},
)
