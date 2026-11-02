"""PC SAMPLER -- where the ColdFire's time goes on a unit, by code address: a
level-6 interrupt from PIT3 at about 20 kHz counts the interrupted PC into
histograms (sampler.s). Unlike the port's instruction counts (ot_emu
--isr-meter) and FRAME PROFILE's seams, it sees memory stalls and needs no
seam inside the code it measures. USB serves the header as 0xc0/0x57 block 6
(USB_TESTCMD, a probes remix with LOAD METER); tools/hw/pc_sampler.py reads
the histograms with 0xc0/0x59 and names the hot code.

Cost: one level-6 interrupt every 50 us, a few dozen instructions; about 1% of
the ColdFire. A test image's module, not an everyday one.
"""
from remix.schema import Category, Detour, Kind, Linked, Module, Proof

H = bytes.fromhex
U = "pc_sampler"

MODULE = Module(
    name="pc-sampler",
    key="PC SAMPLER",
    kind=Kind.CF_PATCH,
    category=Category.REFERENCE, author="bryantysinger", author_url="https://github.com/bryantysinger",
    proof=Proof.PORT, proof_note="under the port with PIT3 modelled (1 Nov 2026): ~20 kHz, every sample counted once (lo + hi + other = total), STRESS_INT A07; the header over USB (verify_usb_load_meter); not yet on a unit",
    doc="Probe: a 20 kHz level-6 PC sampler on PIT3; where the ColdFire's time goes, over USB.",
    requires=("USB", "LOAD METER"),
    linked=(Linked(U, "modules/pc-sampler/sampler.s", cpu="5475", dram=True),),
    detours=(
        Detour(0x40040482, H("4eb940000d50"), U, "pcs_init",
               "the sys task's init installs DTIM1's handler: start the sampler first", kind="jsr"),
    ),
)
