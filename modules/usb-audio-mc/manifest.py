"""USB AUDIO MC -- USB AUDIO as a four-channel stream of MAIN and CUE.

Channels 1-4: MAIN L/R and CUE L/R, the DAC feed itself, at high speed (the
same 250 us cadence as USB AUDIO EXTENDED/FULL, not USB AUDIO MASTER's 1 ms).
Full speed carries MAIN alone. USB AUDIO EXTENDED's source (markandrus/octemu,
MIT) assembled with USB_LAYOUT = 3: the producer reads MC_BASE directly (it is
not ping-ponged, so no bank bookkeeping is needed, unlike the tracks' read-back
arena) and writes one 16-byte slot per frame. It takes the same hook sites as
USB AUDIO EXTENDED, USB AUDIO FULL and USB AUDIO MASTER, so a remix carries one
of the four.

This reproduces, as an independent module, the MAIN+CUE-only high-speed
stream that usbin-test's AUD_IN4 flag forced onto the twenty-channel build
whenever USB AUDIO IN (the host -> A-D stream) was present. Here the two are
decoupled: USB AUDIO IN can pair with this, or with FULL or EXTENDED, at
whatever USB bandwidth budget the remix wants -- only the 4-in/4-out
combination (this module) has been run on hardware. README.md.
"""
import dataclasses
import importlib.util
import pathlib

from remix import schema
from remix.schema import Category, Proof, Linked, Module

_spec = importlib.util.spec_from_file_location(
    "usbaudio_manifest", pathlib.Path(schema.__file__).resolve().parents[2] / "modules/usb-audio-extended/manifest.py")
usbaudio = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(usbaudio)

_PRODUCER = 0x4000d9a0

MODULE = Module(
    name="usb-audio-mc", key="USB AUDIO MC", kind=usbaudio.MODULE.kind,
    category=Category.MIDI_USB, author="markandrus/octemu", author_url="https://github.com/markandrus/octemu",
    proof=Proof.PORT, proof_note="`verify_usb` under the port (27 Sep 2026); this build not on hardware (usbin-test's AUD_IN4 ran the MAIN+CUE high-speed stream on Bryan T's MKII, 26 Sep 2026, as a slice of the 20-channel producer; the full-speed MAIN-only path is new)",
    doc="MAIN and CUE over USB (UAC2, 4 channels, 24-bit) at EXTENDED/FULL's 250 us cadence; full speed carries MAIN alone (markandrus/octemu; the MC variant Bryan T's, from usbin-test's AUD_IN4).",
    linked=(Linked("usbaudio", usbaudio.SOURCE, cpu="5475", dram=True, include=usbaudio.layout_inc(3)),),
    detours=tuple(
        dataclasses.replace(d, **({"note": "frame_isr's last instruction: the per-block producer (MAIN L/R + CUE L/R) and the packet builder"}
                                  if d.site == _PRODUCER else {}))
        for d in usbaudio.DETOURS),
    overrides=usbaudio.MODULE.overrides,
    pokes=usbaudio.MODULE.pokes,
)
