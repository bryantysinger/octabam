"""usb-audio -- the rig plus USB MIDI and sixteen channels of USB audio.

`usb` with USB AUDIO (markandrus/octemu's UAC2 proof of concept) on the
DRAM platform: at USB high speed the unit is also a 16-channel 44.1 kHz
24-bit audio input, track N's post-FX pre-fader L/R on channels 2N-1/2N;
at full speed the stereo sum of the tracks. The 16-bit stream was on
hardware as image 64 (25 Sep 2026); the 24-bit one is port-measured only.
docs/remixes/usb.md has the build and use steps.
"""

from remix.schema import Remix

REMIX = Remix(
    name="usb-audio",
    doc="usb + USB AUDIO: sixteen channels of the tracks over USB (UAC2).",
    modules=("REVERB SERVER", "DELAY SERVER", "SEND",
             "SPECTRUM", "CHARACTER", "MODULATION",
             "TEMPO SYNC", "CC MAP", "MODE DEFAULTS", "RIG HOSTS",
             "USB MIDI", "USB AUDIO"),
    fallback="SEND",
    hidden=("REVERB SERVER", "DELAY SERVER"),
    named=("REVERB SERVER", "DELAY SERVER"),
    locked=("REVERB SERVER", "DELAY SERVER"),
    fx1=("SPECTRUM", "CHARACTER", "MODULATION"),
)
