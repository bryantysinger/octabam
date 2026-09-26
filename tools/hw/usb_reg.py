#!/usr/bin/env python3
"""Read and (a few) write ColdFire peripheral registers on a unit over USB,
through USB AUDIO OUT's diagnostic vendor requests (image 98 on;
modules/usbaudio-out/usbaudio_out.s out_ctrl_shim).

  tools/hw/usb_reg.py show                 # the USB / crossbar registers of interest
  tools/hw/usb_reg.py peek 0xfc0b01a8      # any long in 0xfc000000.. (see the warning)
  tools/hw/usb_reg.py poke USBMODE 0x1e    # a register from the allowlist below
  tools/hw/usb_reg.py sdis on|off          # USBMODE.SDIS (stream disable), the first test

0x57 (GET) reads the long at wIndex<<16 | wValue; the device refuses
anything outside 0xfc000000..0xfcffffff. An address with no register
behind it can take an access error and reset the unit: stick to `show`
and addresses from the reference manual. 0x58 / 0x59 (OUT, no data) write
the low / high 16 bits of an allowlisted register, keeping the other half.
A poke lasts until the next USB reset (replug) or power cycle.

Needs pyusb + libusb, as tools/hw/usb_counters.py.
"""
import argparse
import struct
import sys

POKE = {  # name -> (index in out_poketab, address)
    "USBMODE": (0, 0xfc0b01a8),
    "BURSTSIZE": (1, 0xfc0b0160),
    "TXFILLTUNING": (2, 0xfc0b0164),
}
for n in range(1, 8):
    POKE[f"PRS{n}"] = (2 + n, 0xfc004000 + 0x100 * n)
    POKE[f"CRS{n}"] = (9 + n, 0xfc004010 + 0x100 * n)
SHOW = ["USBMODE", "BURSTSIZE", "TXFILLTUNING"] + [f"PRS{n}" for n in range(1, 8)] + [f"CRS{n}" for n in range(1, 8)]


def device():
    import glob
    import usb.core
    import usb.backend.libusb1
    libs = (glob.glob("/opt/homebrew/opt/libusb/lib/libusb-1.0.dylib") + glob.glob("/usr/local/opt/libusb/lib/libusb-1.0.dylib")
            + glob.glob("/opt/homebrew/lib/libusb-1.0*.dylib") + glob.glob("/usr/local/lib/libusb-1.0*.dylib"))
    backend = usb.backend.libusb1.get_backend(find_library=lambda _: libs[0]) if libs else None
    dev = usb.core.find(idVendor=0x1935, idProduct=0x0002, backend=backend)
    if dev is None:
        sys.exit("no Octatrack on USB (1935:0002)")
    return dev


def peek(dev, addr):
    raw = bytes(dev.ctrl_transfer(0xc0, 0x57, addr & 0xffff, addr >> 16, 4, timeout=1000))
    return struct.unpack(">I", raw)[0]


def poke(dev, name, value):
    idx, _ = POKE[name]
    if value >> 16:
        dev.ctrl_transfer(0x40, 0x59, value >> 16, idx, None, timeout=1000)
    dev.ctrl_transfer(0x40, 0x58, value & 0xffff, idx, None, timeout=1000)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("show")
    p = sub.add_parser("peek"); p.add_argument("addr", type=lambda v: int(v, 0))
    p = sub.add_parser("poke"); p.add_argument("name", choices=sorted(POKE)); p.add_argument("value", type=lambda v: int(v, 0))
    p = sub.add_parser("sdis"); p.add_argument("state", choices=("on", "off"))
    a = ap.parse_args()
    dev = device()
    try:
        if a.cmd == "show":
            for n in SHOW:
                print(f"{n:13s} {POKE[n][1]:#010x} = {peek(dev, POKE[n][1]):#010x}")
        elif a.cmd == "peek":
            print(f"{a.addr:#010x} = {peek(dev, a.addr):#010x}")
        elif a.cmd == "poke":
            before = peek(dev, POKE[a.name][1])
            poke(dev, a.name, a.value)
            print(f"{a.name}: {before:#010x} -> {peek(dev, POKE[a.name][1]):#010x}")
        elif a.cmd == "sdis":
            before = peek(dev, POKE["USBMODE"][1])
            new = (before | 0x10) if a.state == "on" else (before & ~0x10)
            poke(dev, "USBMODE", new & 0xffff)
            print(f"USBMODE: {before:#010x} -> {peek(dev, POKE['USBMODE'][1]):#010x}")
    except Exception as e:  # noqa: BLE001
        sys.exit(f"the request failed: {e} (a STALL: an image before 98, or a refused address)")


if __name__ == "__main__":
    main()
