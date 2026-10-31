"""FRAME PROFILE -- where the frame interrupt's time goes on a unit: seven seams
and four timed busy-waits in the frame interrupt, and the level-6 eDMA handler's
runs inside it, on DMA timer 3, published every 0.5 s (profile.s says which
code each section holds). USB serves the window as vendor request 0xc0/0x57
block 5; tools/hw/task_meter.py and tools/hw/analyzer_sweep.py read it.

Why: on the unit the recorder and a streaming USB IN cost the frame interrupt
far more than their instructions do under the port (docs/firmware/CF_BUDGET.md),
and two bus explanations measured null (the crossbar's arbitration order, the
recorder's copyback stores). The sections, the host-port command waits and the
eDMA waits say which part of the interrupt grows.

Shares sites with CF METER (the host-command polls and the level-6 handler)
and EUCLID (0x4000d562); the ledger refuses either beside it.
"""
from remix.schema import Category, Detour, Kind, Linked, Module, Proof

H = bytes.fromhex
U = "frame_profile"

MODULE = Module(
    name="frame-profile",
    key="FRAME PROFILE",
    kind=Kind.CF_PATCH,
    category=Category.REFERENCE, author="bryantysinger", author_url="https://github.com/bryantysinger",
    proof=Proof.HARDWARE, proof_note="sections sum to the frame interrupt under the port (27 Oct 2026); read on Bryan T's MKII with analyzer_sweep (27-28 Oct 2026)",
    doc="Probe: the frame interrupt's time by section, host-port and eDMA waits, nested eDMA handler time, over USB.",
    requires=("LOAD METER", "USB"),
    linked=(Linked(U, "modules/frame-profile/profile.s", cpu="5475", dram=True),),
    detours=(
        Detour(0x4000ab08, H("4eb94001c9b0"), U, "fp_s0", "S0: the frame's first call, the frame starts", kind="jsr"),
        Detour(0x4000d0de, H("4eb940004db8"), U, "fp_s1", "S1: head ends (host-command handshake, sequencer)", kind="jsr"),
        Detour(0x4000d0ea, H("203980004800"), U, "fp_s2", "S2: the calls 0x40004db8 / 0x40004bd4 end", kind="jsr"),
        Detour(0x4000d31a, H("45f946c7ff42"), U, "fp_s3", "S3: track prep ends, the recorder dispatcher starts", kind="jsr"),
        Detour(0x4000d3d4, H("47f9400d61d0"), U, "fp_s4", "S4: the recorder dispatcher ends, the packer starts", kind="jsr"),
        Detour(0x4000d562, H("43f9800000f0"), U, "fp_s5", "S5: the packer and renderers end", kind="jsr"),
        Detour(0x4000d938, H("4ab946104d04"), U, "fp_s6", "S6: mix and MIDI end; the frame's accounting closes", kind="jsr"),
        Detour(0x4000ab26, H("3039200000044a006df6"), U, "fp_hc1", "the frame's host-command acknowledge poll, timed", pad_to=10),
        Detour(0x4000a90c, H("3039200000044a006df6"), U, "fp_hc2", "the other path's host-command poll, timed", pad_to=10),
        Detour(0x400035a8, H("3039fc04507e4a006cf6"), U, "fp_d3", "the renderer's eDMA channel 3 done poll, timed", pad_to=10),
        Detour(0x40003780, H("3039fc0450be4a006cf6"), U, "fp_d5", "the renderer's eDMA channel 5 done poll, timed", pad_to=10),
        Detour(0x40004840, H("4feffff048d70303"), U, "fp_x6", "the level-6 eDMA handler's entry", pad_to=8),
        Detour(0x40004bc8, H("4cd703034fef00104e73"), U, "fp_x6x", "the level-6 eDMA handler's exit: inside-frame time", pad_to=10),
    ),
)
