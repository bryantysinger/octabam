#!/usr/bin/env python3
"""Enumerate the image just built as a USB device under the ColdFire port.

Boots out/mainos_bus.bin with the device-controller model and its bench
(tools/emu/ot_emu/usb.h), then acts as the host: bus reset, GET_DESCRIPTOR,
SET_ADDRESS, SET_CONFIGURATION, a mass-storage INQUIRY and TEST UNIT READY
over EP1. The firmware's own USB stack answers every step, so this checks:

  * the stock control path is intact in the built image (a module that
    moves a descriptor table, hooks the ISR or grows a configuration shows
    up here as a wrong VID/PID, a short config or a hang);
  * the model's queue-head and transfer-descriptor walk agrees with what
    the firmware builds (the INQUIRY data + CSW chain, both directions);
  * no primed queue head was left uninitialised (the defect that crashed a
    unit under octemu's USB-audio payload).

SKIPs when the port is not built (`make emu-cf`). What this cannot see:
timing (the port serialises the host's polls against the frame interrupt)
and anything a real host does beyond these requests.
"""
import os
import pathlib
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1])); import toolpath  # noqa: E402,F401
import usb_host  # noqa: E402  (tools/harness)

EMU = ROOT / "out/emu/ot_emu"
IMAGE = ROOT / "out/mainos_bus.bin"


def main():
    if not EMU.is_file():
        print("  [SKIP] verify_usb: the port is not built (make emu-cf)")
        return 0
    if not IMAGE.is_file():
        print("  [FAIL] verify_usb: no out/mainos_bus.bin (make bus)")
        return 1
    sock = f"/tmp/ot-usb-{os.getpid()}.sock"     # sun_path is 104 bytes on macOS; the scratch dirs are longer
    log = ROOT / "out/verify_usb.log"
    with open(log, "w") as lf:
        emu = subprocess.Popen([str(EMU), "--image", str(IMAGE), "--usb-host", sock, "--usb-hold-ms", "120000"],
                               cwd=ROOT, stdout=lf, stderr=subprocess.STDOUT)
    fails = []

    def check(what, ok, detail=""):
        print(f"  [{'PASS' if ok else 'FAIL'}] {what}{'  ' + detail if detail else ''}")
        if not ok:
            fails.append(what)

    try:
        b = usb_host.Bench(sock, timeout=60.0)
        dev, cfg = usb_host.enumerate_device(b, hs=True)
        vid, pid = dev[8] | dev[9] << 8, dev[10] | dev[11] << 8
        check("device descriptor: Elektron 1935:0002, USB 2.00", (vid, pid, dev[2], dev[3]) == (0x1935, 0x0002, 0x00, 0x02),
              f"got {vid:04x}:{pid:04x} bcdUSB {dev[3]:x}.{dev[2]:02x}")
        ifaces = [d for t, d in usb_host.descriptors(cfg) if t == 4]
        eps = [d for t, d in usb_host.descriptors(cfg) if t == 5]
        msc = [d for d in ifaces if d[5:8] == bytes([8, 6, 0x50])]
        check("a mass-storage SCSI/BOT interface is in the configuration", len(msc) == 1,
              f"{len(ifaces)} interface(s), {len(cfg)} bytes")
        bulk = sorted((d[2], d[3] & 3, d[4] | d[5] << 8) for d in eps if d[2] in (0x81, 0x01))
        check("EP 0x81/0x01 bulk, 512 bytes at high speed", bulk == [(0x01, 2, 512), (0x81, 2, 512)], str(bulk))
        ok = usb_host.msc_test(b)
        check("INQUIRY answers 36 bytes with a good CSW", ok)
    except Exception as e:  # noqa: BLE001 -- a hang or a stall is the finding
        check(f"the host script completed ({type(e).__name__}: {e})", False)
    finally:
        try:
            b.sock.close()          # the hangup ends the port's hold
        except NameError:
            emu.kill()
    try:
        rc = emu.wait(timeout=120)
    except subprocess.TimeoutExpired:
        emu.kill()
        rc = -1
    check("the port exited cleanly after the client hung up", rc == 0, f"exit {rc}")
    summary = [l for l in log.read_text(errors="replace").splitlines() if l.startswith("usb        : USBCMD")]
    check("the port printed its USB summary", bool(summary))
    if summary:
        s = summary[-1]
        print("  " + s)
        check("no uninitialised queue head was primed", "UNINITIALIZED" not in s)
        check("no EP0 stall during enumeration", " 0 stall(s)" in s)
    print(f"verify_usb: {'OK' if not fails else str(len(fails)) + ' FAILED'} ({log})")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
