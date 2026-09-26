"""USB AUDIO -- the unit as a UAC2 audio input, 20 channels at 44.1 kHz 24-bit.

High speed: the eight tracks' L/R (post-FX, pre-fader) on channels 1-16,
MAIN on 17-18, CUE on 19-20. Full speed: the tracks' stereo sum.
markandrus (octemu, MIT); MAIN/CUE Bryan T. A DRAM unit with build-time
detours. Needs USB MIDI: the audio function joins its composite, and the
ISR shim chains to USB MIDI's. README.md has the design and what was
measured.
"""
from remix.schema import Detour, Kind, Linked, Module, Override, Poke

H = bytes.fromhex

MODULE = Module(
    name="usbaudio", key="USB AUDIO", kind=Kind.CF_PATCH,
    doc="Twenty 24-bit channels over USB (UAC2): the tracks post-FX pre-fader, MAIN, CUE; the stereo sum at full speed (markandrus/octemu).",
    linked=(Linked("usbaudio", "modules/usbaudio/usbaudio.s", cpu="5475", dram=True),),
    detours=(
        Detour(0x4001dd04, H("2039fc0b01c4"), "usbaudio", "audio_setiface_shim",
               "SET_INTERFACE: interface 4 alt 1 brings the stream up, alt 0 down; others stock"),
        Detour(0x4001d824, H("4879400e20a1"), "usbaudio", "audio_getiface_shim",
               "GET_INTERFACE: interface 4 reports the alt setting the host asked for"),
        Detour(0x4001de64, H("2039fc0b01c0"), "usbaudio", "audio_ctrl_shim",
               "class requests to the clock source (sample rate CUR/RANGE, validity); the rest STALL as stock"),
        Detour(0x4001d4b2, H("23d04ec95028"), "usbaudio", "audio_ep0page_shim",
               "usb_ep0_send fills the dTD's buffer page 1 too: a configuration straddling a 4 KB page transmitted truncated"),
        Detour(0x4000d9a0, H("42b946104d4e"), "usbaudio", "audio_frame_shim",
               "frame_isr's last instruction: the per-block producer (20 channels: tracks, MAIN, CUE; + the sum into the rings) and the packet builder"),
        Detour(0x4001e606, H("2039fc0b01ac"), "usbaudio", "audio_isr_shim",
               "usb_isr UI path: retire EP3 IN completions, then USB MIDI's shim"),
    ),
    # The ISR site is USB MIDI's; this shim does its EP3 work and jumps to
    # USB MIDI's shim by symbol (the units link together).
    overrides=(Override(0x4001e606, "USB MIDI"),),
    pokes=(Poke(0x400e2004, H("000000"), H("ef0201"),
                "device descriptor: class/subclass/protocol = interface-association composite"),),
)
