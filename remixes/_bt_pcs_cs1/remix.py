"""_bt_pcs_cs1 -- _bt_pcs_base plus REC CS1 SKIP (the A/B for it). _bt_pcs_base: _bt_stress_base plus PC SAMPLER: where the ColdFire's time goes
(tools/hw/pc_sampler.py) on the stress baseline. From _bt_stress_base:
the recorder stress test's baseline (tools/hw/rec_stress.py):
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
    name="_bt_pcs_cs1",
    family="probes", proof=Proof.PORT, proof_note="built for tools/hw/pc_sampler.py (1 Nov 2026)",
    doc="_bt_pcs_base + REC CS1 SKIP; _bt_pcs_base is _bt_stress_base + PC SAMPLER: stock + RECORDER LOOP FIX + the meters, with the ColdFire's time by code address.",
    modules=("BRAIN", "USB", "LOAD METER", "PC SAMPLER", "REC CS1 SKIP", "RECORDER LOOP FIX", "LOFI AMF FIX")
            + tuple(e for e in STOCK if e not in DROPPED),
    fx1=tuple(e for e in STOCK[:10] if e not in DROPPED),
    fallback="NONE",
    settings={("octabam.usb", "TRACKS"): "OFF", ("octabam.usb", "MAIN"): 1,
              ("octabam.usb", "CUE"): 1, ("octabam.usb", "MASTER"): 0,
              ("octabam.usb", "IN"): "ABCD"},
)
