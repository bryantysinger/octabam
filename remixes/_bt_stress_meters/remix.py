"""_bt_stress_meters -- _bt_stress_base without RECORDER LOOP FIX: stock with only
the recorder stress test's instruments (BRAIN, USB, LOAD METER, FRAME PROFILE),
so the pair prices RECORDER LOOP FIX on hardware (tools/hw/rec_stress.py)."""
from remix.schema import Proof, Remix

STOCK = ("FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER", "CHORUS", "SPATIALIZER",
         "COMB FILTER", "COMPRESSOR", "LO-FI", "DELAY", "PLATE REV", "SPRING REV", "DARK REV")
DROPPED = ("PHASER",)

REMIX = Remix(
    name="_bt_stress_meters",
    family="probes", proof=Proof.PORT, proof_note="built for tools/hw/rec_stress.py (1 Nov 2026)",
    doc="Stock + the meters (BRAIN, USB, LOAD METER, FRAME PROFILE), no RECORDER LOOP FIX: prices the fix against _bt_stress_base.",
    modules=("BRAIN", "USB", "LOAD METER", "FRAME PROFILE", "LOFI AMF FIX")
            + tuple(e for e in STOCK if e not in DROPPED),
    fx1=tuple(e for e in STOCK[:10] if e not in DROPPED),
    fallback="NONE",
    settings={("octabam.usb", "TRACKS"): "OFF", ("octabam.usb", "MAIN"): 1,
              ("octabam.usb", "CUE"): 1, ("octabam.usb", "MASTER"): 0,
              ("octabam.usb", "IN"): "ABCD"},
)
