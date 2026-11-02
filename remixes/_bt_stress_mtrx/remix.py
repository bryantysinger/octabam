"""_bt_stress_mtrx -- _bt_mtrx_io's modules plus the stress test's instrument
(tools/hw/rec_stress.py): LOAD METER, which in this probes remix also turns on
USB's test commands (USB_TESTCMD: 0xc0/0x58 REC MATRIX's masks, 0xc0/0x59 the
screen). No FRAME PROFILE: it freezes a unit at full load (1 Nov 2026), so the
stress ceilings are measured without it. PHASER gives up its words for LOAD
METER's DSP half. A test image, not an everyday one."""
from remix.schema import Pin, Proof, Remix

CORE = ("BRAIN", "STORE", "KITS", "MIDI SCENES", "SCENES P2", "PLOCKS P2",
        "CC MAP", "CC FEEDBACK", "EVENTS", "USB",
        "RECORDER LOOP FIX", "BATCH_BUGFIXES", "ERASE_EMPTY_TRIGLESS_LOCKS",
        "QUANTIZE_LIVE_REC_TOGGLE", "REC_TRIG_MUTE", "MUTE_MODES",
        "SCALE QUANTIZER", "TUNER", "DIRECT_JUMP_KYOTI", "RELOAD_FROM_PROJECT", "RLEN PLEN",
        "ATA WRITE GUARD")
STOCK = ("FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER", "CHORUS", "SPATIALIZER",
         "COMB FILTER", "COMPRESSOR", "LO-FI", "DELAY", "PLATE REV", "SPRING REV", "DARK REV")
DROPPED = ("PHASER",)

REMIX = Remix(
    name="_bt_stress_mtrx",
    family="probes", proof=Proof.PORT, proof_note="built for tools/hw/rec_stress.py (31 Oct 2026; FRAME PROFILE out 1 Nov 2026)",
    doc="_bt_mtrx_io's modules + LOAD METER (no FRAME PROFILE): the stress test's MTRX image.",
    modules=CORE + ("REC MATRIX", "LOFI AMF FIX", "STRETCH ANALYSIS GATE", "LOAD METER")
            + tuple(e for e in STOCK if e not in DROPPED),
    fx1=tuple(e for e in STOCK[:10] if e not in DROPPED),
    fallback="NONE",
    settings={("octabam.usb", "TRACKS"): "OFF", ("octabam.usb", "MAIN"): 1,
              ("octabam.usb", "CUE"): 1, ("octabam.usb", "MASTER"): 0,
              ("octabam.usb", "IN"): "ABCD",
              ("kyoti.mute-modes", "PLACE"): Pin("DRAM")},
)
