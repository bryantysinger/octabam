"""USB AUDIO OUT -- four channels from the host standing in for inputs A-D.

Step 1 (Bryan T, 26 Sep 2026): descriptors only. With this key in a remix,
USB MIDI's descriptor unit grows the audio function by a host -> device
path: a USB streaming input terminal and a line output terminal on the
same clock, and AudioStreaming interface 5 (alt 0 idle, alt 1 with EP3 OUT,
isochronous asynchronous, 4 ch x 24-bit in 4-byte subslots, 192 B every
250 us at high speed). EP3 IN is marked as the implicit-feedback data
endpoint: no endpoint is free for an explicit feedback IN (EP1 mass storage,
EP2 USB MIDI, EP3 IN the input stream), so the host sizes each OUT packet
from the IN stream's. The configuration grows from 250 to 334 bytes.

No code yet: SET_INTERFACE on interface 5 reaches the stock handler, and
EP3 OUT is never primed. This step asks one question of the host: does it
accept the implicit-feedback pairing and list a four-channel output?
Needs USB MIDI and USB AUDIO.
"""
from remix.schema import Kind, Module

MODULE = Module(
    name="usbaudio-out", key="USB AUDIO OUT", kind=Kind.CF_PATCH,
    doc="Four channels from the host for inputs A-D (step 1: descriptors only; implicit feedback on EP3 IN).",
)
