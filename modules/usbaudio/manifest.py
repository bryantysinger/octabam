"""USB AUDIO -- the eight tracks over USB as a UAC2 sixteen-channel input.

markandrus (octemu, MIT): at USB high speed the unit adds an audio function
to the USB MIDI composite, sixteen channels of 44.1 kHz PCM, track N's
post-FX pre-fader L/R on channels 2N-1/2N, taken from the read-back arena
the eDMA fills every block; at full speed the stereo sum of the tracks.
His stream is 16-bit; this one carries 24 bits in 4-byte subslots at a
250 us poll. His card-loaded payload, page allocator, runtime hook installer,
trampoline, reporter and guard are replaced by the DRAM platform: the unit
is linked into the reserve, the rings are its data, and every hook is a
build-time detour. Needs USB MIDI (the audio function shares its
composite: the descriptor unit generates the five-interface configuration
when this module is in the remix, and this module's ISR shim chains to
USB MIDI's). The dTDs and packet buffers the controller DMAs are the
unit's own data, read and written only through the uncached SDRAM alias.
README.md has what was measured and what was not.
"""
from remix.schema import Detour, Kind, Linked, Module, Override, Poke

H = bytes.fromhex

MODULE = Module(
    name="usbaudio", key="USB AUDIO", kind=Kind.CF_PATCH,
    doc="Sixteen 24-bit channels of the tracks over USB (UAC2, post-FX pre-fader), the stereo sum at full speed (markandrus/octemu).",
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
