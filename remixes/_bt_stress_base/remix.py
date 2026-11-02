"""_bt_stress_base -- the recorder stress test's baseline (tools/hw/rec_stress.py):
stock + RECORDER LOOP FIX with only the instruments. BRAIN (task ledger), USB
(the meters' vendor requests; IN ABCD / OUT MAIN CUE for the streaming rungs)
and LOAD METER. No FRAME PROFILE: it freezes a unit at full load (1 Nov 2026).
PHASER gives up its words for LOAD METER's DSP half, as in remixes/test/task-meter.
No REC MATRIX: the MTRX rungs are skipped."""
from remix.schema import Proof, Remix

STOCK = ("FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER", "CHORUS", "SPATIALIZER",
         "COMB FILTER", "COMPRESSOR", "LO-FI", "DELAY", "PLATE REV", "SPRING REV", "DARK REV")
DROPPED = ("PHASER",)

REMIX = Remix(
    name="_bt_stress_base",
    family="probes", proof=Proof.PORT, proof_note="built for tools/hw/rec_stress.py (31 Oct 2026)",
    doc="Stock + RECORDER LOOP FIX + the meters (BRAIN, USB, LOAD METER; no FRAME PROFILE): the stress test's baseline.",
    modules=("BRAIN", "USB", "LOAD METER", "RECORDER LOOP FIX", "LOFI AMF FIX")
            + tuple(e for e in STOCK if e not in DROPPED),
    fx1=tuple(e for e in STOCK[:10] if e not in DROPPED),
    fallback="NONE",
    settings={("octabam.usb", "TRACKS"): "OFF", ("octabam.usb", "MAIN"): 1,
              ("octabam.usb", "CUE"): 1, ("octabam.usb", "MASTER"): 0,
              ("octabam.usb", "IN"): "ABCD"},
)
