"""task-meter-fp -- task-meter plus FRAME PROFILE (the frame interrupt by section). task-meter -- the smallest image that the analyzer sweep (tools/hw/analyzer_sweep.py) reads: BRAIN for the
task ledger, USB for vendor request 0xc0/0x57 (block 4, brain_ts) and LOAD METER for the frame interrupt's share
(block 0), with the RECORDER LOOP FIX and LO-FI AMF FIX and the stock effects. PHASER gives up its words for LOAD
METER's DSP half, as in stock-meter-a. Nothing else of ours runs, so the tasks' shares are stock's own."""
from remix.schema import Proof, Remix

STOCK = ("FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER", "CHORUS", "SPATIALIZER",
         "COMB FILTER", "COMPRESSOR", "LO-FI", "DELAY", "PLATE REV", "SPRING REV", "DARK REV")
DROPPED = ("PHASER",)

REMIX = Remix(
    name="task-meter-fp",
    family="probes", proof=Proof.PORT, proof_note="block 4 read over the port's USB bench (26 Oct 2026)",
    doc="BRAIN + USB + LOAD METER over stock: each ColdFire task's share read over USB (tools/hw/task_meter.py).",
    modules=("BRAIN", "USB", "LOAD METER", "RECORDER LOOP FIX", "LOFI AMF FIX", "FRAME PROFILE")
            + tuple(e for e in STOCK if e not in DROPPED),
    fx1=tuple(e for e in STOCK[:10] if e not in DROPPED),
    fallback="NONE",
    settings={("octabam.usb", "TRACKS"): "PRE", ("octabam.usb", "MAIN"): 1,
              ("octabam.usb", "CUE"): 1, ("octabam.usb", "MASTER"): 0,
              ("octabam.usb", "IN"): "OFF"},
)
