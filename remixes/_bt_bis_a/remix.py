"""_bt_bis_a -- bisecting build 84's eight-loop freeze (SELF x8, cable out): BRAIN and LOFI AMF FIX
Pass/fail by eye on the unit (stock runs STRESS_INT's A08; 84 freezes at bar 2)."""
from remix.schema import Proof, Remix

STOCK = ("FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER", "CHORUS", "SPATIALIZER",
         "COMB FILTER", "COMPRESSOR", "LO-FI", "DELAY", "PLATE REV", "SPRING REV", "DARK REV")
DROPPED = ()

REMIX = Remix(
    name="_bt_bis_a",
    family="probes", proof=Proof.PORT, proof_note="built to bisect the eight-loop freeze (1 Nov 2026)",
    doc="Stock + BRAIN, LOFI AMF FIX: half of build 84's modules, to bisect its eight-loop freeze.",
    modules=('BRAIN', 'LOFI AMF FIX') + tuple(e for e in STOCK if e not in DROPPED),
    fx1=tuple(e for e in STOCK[:10] if e not in DROPPED),
    fallback="NONE",
)
