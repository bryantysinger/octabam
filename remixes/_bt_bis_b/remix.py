"""_bt_bis_b -- bisecting build 84's eight-loop freeze (SELF x8, cable out): USB and LOAD METER (PHASER gives up its words for LOAD METER's DSP half)
Pass/fail by eye on the unit (stock runs STRESS_INT's A08; 84 freezes at bar 2)."""
from remix.schema import Proof, Remix

STOCK = ("FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER", "CHORUS", "SPATIALIZER",
         "COMB FILTER", "COMPRESSOR", "LO-FI", "DELAY", "PLATE REV", "SPRING REV", "DARK REV")
DROPPED = ('PHASER',)

REMIX = Remix(
    name="_bt_bis_b",
    family="probes", proof=Proof.PORT, proof_note="built to bisect the eight-loop freeze (1 Nov 2026)",
    doc="Stock + USB, LOAD METER: half of build 84's modules, to bisect its eight-loop freeze.",
    modules=('USB', 'LOAD METER') + tuple(e for e in STOCK if e not in DROPPED),
    fx1=tuple(e for e in STOCK[:10] if e not in DROPPED),
    fallback="NONE",
    settings={("octabam.usb", "TRACKS"): "OFF", ("octabam.usb", "MAIN"): 1,
              ("octabam.usb", "CUE"): 1, ("octabam.usb", "MASTER"): 0,
              ("octabam.usb", "IN"): "ABCD"},
)
