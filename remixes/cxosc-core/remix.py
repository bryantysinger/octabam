"""cxosc-core -- CORE + REMIX SWITCH + CX OSC on the 14 stock effects.

Unit handoff for the complex-oscillator machine. Not folded into ilia/latest.
Conflicts with SYNTH MACHINE (not included).
"""

from remix.schema import Pin, Proof, Remix

from pathlib import Path
import runpy

_CORE = runpy.run_path(
    str(Path(__file__).resolve().parents[1] / "octabam-core" / "remix.py"),
    run_name="octabam_core_remix",
)
CORE = _CORE["CORE"]
STOCK14 = _CORE["STOCK14"]

REMIX = Remix(
    name="cxosc-core",
    family="mods", proof=Proof.CHECK,
    proof_note="unit handoff: CORE + CX OSC; marker-less machine list, mono, stock LFOs",
    doc="CORE + REMIX SWITCH + CX OSC on the 14 stock effects.",
    modules=CORE + ("REMIX SWITCH", "CX OSC", "LOFI AMF FIX") + STOCK14,
    fallback="NONE",
    settings={("octabam.usb", "TRACKS"): "PRE", ("octabam.usb", "MAIN"): 1,
              ("octabam.usb", "CUE"): 1, ("octabam.usb", "MASTER"): 0,
              ("octabam.usb", "IN"): Pin("OFF"),
              ("kyoti.mute-modes", "PLACE"): Pin("DRAM")},
)
