"""_bt_bis_c -- bisecting build 84's eight-loop freeze (SELF x8, cable out): USB, LOAD METER and FRAME PROFILE (PHASER gives up its words for LOAD METER's DSP half)
Pass/fail by eye on the unit (stock runs STRESS_INT's A08; 84 freezes at bar 2)."""
from remix.schema import Proof, Remix

STOCK = ("FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER", "CHORUS", "SPATIALIZER",
         "COMB FILTER", "COMPRESSOR", "LO-FI", "DELAY", "PLATE REV", "SPRING REV", "DARK REV")
DROPPED = ('PHASER',)

REMIX = Remix(
    name="_bt_bis_c",
    family="probes", proof=Proof.PORT, proof_note="built to bisect the eight-loop freeze (1 Nov 2026)",
    doc="Stock + USB, LOAD METER, FRAME PROFILE: build 84 without BRAIN and LOFI AMF FIX, to bisect its eight-loop freeze.",
    modules=('USB', 'LOAD METER', 'FRAME PROFILE') + tuple(e for e in STOCK if e not in DROPPED),
    fx1=tuple(e for e in STOCK[:10] if e not in DROPPED),
    fallback="NONE",
    settings={("octabam.usb", "TRACKS"): "OFF", ("octabam.usb", "MAIN"): 1,
              ("octabam.usb", "CUE"): 1, ("octabam.usb", "MASTER"): 0,
              ("octabam.usb", "IN"): "ABCD"},
)
